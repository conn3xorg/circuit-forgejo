# circuit-forgejo

A Conn3x circuit that runs [Forgejo](https://forgejo.org), the self-hosted Git forge, on your own hosts. Repositories, issues, pull requests and packages, on a box you already pay for, with your code never leaving it.

It downloads a pinned Forgejo release binary from Codeberg, checks its SHA-256, and runs it under systemd as a `git` user. You set the domain, the URL people reach it by, the listen address and the database; the circuit writes `/etc/forgejo/app.ini` from them and restarts Forgejo when it changes. Out of the box Forgejo listens only on `127.0.0.1:3000`, keeps its data in SQLite, and doesn't let strangers sign up. The host's own sshd serves git over SSH, so clone URLs look like `git@git.example.com:you/repo.git`.

The circuit also creates your admin user, and keeps its password in step with `admin_password`.

## Usage

```hcl
variable "forgejo_admin_password" {
  type      = string
  sensitive = true
}

module "forgejo" {
  source = "github.com/conn3xorg/circuit-forgejo?ref=v0.1.0"

  hosts                = { git1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  domain   = "git.example.com"
  root_url = "https://git.example.com/"

  admin_username = "james"
  admin_email    = "james@example.com"
  admin_password = var.forgejo_admin_password
}
```

Then run `conn3x init` and `conn3x apply`, with the password in `TF_VAR_forgejo_admin_password`. A second `conn3x plan` says `No changes.`

Forgejo speaks plain HTTP. Put it behind a TLS proxy on the same host, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) with a reverse proxy to `127.0.0.1:3000`, and set `root_url` to the address people type. To reach it without a proxy, set `http_address = "0.0.0.0"` and open `http_port`.

### PostgreSQL

SQLite is fine for a person or a small team. For more, point Forgejo at PostgreSQL. The database and role must exist; [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) can make both on the same host:

```hcl
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts          = { git1 = "203.0.113.10" }
  users          = ["forgejo"]
  user_passwords = { forgejo = var.forgejo_db_password }
  databases      = { forgejo = "forgejo" }
}

module "forgejo" {
  source     = "github.com/conn3xorg/circuit-forgejo?ref=v0.1.0"
  depends_on = [module.postgres]

  hosts             = { git1 = "203.0.113.10" }
  postgres          = {}
  postgres_password = var.forgejo_db_password

  admin_username = "james"
  admin_email    = "james@example.com"
  admin_password = var.forgejo_admin_password
}
```

`postgres = {}` means `127.0.0.1:5432`, database `forgejo`, user `forgejo`. Set `host`, `name`, `user` or `ssl_mode` for anything else.

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Installs `git` and `curl` if they're missing.
2. Creates the `git` system user, with home `/home/git` and `/bin/bash` as its shell, since sshd runs Forgejo's command for git over SSH through it. Creates `/home/git/.ssh`, `/var/lib/forgejo` for Forgejo's data, and `/etc/forgejo`, which `git` can read but not write.
3. Downloads `forgejo-VERSION-linux-ARCH` from the Codeberg release to `/usr/local/bin/forgejo`. If the checksum doesn't match `checksums`, the apply fails and the old binary stays.
4. Generates `INTERNAL_TOKEN`, `SECRET_KEY`, `JWT_SECRET` and `LFS_JWT_SECRET` once, each into its own file in `/etc/forgejo`, with `forgejo generate secret`. Forgejo reads them from there through `*_URI = file:` settings, so they never pass through Conn3x, the plan or state. Later applies leave them alone.
5. Writes `/etc/forgejo/app.ini`, owned by root with mode `0640`, and `/etc/systemd/system/forgejo.service`. A change to either, or a new binary, restarts Forgejo.
6. Starts Forgejo now and at boot, and waits until `/api/healthz` answers. On a first start, Forgejo creates its database here.
7. Writes `admin_password` to `/etc/conn3x/forgejo/admin_password` (root only, mode `0600`), creates the admin user if there isn't one by that name, and sets its password whenever that file changed.

app.ini is write-only: it reaches the host, but the plan and state hold only an HMAC of it, since it can carry the PostgreSQL password. A change to any input shows in the plan as `content_hmac` changing. See [Secrets](https://docs.conn3x.org/reference/circuits/secrets) for the HMAC key Conn3x uses.

Forgejo's CLI takes a password only as an argument, so the admin password is on a command line, visible to `ps`, for the moment `forgejo admin user change-password` runs. The admin is first created with a random password, so that's the only time.

The unit runs Forgejo with `ProtectSystem=strict`, so it can write only to `/var/lib/forgejo` and `/home/git/.ssh`, where it keeps the `authorized_keys` file sshd reads for git over SSH.

Before the circuit runs, the `conn3x_host` data source reads each host's architecture over SSH. `x86_64` and `aarch64` each get their own build; other architectures fail the plan.

### What it doesn't do

- It doesn't open a firewall port or set up TLS. See above for a proxy, and use [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for ports.
- It doesn't configure email, Actions runners, OAuth sources or anything else in app.ini beyond the inputs below. Forgejo's defaults apply to the rest.
- It doesn't take backups. `forgejo dump` makes one; copying it somewhere safe is up to you.
- It doesn't check the release's GPG signature on the host. The default checksums were taken from the release's `.sha256` files, and the binaries they match carry a good signature from Forgejo's release key, `EB114F5E6C0DC2BCDD183550A4B61A2DC5923710`.
- Changing `admin_username` creates a second admin; it doesn't rename the first. Changing `admin_email` after the first apply changes nothing.
- Deleting the module leaves Forgejo installed and running, with its data.

### Upgrading

Set `forgejo_version` and `checksums` together. Each binary on the [release page](https://codeberg.org/forgejo/forgejo/releases) has a `.sha256` file beside it, and a `.asc` signature you can check first:

```sh
v=17.0.1
for a in amd64 arm64; do
  curl -sSfLO https://codeberg.org/forgejo/forgejo/releases/download/v$v/forgejo-$v-linux-$a
  curl -sSfLO https://codeberg.org/forgejo/forgejo/releases/download/v$v/forgejo-$v-linux-$a.asc
  gpg --verify forgejo-$v-linux-$a.asc forgejo-$v-linux-$a && sha256sum forgejo-$v-linux-$a
done
```

```hcl
module "forgejo" {
  source = "github.com/conn3xorg/circuit-forgejo?ref=v0.1.0"

  # ...
  forgejo_version = "17.0.1"
  checksums = {
    x86_64  = "51a8cdf4a1252e79f4b3855d7a7891af6c6635105420768c460e2f0690385d6f"
    aarch64 = "1e99403746406e8199efc903ddd1940d5728a60e50241f7aa6c9f2b907bd8ec9"
  }
}
```

The new binary replaces the old one and Forgejo restarts, migrating its database on the way up. Take a `forgejo dump` first and read Forgejo's release notes, since a migration can't be undone by going back a version.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port Conn3x connects to. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `forgejo_version` | string | `"17.0.1"` | Forgejo release to install, without the leading `v`. |
| `checksums` | map(string) | The 17.0.1 checksums | SHA-256 of the release binary for `x86_64` and `aarch64`. |
| `app_name` | string | `"Forgejo"` | Name shown in page titles and emails. |
| `domain` | string | `null` | Host name people reach Forgejo by, used in clone URLs. When null, each host's address. |
| `root_url` | string | `null` | Public URL with a trailing slash, such as `"https://git.example.com/"`. When null, `http://DOMAIN:HTTP_PORT/`. |
| `http_address` | string | `"127.0.0.1"` | Address the web interface and API listen on. `"0.0.0.0"` listens on every address. |
| `http_port` | number | `3000` | Port of the web interface and API. |
| `git_ssh_port` | number | `22` | SSH port shown in clone URLs. With `builtin_ssh_server`, also the port Forgejo's own SSH server listens on. |
| `builtin_ssh_server` | bool | `false` | Run Forgejo's own SSH server on `git_ssh_port` instead of using the host's sshd. Pick a port sshd isn't on. |
| `disable_registration` | bool | `true` | Stop people creating their own accounts. The admin can still create them. |
| `postgres` | object | `null` | PostgreSQL connection: `host` (`"127.0.0.1:5432"`), `name` (`"forgejo"`), `user` (`"forgejo"`) and `ssl_mode` (`"disable"`). When null, SQLite in `/var/lib/forgejo/data`. |
| `postgres_password` | string | `null` | Password of the PostgreSQL user, needed with `postgres`. Sensitive, and kept out of state. Can't hold a backtick. |
| `admin_username` | string | Required | Name of the admin user. Forgejo reserves some names, such as `admin`. |
| `admin_email` | string | Required | Email address of the admin user. |
| `admin_password` | string | Required | Password of the admin user, at least 8 characters. Sensitive, and kept out of state. Changing it sets the new one. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the configuration file, `/etc/forgejo/app.ini`. |
| `urls` | Each host's `ROOT_URL` by host name, such as `{ git1 = "https://git.example.com/" }`. |

## Requirements

Requires Conn3x v0.6.6 or later, systemd on each host, and outbound HTTPS to codeberg.org and your distribution's mirrors.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, then checks `/api/healthz`, signs in to `/api/v1/user` as the admin, checks that a wrong password gets `401`, creates a repository over the API and clones it over HTTP. The same checks passed on arm64 containers of all four by hand.

By hand, on Debian 13 in a container, the admin password was changed with a second apply and the new one worked; and with circuit-postgres on the same host and `postgres = {}`, Forgejo kept its data in PostgreSQL, the second plan had no changes, and the password was in neither the state nor the plan output.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both with 1 vCPU and 1 GB of memory, the same checks passed, and a key added over the API cloned and pushed over the host's sshd as `git@`. On Rocky Linux, Forgejo ran as `unconfined_service_t`, `authorized_keys` was labelled `ssh_home_t`, and the audit log had no denials. After a reboot both came back with the repository, and the plan had no changes.

`builtin_ssh_server` hasn't been tried.

## License

MPL-2.0. See [LICENSE](LICENSE). Forgejo itself is GPL-3.0-or-later.

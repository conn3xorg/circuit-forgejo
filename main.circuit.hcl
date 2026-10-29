# Facts give each host's architecture, which picks the release binary.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = contains(keys(var.checksums), self.arch)
      error_message = "Host ${each.key} is ${self.arch}. The circuit has Forgejo builds for ${join(" and ", keys(var.checksums))}."
    }
  }
}

locals {
  binary  = "/usr/local/bin/forgejo"
  work    = "/var/lib/forgejo"
  etc     = "/etc/forgejo"
  config  = "${local.etc}/app.ini"
  git_ssh = "/home/git/.ssh"

  # Forgejo names its builds by Go's architecture names.
  goarch = { x86_64 = "amd64", aarch64 = "arm64" }

  # Every command Forgejo's CLI runs as git, against the same config and
  # data the service uses.
  cli = "cd / && runuser -u git -- ${local.binary} --config ${local.config} --work-path ${local.work}"

  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.http_address, strcontains(var.http_address, ":") ? "[${var.http_address}]" : var.http_address)
  local_url  = "http://${local.local_host}:${var.http_port}"

  domain   = { for name, h in var.hosts : name => coalesce(var.domain, try(h.address, h)) }
  root_url = { for name, h in var.hosts : name => coalesce(var.root_url, "http://${local.domain[name]}:${var.http_port}/") }

  # Each secret is generated on the host by the first apply and read by
  # Forgejo from its file, so none of them is in app.ini, the plan or state.
  secrets = {
    INTERNAL_TOKEN = "internal_token"
    SECRET_KEY     = "secret_key"
    JWT_SECRET     = "jwt_secret"
    LFS_JWT_SECRET = "lfs_jwt_secret"
  }

  # The database password is the one secret app.ini holds. Backticks quote
  # it for Forgejo's ini parser, so ; and # stay part of it.
  database = var.postgres == null ? "DB_TYPE = sqlite3\nPATH = ${local.work}/data/forgejo.db\n" : join("\n", [
    "DB_TYPE = postgres",
    "HOST = ${try(var.postgres.host, "")}",
    "NAME = ${try(var.postgres.name, "")}",
    "USER = ${try(var.postgres.user, "")}",
    "SSL_MODE = ${try(var.postgres.ssl_mode, "")}",
    "PASSWD = `${coalesce(var.postgres_password, "-")}`",
    "",
  ])

  app_ini = { for name, h in var.hosts : name => <<-EOT
    ; Written by Conn3x. Changes here are overwritten on the next apply.
    APP_NAME = ${var.app_name}
    RUN_USER = git
    RUN_MODE = prod
    WORK_PATH = ${local.work}

    [server]
    PROTOCOL = http
    DOMAIN = ${local.domain[name]}
    ROOT_URL = ${local.root_url[name]}
    HTTP_ADDR = ${var.http_address}
    HTTP_PORT = ${var.http_port}
    SSH_DOMAIN = ${local.domain[name]}
    SSH_PORT = ${var.git_ssh_port}
    START_SSH_SERVER = ${var.builtin_ssh_server}
    SSH_LISTEN_PORT = ${var.git_ssh_port}
    LFS_START_SERVER = true
    LFS_JWT_SECRET_URI = file:${local.etc}/lfs_jwt_secret

    [database]
    ${local.database}
    [security]
    INSTALL_LOCK = true
    INTERNAL_TOKEN_URI = file:${local.etc}/internal_token
    SECRET_KEY_URI = file:${local.etc}/secret_key

    [oauth2]
    JWT_SECRET_URI = file:${local.etc}/jwt_secret

    [service]
    DISABLE_REGISTRATION = ${var.disable_registration}

    [log]
    MODE = console
    LEVEL = Info
  EOT
  }
}

circuit "forgejo" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Forgejo runs git for every repository operation. curl waits for it to
  # come up.
  step "tools" {
    for_each = toset(["git", "curl"])
    package {
      name = item.value
    }
  }

  # sshd runs Forgejo's forced command through git's login shell, so git
  # over SSH needs a real one.
  step "user" {
    user {
      name   = "git"
      system = true
      home   = "/home/git"
      shell  = "/bin/bash"
    }
  }

  # Forgejo adds users' keys to git's authorized_keys. Creating .ssh here
  # gives it the ssh_home_t label on SELinux hosts, which sshd needs to read
  # the file Forgejo writes into it.
  step "ssh_dir" {
    directory {
      path  = local.git_ssh
      owner = "git"
      group = "git"
      mode  = "0700"
    }
  }

  step "work_dir" {
    directory {
      path  = local.work
      owner = "git"
      group = "git"
      mode  = "0750"
    }
  }

  # app.ini and the secrets belong to root, and git can only read them, so
  # Forgejo can't rewrite its own configuration.
  step "config_dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "git"
      mode  = "0750"
    }
  }

  step "binary" {
    download {
      url    = "https://codeberg.org/forgejo/forgejo/releases/download/v${var.forgejo_version}/forgejo-${var.forgejo_version}-linux-${local.goarch[data.conn3x_host.facts[each.key].arch]}"
      sha256 = var.checksums[data.conn3x_host.facts[each.key].arch]
      dest   = local.binary
      mode   = "0755"
    }
  }

  step "secret" {
    for_each = local.secrets
    command {
      command = "umask 077 && ${local.binary} generate secret ${item.key} > ${local.etc}/${item.value}.new && chgrp git ${local.etc}/${item.value}.new && chmod 640 ${local.etc}/${item.value}.new && mv ${local.etc}/${item.value}.new ${local.etc}/${item.value}"
      creates = "${local.etc}/${item.value}"
    }
  }

  # Write-only, since it can hold the PostgreSQL password: the plan and
  # state record only an HMAC of the content.
  step "config" {
    file {
      path       = local.config
      content_wo = local.app_ini[each.key]
      owner      = "root"
      group      = "git"
      mode       = "0640"
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/forgejo.service"
      content = <<-EOT
        [Unit]
        Description=Forgejo
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=git
        Group=git
        WorkingDirectory=${local.work}
        ExecStart=${local.binary} web --config ${local.config}
        Environment=USER=git HOME=/home/git FORGEJO_WORK_DIR=${local.work}
        Restart=always
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        NoNewPrivileges=true
        ProtectSystem=strict
        PrivateTmp=true
        ReadWritePaths=${local.work} ${local.git_ssh}

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # A step rather than a handler, so the checks below wait for the Forgejo
  # that runs the new binary and config. A handler would restart it after
  # them, and a plan straight after the apply would find it still starting.
  # On a first apply it's what starts Forgejo.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart forgejo"
      triggers = {
        binary = conn3x_download.forgejo__binary[each.key].revision
        config = conn3x_file.forgejo__config[each.key].revision
        unit   = conn3x_file.forgejo__unit[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "forgejo"
      state   = "started"
      enabled = true
    }
  }

  # On a first start Forgejo creates its database before it answers, and
  # the admin user can't be created until it has. unless is checked at plan
  # time, before the restart, so the restart's revision makes the apply
  # check again.
  step "ready" {
    command {
      command  = "for _ in $(seq 120); do curl -sf -o /dev/null ${local.local_url}/api/healthz && exit 0; sleep 1; done; exit 1"
      unless   = "curl -sf -o /dev/null ${local.local_url}/api/healthz"
      triggers = { restart = conn3x_command.forgejo__restart[each.key].revision }
    }
  }

  step "password_dir" {
    directory {
      path = "/etc/conn3x/forgejo"
      mode = "0700"
    }
  }

  # The admin password lands in a root-only file, never in state or the plan.
  step "admin_password" {
    file {
      path       = "/etc/conn3x/forgejo/admin_password"
      content_wo = var.admin_password
    }
  }

  # Created with a random password, which the next step replaces, so the
  # real one is never on a command line here.
  step "admin" {
    command {
      command = "${local.cli} admin user create --admin --username '${var.admin_username}' --email '${var.admin_email}' --random-password --must-change-password=false >/dev/null"
      unless  = "${local.cli} admin user list --admin | awk 'NR > 1 { print $2 }' | grep -qxF '${var.admin_username}'"
    }
  }

  # Runs when the password file changes or the user was just created.
  # Forgejo's CLI only takes a password as an argument, so it's on this
  # command line for the moment the command runs.
  step "admin_set_password" {
    command {
      command = "${local.cli} admin user change-password --username '${var.admin_username}' --password \"$(cat /etc/conn3x/forgejo/admin_password)\" --must-change-password=false >/dev/null"
      triggers = {
        password = conn3x_file.forgejo__admin_password[each.key].revision
        user     = conn3x_command.forgejo__admin[each.key].revision
      }
    }
  }
}

# Local example

Applies circuit-forgejo to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

```sh
./up.sh
export TF_VAR_admin_password=$(openssl rand -hex 12)
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` Forgejo listens on `127.0.0.1:3000` inside the container. To sign in as the admin over the API:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  curl -s -u "forgejo-admin:$TF_VAR_admin_password" localhost:3000/api/v1/user
```

To use the web interface from your browser, forward the port over SSH and open `http://localhost:3000`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 3000:127.0.0.1:3000 -N root@127.0.0.1
```

Links Forgejo builds itself, such as clone URLs, point at `git.example.test`, the example's `domain`.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.

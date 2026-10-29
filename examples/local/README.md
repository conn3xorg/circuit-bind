# Local example

Applies circuit-bind to two throwaway Rocky Linux 10 containers with systemd: a primary serving `example.test`, and a secondary that copies it over a TSIG-signed transfer. You need Conn3x and Podman.

The containers run privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
NAME=circuit-bind-secondary PORT=2223 ./up.sh

export TF_VAR_tsig_secret=$(openssl rand -base64 32)
export TF_VAR_secondary_port=2223
export TF_VAR_primary_address=$(${PODMAN:-podman} inspect -f '{{.NetworkSettings.IPAddress}}' circuit-bind)
export TF_VAR_secondary_address=$(${PODMAN:-podman} inspect -f '{{.NetworkSettings.IPAddress}}' circuit-bind-secondary)

conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` The two addresses are the containers' own on Podman's network, where the secondary fetches the zone and the primary sends NOTIFY. Leave `TF_VAR_secondary_port` unset to try the primary on its own.

To ask the secondary something:

```sh
ssh -p 2223 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1
dnf -y install bind-utils
dig @127.0.0.1 www.example.test   # flags include aa: it answers with authority
dig @127.0.0.1 example.test SOA   # the serial, the same as the primary's
dig @127.0.0.1 example.org        # REFUSED: recursion is off
```

Now change a record with `conn3x apply -var www_address=192.0.2.11`. The primary's serial goes up, and within a second or two the secondary answers with the new address.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses. Two Fedora 45 containers from the same image share a machine ID, and with it a MAC address, so they can't reach each other: pair Fedora with another distribution.

`./down.sh` removes both containers, their volumes, the key and the state.

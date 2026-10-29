# circuit-bind

A Conn3x circuit that runs BIND 9 as an authoritative DNS server, from your distribution's own packages. You write your zones as records in HCL; the circuit turns them into zone files, gives each a serial that goes up whenever the records change, and has BIND serve them. A second server can carry the same zones as a secondary, copying them from the primary over a TSIG-signed transfer and picking up each change as soon as the primary sends NOTIFY.

Recursion is off, so BIND answers for its own zones and refuses everything else. If you want a resolver for your network, [circuit-unbound](https://github.com/conn3xorg/circuit-unbound) is the one to reach for.

The same settings land on Debian, Ubuntu, Fedora and Rocky Linux. The circuit picks the parts that differ: `/etc/bind` or `/etc/named.conf`, `/var/lib/bind` or `/var/named`, the `bind` or `named` user, and the unit's name. Every zone goes through `named-checkzone`, and the config through `named-checkconf`, before BIND sees either.

## Usage

```hcl
module "dns" {
  source = "github.com/conn3xorg/circuit-bind?ref=v0.1.0"

  hosts                = { ns1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  zones = {
    "example.com" = {
      type = "primary"
      records = [
        { name = "@", type = "NS", value = "ns1" },
        { name = "@", type = "MX", value = "10 mail" },
        { name = "@", type = "TXT", value = "v=spf1 mx -all" },
        { name = "ns1", type = "A", value = "203.0.113.10" },
        { name = "www", type = "A", ttl = 300, value = "203.0.113.20" },
        { name = "mail", type = "A", value = "203.0.113.25" },
        { name = "blog", type = "CNAME", value = "www" },
      ]
    }
  }

  soa = { rname = "hostmaster.example.com." }
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.` and `dig @203.0.113.10 www.example.com` answers with the `aa` flag.

Records are written as they would be in a zone file. A `name` without a trailing dot is relative to the zone, and `@` is the zone itself. `ttl` is optional and falls back to `default_ttl`. A TXT `value` without quotes gets them, so a value with spaces stays one string; one longer than 255 characters needs splitting into quoted pieces yourself. Every primary zone needs at least one `NS` record.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its paths by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` every step on them plans as a replacement.

```hcl
hosts = {
  for name, d in digitalocean_droplet.ns : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "rocky"
  }
}
```

To try a primary and a secondary on throwaway containers first, see [examples/local](examples/local).

### A primary and a secondary

Use the module twice: once for the primary, holding the records, and once for the secondary, pointing at the primary. Both need the same TSIG key, which signs the transfer so only the secondary can take a copy of the zone.

```hcl
variable "tsig_secret" {
  type      = string
  sensitive = true
}

module "ns1" {
  source = "github.com/conn3xorg/circuit-bind?ref=v0.1.0"
  hosts  = { ns1 = "203.0.113.10" }

  tsig_keys = { transfer = var.tsig_secret }

  zones = {
    "example.com" = {
      type = "primary"
      records = [
        { name = "@", type = "NS", value = "ns1" },
        { name = "@", type = "NS", value = "ns2" },
        { name = "ns1", type = "A", value = "203.0.113.10" },
        { name = "ns2", type = "A", value = "198.51.100.10" },
        { name = "www", type = "A", value = "203.0.113.20" },
      ]
      allow_transfer = ["key transfer"]
      also_notify    = ["198.51.100.10"]
    }
  }
}

module "ns2" {
  source = "github.com/conn3xorg/circuit-bind?ref=v0.1.0"
  hosts  = { ns2 = "198.51.100.10" }

  tsig_keys = { transfer = var.tsig_secret }

  zones = {
    "example.com" = {
      type      = "secondary"
      primaries = ["203.0.113.10"]
      key       = "transfer"
    }
  }
}
```

Make a secret with `tsig-keygen transfer`, which prints a key block with the secret in it, or with `openssl rand -base64 32`, and pass it in with `TF_VAR_tsig_secret`. Keys use `hmac-sha256`.

`allow_transfer` is a BIND address match list, so `"key transfer"` lets anyone holding the key transfer the zone, and `"198.51.100.10"` lets that address transfer it unsigned. Leave it empty and nobody can. `also_notify` lists servers to tell about each change. The primary also tells every server named in the zone's `NS` records that it can find an address for, so with `ns2`'s `A` record in the zone, as above, `also_notify` is belt and braces.

The two modules can apply side by side. Whichever server comes up second finds the other ready: a secondary asks for the zone as soon as it loads it, and a primary sends NOTIFY when it starts.

### The serial

Every primary zone gets a serial in the usual `YYYYMMDDnn` form: the date, then a two-digit count. The circuit leaves a placeholder in the file it writes, and the host fills it in when the records change, so a plan never depends on the clock and the serial stays put when nothing changes. The first change of the day gets `00`; another later the same day gets `01`, and so on. When the live file's serial is already that high, as after a 100th change in a day or a serial you set by hand, it goes up by one instead. Either way it only ever increases, which is what secondaries need to see a change.

A hand edit to the live zone file is put back on the next apply, under a new serial, so secondaries get the put-back version too.

Delete the zone file on the host and the serial starts again from today's `00`. If the secondaries already hold a higher serial from earlier the same day, they keep their copy until the primary passes it.

### Who may ask

`listen_on` picks the addresses BIND answers on, port 53, and defaults to `"any"`, every IPv4 and IPv6 address. BIND binds each address on its own, so it sits beside systemd-resolved's stub on `127.0.0.53` without trouble: on an Ubuntu 24.04 droplet, both ran together.

Anyone who can reach those addresses can query the zones, which is the point of an authoritative server. They can't use it to look up anything else: `recursion` is off, so a question about a name outside the zones is `REFUSED`. With `recursion = true`, BIND also resolves for the host and its own networks, BIND's default `allow-recursion`, and checks DNSSEC on those answers.

## What it does

On each host, in order:

1. Installs `bind9` on Debian and Ubuntu, or `bind` on the Red Hat family.
2. For each primary zone, writes the rendered zone, with the serial still a placeholder, to `<zone file>.conn3x`. The zone file is `/var/lib/bind/<zone>.zone` on Debian and Ubuntu, `/var/named/<zone>.zone` on the Red Hat family.
3. When those records differ from the live file's, fills in a new serial, runs `named-checkzone` over the result and puts it in place, owned by root and readable by BIND's group. If the check fails, the live file stays as it was and the apply stops with BIND's error, such as `bad dotted quad`.
4. Writes the whole config to `named.conf.conn3x` beside the live `named.conf`, `/etc/bind/named.conf` on Debian and Ubuntu, `/etc/named.conf` on the Red Hat family. With `tsig_keys` set, it goes through `content_wo`, so the secrets stay out of state and out of the plan. Then runs `named-checkconf` over it and copies it in place, mode `0640`, readable by BIND's group. A config that fails the check never reaches the live file.
5. Starts BIND now and at boot, and reloads it when a zone or the config changed. The unit's reload runs `rndc reload`, which rereads the config and every changed zone without dropping a query, and sends NOTIFY for each zone whose serial went up.

Secondaries keep their copies in `/var/cache/bind` on Debian and Ubuntu, `/var/named/slaves` on the Red Hat family, both written by BIND itself.

The config replaces the distribution's own `named.conf`. Debian's `named.conf.options` and `named.conf.local` are no longer read, and neither are the Red Hat family's `named.rfc1912.zones` and root hints, which only matter to recursion. The Red Hat family's system-wide crypto policy is still included. `rndc` keeps working as root through the key each distribution makes on its own.

On Fedora, the package installs BIND's unit as `bind.service` and points `named.service` at it through alternatives, which systemd sees as a second unit of its own. The circuit manages `bind.service` there, and `named` everywhere else.

### BIND versions

The circuit uses each distribution's package, so the version follows the distribution, and there's no version to pin. On the hosts tested:

| Distribution | BIND |
| --- | --- |
| Ubuntu 24.04 | 9.18.39 |
| Debian 13 | 9.20.30 |
| Rocky Linux 10 | 9.18.33 |
| Fedora 45 | 9.18.50 |

### What it doesn't do

- It doesn't sign zones with DNSSEC or take dynamic updates.
- It doesn't open the firewall for port 53, UDP and TCP. See [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for that.
- It has no views, so every client sees the same answers.
- Removing a zone from `zones` stops BIND serving it but leaves its file on the host. Deleting the module leaves BIND installed and running with the last config.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `zones` | map(object) | `{}` | Zones BIND serves, by name, such as `"example.com"`. Each has a `type`, `primary` or `secondary`. A primary has `records`, a list of `{ name, type, ttl, value }` with `ttl` optional, among them at least one `NS`. A secondary has `primaries`, the primaries' IP addresses, and optionally `key`, the name of a `tsig_keys` key to sign its transfers with. Either can have `allow_transfer`, a list of BIND address match elements such as `"key transfer"` or `"198.51.100.10"`, and `also_notify`, a list of IP addresses. |
| `tsig_keys` | map(string) | `{}` | TSIG keys for zone transfers, by name, with each key's base64 secret. Sensitive: with any set, the config is written with `content_wo` and kept out of state and the plan. |
| `soa` | object | see description | SOA fields for primary zones: `mname`, by default the zone's first `NS` record at `@`; `rname`, the contact's mailbox with a dot for the `@`, default `"hostmaster"`, relative to the zone; `refresh` `3600`, `retry` `900`, `expire` `1209600` and `minimum` `300`, in seconds. The serial is set on the host. See [The serial](#the-serial). |
| `default_ttl` | number | `3600` | TTL, in seconds, for records without their own. |
| `listen_on` | list(string) | `["any"]` | Addresses BIND answers on, port 53. `"any"` means every IPv4 and IPv6 address. |
| `recursion` | bool | `false` | Resolve other names too, for the host and its own networks. Off, anything outside the zones is refused. |

## Outputs

| Name | Description |
| --- | --- |
| `config_files` | Path of the `named.conf` the circuit writes on each host, by host name, such as `{ ns1 = "/etc/named.conf" }`. |
| `zone_files` | Path of each zone's file on each host, by host name, then zone, such as `{ ns1 = { "example.com" = "/var/named/example.com.zone" } }`. |

## Requirements

Requires Conn3x v0.6.7 or later and systemd on each host, with a package mirror the host can reach. Secondaries need to reach their primaries on TCP port 53, and primaries need to reach their secondaries on UDP port 53 for NOTIFY.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to a primary and a secondary on amd64, pairing each distribution with a different one in each role: Rocky Linux 10 with Ubuntu 24.04 and Debian 13 with Fedora 45, both ways round, and checks that the second plan has no changes. It then checks that both answer the zone's `A`, `MX`, `TXT` and `CNAME` records with the `aa` flag and the same serial, that a missing name gets `NXDOMAIN`, that a name outside the zone is `REFUSED`, that an unsigned transfer is refused and that the secondary's came signed with the key. Then it changes a record, checks that the serial went up and the secondary answers with the new record, and that the plan is clean again. The same four pairs passed in Podman on arm64, as did a primary and a secondary both on Debian 13, both on Ubuntu 24.04 and both on Rocky Linux 10.

On droplets, a Rocky Linux 10 primary and an Ubuntu 24.04 secondary passed the same checks over their public addresses, queried from each droplet in turn, with the secondary picking up a changed record from the primary's NOTIFY. Both still answered after a reboot, with the plan still at no changes. Rocky Linux ran with SELinux enforcing: BIND ran confined as `named_t`, and the audit log had no denials. On Ubuntu, BIND ran under its AppArmor profile beside systemd-resolved's stub.

With `recursion` on and `listen_on` set to `127.0.0.1`, on Rocky Linux 10, `example.com` came back with the `ad` flag, `dnssec-failed.org` with `SERVFAIL`, and the container's own address refused the connection.

A record that fails `named-checkzone` was tried on Ubuntu 24.04: the apply stopped with BIND's error and the live zone stayed in place. A hand edit to the live zone and to `named.conf` was put back on the next apply, the zone under a higher serial.

## License

MPL-2.0. See [LICENSE](LICENSE). BIND itself is MPL-2.0 too.

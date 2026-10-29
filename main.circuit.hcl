# Facts give each host's distribution. Debian and Ubuntu keep BIND's config
# in /etc/bind and run it as bind; the Red Hat family uses /etc/named.conf
# and /var/named and runs it as named.
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
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  debian = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) }

  # Fedora installs BIND's unit as bind.service and points named.service at
  # it through alternatives, which systemd sees as a second, separate unit
  # that can't be enabled. The real one is the one to manage.
  unit = { for name, o in local.os : name => o == "fedora" ? "bind" : "named" }

  group         = { for name, d in local.debian : name => d ? "bind" : "named" }
  conf          = { for name, d in local.debian : name => d ? "/etc/bind/named.conf" : "/etc/named.conf" }
  directory     = { for name, d in local.debian : name => d ? "/var/cache/bind" : "/var/named" }
  primary_dir   = { for name, d in local.debian : name => d ? "/var/lib/bind" : "/var/named" }
  secondary_dir = { for name, d in local.debian : name => d ? "/var/cache/bind" : "/var/named/slaves" }

  zones         = { for name, z in var.zones : trimsuffix(lower(name), ".") => z }
  primary_zones = { for name, z in local.zones : name => z if z.type == "primary" }
  zone_file = { for host in keys(var.hosts) : host => {
    for name, z in local.zones : name => "${z.type == "primary" ? local.primary_dir[host] : local.secondary_dir[host]}/${name}.zone"
  } }

  has_secret = nonsensitive(length(var.tsig_keys) > 0)

  listen_v4 = [for a in var.listen_on : a if a == "any" || !strcontains(a, ":")]
  listen_v6 = [for a in var.listen_on : a if a == "any" || strcontains(a, ":")]

  # The serial is left as a placeholder here. The host fills it in, so a
  # plan never depends on the clock and the serial only moves when the
  # records do.
  zone_content = { for name, z in local.primary_zones : name => join("\n", concat(
    [
      "; Written by Conn3x. Changes here are overwritten on the next apply.",
      "$ORIGIN ${name}.",
      "$TTL ${var.default_ttl}",
      "@ IN SOA ${coalesce(var.soa.mname, try([for r in z.records : r.value if upper(r.type) == "NS" && contains(["@", "${name}."], lower(r.name))][0], "ns1"))} ${var.soa.rname} (",
      "    CONN3X_SERIAL ; serial",
      "    ${var.soa.refresh} ; refresh",
      "    ${var.soa.retry} ; retry",
      "    ${var.soa.expire} ; expire",
      "    ${var.soa.minimum} ; minimum",
      ")",
    ],
    # A TXT value without quotes gets them, so spaces stay in one string.
    [for r in z.records : join(" ", compact([
      r.name,
      r.ttl == null ? "" : tostring(r.ttl),
      "IN",
      upper(r.type),
      upper(r.type) == "TXT" && !startswith(r.value, "\"") ? "\"${r.value}\"" : r.value,
    ]))],
    [""],
  )) }

  config = { for host, d in local.debian : host => join("\n", concat(
    [
      "// Written by Conn3x. Changes here are overwritten on the next apply.",
      "options {",
      "    directory \"${local.directory[host]}\";",
      "    pid-file \"/run/named/named.pid\";",
      "    listen-on port 53 { ${length(local.listen_v4) > 0 ? join("; ", local.listen_v4) : "none"}; };",
      "    listen-on-v6 port 53 { ${length(local.listen_v6) > 0 ? join("; ", local.listen_v6) : "none"}; };",
      "    recursion ${var.recursion ? "yes" : "no"};",
      # Validation only matters to recursion. Off, it would still fetch
      # the root's keys.
      "    dnssec-validation ${var.recursion ? "auto" : "no"};",
      "    allow-transfer { none; };",
    ],
    # The system-wide crypto policy, as the Red Hat family's own named.conf
    # includes it.
    d ? [] : ["    include \"/etc/crypto-policies/back-ends/bind.config\";"],
    ["};", ""],
    local.has_secret ? [for k, s in var.tsig_keys : "key \"${k}\" {\n    algorithm hmac-sha256;\n    secret \"${s}\";\n};\n"] : [],
    [for name, z in local.zones : "${join("\n", compact(concat(
      [
        "zone \"${name}\" {",
        "    type ${z.type};",
        "    file \"${local.zone_file[host][name]}\";",
      ],
      z.type == "secondary" ? ["    primaries { ${join(" ", [for p in z.primaries : "${p}${z.key == null ? "" : " key ${z.key}"};"])} };"] : [],
      length(z.allow_transfer) > 0 ? ["    allow-transfer { ${join(" ", [for a in z.allow_transfer : "${a};"])} };"] : [],
      length(z.also_notify) > 0 ? ["    also-notify { ${join(" ", [for a in z.also_notify : "${a};"])} };"] : [],
      ["};"],
    )))}\n"],
  )) }
}

circuit "bind" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = local.debian[each.key] ? "bind9" : "bind"
    }
  }

  # Each primary zone lands beside its live file first, with the serial
  # still a placeholder.
  step "zone_candidate" {
    for_each = local.primary_zones
    file {
      path    = "${local.zone_file[each.key][item.key]}.conn3x"
      content = local.zone_content[item.key]
    }
  }

  # Fills in the serial and puts the zone in place once named-checkzone
  # accepts it. The serial is today's date and a two-digit count,
  # YYYYMMDDnn, or one more than the live file's when that is already as
  # high, so it only ever goes up and secondaries see the change. When the
  # live file already holds the records, under its own serial, nothing
  # happens. A hand edit to the live file is put back, with a new serial.
  step "zone" {
    for_each = local.primary_zones
    command {
      command  = <<-EOT
        live=${local.zone_file[each.key][item.key]}
        old=$(awk '$2 == ";" && $3 == "serial" { print $1; exit }' "$live" 2>/dev/null)
        new=$(date -u +%Y%m%d)00
        if [ -n "$old" ] && [ "$old" -ge "$new" ]; then new=$((old + 1)); fi
        sed "s/CONN3X_SERIAL/$new/" "$live.conn3x" > "$live.new"
        if ! named-checkzone ${item.key} "$live.new"; then rm -f "$live.new"; exit 1; fi
        chgrp ${local.group[each.key]} "$live.new"
        chmod 640 "$live.new"
        mv "$live.new" "$live"
        if command -v restorecon >/dev/null; then restorecon "$live"; fi
      EOT
      unless   = <<-EOT
        live=${local.zone_file[each.key][item.key]}
        old=$(awk '$2 == ";" && $3 == "serial" { print $1; exit }' "$live" 2>/dev/null)
        [ -n "$old" ] && sed "s/CONN3X_SERIAL/$old/" "$live.conn3x" | cmp -s - "$live"
      EOT
      triggers = { candidate = conn3x_file.bind__zone_candidate["${each.key}/${item.key}"].revision }
    }
    notify = [handler.reload]
  }

  # With TSIG keys in it, the config goes through content_wo, which keeps
  # the secrets out of state and out of the plan; without them, the plan
  # shows the diff.
  step "config_candidate" {
    for_each = local.has_secret ? [] : ["config"]
    file {
      path    = "${local.conf[each.key]}.conn3x"
      content = local.config[each.key]
      mode    = "0600"
    }
  }

  step "config_candidate_secret" {
    for_each = local.has_secret ? ["config"] : []
    file {
      path       = "${local.conf[each.key]}.conn3x"
      content_wo = local.config[each.key]
      mode       = "0600"
    }
  }

  # Copies the candidate over the live config only once named-checkconf
  # accepts it, so a typo or a missing key never reaches the running
  # server. named reads the file as its own user on a reload, so the group
  # gets read access. Also puts the file back after a hand edit.
  step "config" {
    command {
      command  = <<-EOT
        named-checkconf ${local.conf[each.key]}.conn3x
        install -m 640 -o root -g ${local.group[each.key]} ${local.conf[each.key]}.conn3x ${local.conf[each.key]}
        if command -v restorecon >/dev/null; then restorecon ${local.conf[each.key]}; fi
      EOT
      unless   = "[ \"$(sha256sum < ${local.conf[each.key]}.conn3x)\" = \"$(sha256sum < ${local.conf[each.key]})\" ]"
      triggers = { candidate = try(conn3x_file.bind__config_candidate["${each.key}/config"].revision, conn3x_file.bind__config_candidate_secret["${each.key}/config"].revision) }
    }
    notify = [handler.reload]
  }

  # Debian and Ubuntu answer to bind9 as well, an alias of named.
  step "running" {
    service {
      name    = local.unit[each.key]
      state   = "started"
      enabled = true
    }
  }

  # The unit's reload runs rndc reload, which rereads the config and every
  # changed zone without dropping a query, and sends NOTIFY to secondaries
  # for each zone whose serial went up.
  handler "reload" {
    service {
      name   = local.unit[each.key]
      action = "reload"
    }
  }
}

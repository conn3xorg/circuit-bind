variable "port" {
  type    = number
  default = 2222
}

# The second container's SSH port. Leave it null to try the primary alone.
variable "secondary_port" {
  type    = number
  default = null
}

# Each container's address on Podman's network, where the two talk to each
# other, from `podman inspect`.
variable "primary_address" {
  type    = string
  default = "10.88.0.2"
}

variable "secondary_address" {
  type    = string
  default = "10.88.0.3"
}

# Make one with `openssl rand -base64 32`.
variable "tsig_secret" {
  type      = string
  sensitive = true
}

# CI changes this to see the serial go up and the secondary follow.
variable "www_address" {
  type    = string
  default = "192.0.2.10"
}

locals {
  secondary = var.secondary_port == null ? {} : { secondary = { address = "127.0.0.1", port = var.secondary_port } }
}

module "primary" {
  source = "../.."

  hosts                = { primary = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  tsig_keys = { transfer = var.tsig_secret }

  zones = {
    "example.test" = {
      type = "primary"
      records = [
        { name = "@", type = "NS", value = "ns1" },
        { name = "@", type = "MX", value = "10 mail" },
        { name = "@", type = "TXT", value = "v=spf1 mx -all" },
        { name = "ns1", type = "A", value = var.primary_address },
        { name = "www", type = "A", ttl = 300, value = var.www_address },
        { name = "mail", type = "A", value = "192.0.2.25" },
        { name = "docs", type = "CNAME", value = "www" },
      ]
      allow_transfer = ["key transfer"]
      also_notify    = var.secondary_port == null ? [] : [var.secondary_address]
    }
  }

  soa = { rname = "hostmaster.example.test." }
}

# The secondary asks for the zone signed with the same key. The two apply
# side by side: whichever starts second, the secondary's first try or the
# primary's NOTIFY finds the other ready.
module "secondary" {
  source = "../.."

  hosts                = local.secondary
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  tsig_keys = { transfer = var.tsig_secret }

  zones = {
    "example.test" = {
      type      = "secondary"
      primaries = [var.primary_address]
      key       = "transfer"
    }
  }
}

output "config_files" {
  value = merge(module.primary.config_files, module.secondary.config_files)
}

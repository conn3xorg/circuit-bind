variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "zones" {
  type = map(object({
    type = string
    records = optional(list(object({
      name  = string
      type  = string
      ttl   = optional(number)
      value = string
    })), [])
    primaries      = optional(list(string), [])
    key            = optional(string)
    allow_transfer = optional(list(string), [])
    also_notify    = optional(list(string), [])
  }))
  default     = {}
  description = "Zones BIND serves, by name, such as { \"example.com\" = { type = \"primary\", records = [...] } }. A primary holds records; a secondary copies the zone from its primaries."

  validation {
    condition     = alltrue([for z in keys(var.zones) : can(regex("^([A-Za-z0-9_-]+\\.)*[A-Za-z0-9_-]+\\.?$", z))])
    error_message = "zones keys must be domain names, such as \"example.com\" or \"1.168.192.in-addr.arpa\"."
  }

  validation {
    condition     = alltrue([for z in values(var.zones) : contains(["primary", "secondary"], z.type)])
    error_message = "Each zone's type must be primary or secondary."
  }

  validation {
    condition     = alltrue([for z in values(var.zones) : z.type == "primary" ? length(z.primaries) == 0 && length([for r in z.records : r if r.type == "NS"]) > 0 : length(z.records) == 0 && length(z.primaries) > 0])
    error_message = "A primary zone needs records, NS records among them, and no primaries. A secondary zone needs primaries and no records."
  }

  validation {
    condition = alltrue(flatten([for z in values(var.zones) : [for r in z.records : (
      can(regex("^[A-Za-z0-9_.*@-]+$", r.name)) && can(regex("^[A-Za-z0-9]+$", r.type)) && !strcontains(r.value, "\n") && length(trimspace(r.value)) > 0
    )]]))
    error_message = "Each record has a name such as \"www\", \"@\" or \"www.example.com.\", a type such as \"A\" or \"MX\", and a one-line value."
  }

  validation {
    condition     = alltrue(flatten([for z in values(var.zones) : [for a in concat(z.primaries, z.also_notify) : can(regex("^[0-9A-Fa-f.:]+$", a))]]))
    error_message = "primaries and also_notify hold IP addresses, such as \"192.0.2.1\"."
  }

  validation {
    condition     = alltrue([for z in values(var.zones) : z.key == null || contains(nonsensitive(keys(var.tsig_keys)), z.key)])
    error_message = "A zone's key must be one of the names in tsig_keys."
  }

  validation {
    condition     = alltrue(flatten([for z in values(var.zones) : [for a in z.allow_transfer : !strcontains(a, ";") && !strcontains(a, "\n") && !strcontains(a, "{")]]))
    error_message = "Each allow_transfer entry is one element of a BIND address match list, such as \"192.0.2.2\", \"key transfer\" or \"none\", without semicolons."
  }
}

variable "tsig_keys" {
  type        = map(string)
  default     = {}
  sensitive   = true
  description = "TSIG keys for zone transfers, by name, with each key's base64 secret, as tsig-keygen prints it. They use hmac-sha256. The config is written with content_wo when any are set, so the secrets stay out of state and the plan."

  validation {
    condition     = alltrue([for name, secret in var.tsig_keys : can(regex("^[A-Za-z0-9_.-]+$", name)) && can(regex("^[A-Za-z0-9+/]+={0,2}$", secret))])
    error_message = "tsig_keys maps names such as \"transfer\" to base64 secrets, such as tsig-keygen or `openssl rand -base64 32` prints."
  }
}

variable "soa" {
  type = object({
    mname   = optional(string)
    rname   = optional(string, "hostmaster")
    refresh = optional(number, 3600)
    retry   = optional(number, 900)
    expire  = optional(number, 1209600)
    minimum = optional(number, 300)
  })
  default     = {}
  description = "SOA fields for primary zones. mname defaults to the zone's first NS record at the apex. rname is the contact's mailbox with the @ as a dot, such as \"hostmaster.example.com.\", or a name relative to the zone. The serial is set on the host."

  validation {
    condition     = (var.soa.mname == null || can(regex("^[A-Za-z0-9_.-]+$", var.soa.mname))) && can(regex("^[A-Za-z0-9_.-]+$", var.soa.rname))
    error_message = "soa mname and rname are domain names, such as \"ns1.example.com.\" and \"hostmaster.example.com.\"."
  }
}

variable "default_ttl" {
  type        = number
  default     = 3600
  description = "TTL, in seconds, for records that don't give their own."
}

variable "listen_on" {
  type        = list(string)
  default     = ["any"]
  description = "Addresses BIND answers on, port 53. \"any\" means every IPv4 and IPv6 address."

  validation {
    condition     = length(var.listen_on) > 0 && alltrue([for a in var.listen_on : a == "any" || can(cidrhost("${a}/${strcontains(a, ":") ? 128 : 32}", 0))])
    error_message = "listen_on holds \"any\" or IP addresses, such as \"192.0.2.1\" or \"::1\"."
  }
}

variable "recursion" {
  type        = bool
  default     = false
  description = "Answer recursive queries too, for localhost and the host's own networks only. Off, BIND answers only for its own zones and refuses everything else. For a resolver, circuit-unbound is the better fit."
}

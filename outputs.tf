output "config_files" {
  description = "Path of the named.conf the circuit writes on each host, by host name."
  value       = local.conf
}

output "zone_files" {
  description = "Path of each zone's file on each host, by host name, then zone."
  value       = local.zone_file
}

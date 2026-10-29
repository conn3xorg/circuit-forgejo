output "config_file" {
  description = "Path of the configuration file the circuit writes on each host."
  value       = "/etc/forgejo/app.ini"
}

output "urls" {
  description = "Each host's ROOT_URL, by host name."
  value       = local.root_url
}

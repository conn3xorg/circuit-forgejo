variable "port" {
  type    = number
  default = 2222
}

# Pass it at run time, such as with TF_VAR_admin_password.
variable "admin_password" {
  type      = string
  sensitive = true
}

module "forgejo" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  domain         = "git.example.test"
  admin_username = "forgejo-admin"
  admin_email    = "admin@example.test"
  admin_password = var.admin_password
}

output "urls" {
  value = module.forgejo.urls
}

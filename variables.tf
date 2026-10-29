variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
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

variable "forgejo_version" {
  type        = string
  default     = "17.0.1"
  description = "Forgejo release to install, without the leading v."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.forgejo_version))
    error_message = "forgejo_version must be a release number such as \"17.0.1\", without the leading v."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the release binary for each architecture, x86_64 and aarch64, from the .sha256 files on the release page. Change these with forgejo_version."
  default = {
    x86_64  = "51a8cdf4a1252e79f4b3855d7a7891af6c6635105420768c460e2f0690385d6f"
    aarch64 = "1e99403746406e8199efc903ddd1940d5728a60e50241f7aa6c9f2b907bd8ec9"
  }

  validation {
    condition     = alltrue([for a, c in var.checksums : contains(["x86_64", "aarch64"], a) && can(regex("^[0-9a-f]{64}$", c))])
    error_message = "checksums maps x86_64 or aarch64 to a SHA-256 in lowercase hex."
  }
}

variable "app_name" {
  type        = string
  default     = "Forgejo"
  description = "Name shown in page titles and emails."

  validation {
    condition     = length(var.app_name) > 0 && !strcontains(var.app_name, "\n")
    error_message = "app_name must be one line of text."
  }
}

variable "domain" {
  type        = string
  default     = null
  description = "Host name people reach Forgejo by, used in clone URLs. When null, each host's address."

  validation {
    condition     = var.domain == null || can(regex("^[A-Za-z0-9.-]+$", coalesce(var.domain, "-")))
    error_message = "domain must be a host name or an IPv4 address, such as \"git.example.com\"."
  }
}

variable "root_url" {
  type        = string
  default     = null
  description = "Public URL of Forgejo, with a trailing slash, such as \"https://git.example.com/\" behind a TLS proxy. When null, http://DOMAIN:HTTP_PORT/."

  validation {
    condition     = var.root_url == null || can(regex("^https?://[^\\s]+/$", coalesce(var.root_url, "-")))
    error_message = "root_url must be an http or https URL ending in /."
  }
}

variable "http_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the web interface and API listen on. The default keeps Forgejo to the host itself, for a proxy in front; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.http_address}/${strcontains(var.http_address, ":") ? 128 : 32}", 0))
    error_message = "http_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "http_port" {
  type        = number
  default     = 3000
  description = "Port of the web interface and API."

  validation {
    condition     = var.http_port >= 1 && var.http_port <= 65535 && floor(var.http_port) == var.http_port
    error_message = "http_port must be a port number from 1 to 65535."
  }
}

variable "git_ssh_port" {
  type        = number
  default     = 22
  description = "SSH port shown in clone URLs. With builtin_ssh_server, also the port Forgejo's own SSH server listens on."

  validation {
    condition     = var.git_ssh_port >= 1 && var.git_ssh_port <= 65535 && floor(var.git_ssh_port) == var.git_ssh_port
    error_message = "git_ssh_port must be a port number from 1 to 65535."
  }
}

variable "builtin_ssh_server" {
  type        = bool
  default     = false
  description = "Run Forgejo's own SSH server on git_ssh_port. When false, the host's sshd serves git over SSH as the git user."
}

variable "disable_registration" {
  type        = bool
  default     = true
  description = "Stop people creating their own accounts. The admin can still create them."
}

variable "postgres" {
  type = object({
    host     = optional(string, "127.0.0.1:5432")
    name     = optional(string, "forgejo")
    user     = optional(string, "forgejo")
    ssl_mode = optional(string, "disable")
  })
  default     = null
  description = "PostgreSQL to keep Forgejo's data in, such as { host = \"db1:5432\" }. The database and role must exist. When null, Forgejo uses SQLite in its data directory."

  validation {
    condition     = var.postgres == null || alltrue([for v in values(coalesce(var.postgres, {})) : can(regex("^[A-Za-z0-9_./:@\\[\\]-]+$", v))])
    error_message = "postgres host, name and user may use letters, digits and . _ - / : @ [ ]."
  }

  validation {
    condition     = var.postgres == null || contains(["disable", "require", "verify-ca", "verify-full"], try(var.postgres.ssl_mode, ""))
    error_message = "postgres ssl_mode must be one of disable, require, verify-ca or verify-full."
  }
}

variable "postgres_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password of the postgres user. Needed with postgres. Pass it at run time with -var or TF_VAR_postgres_password; it never reaches state or the plan."

  validation {
    condition     = var.postgres == null || length(coalesce(var.postgres_password, "")) > 0
    error_message = "postgres needs postgres_password."
  }

  validation {
    condition     = !strcontains(coalesce(var.postgres_password, "-"), "`") && !strcontains(coalesce(var.postgres_password, "-"), "\n")
    error_message = "postgres_password can't hold a backtick or a newline."
  }
}

variable "admin_username" {
  type        = string
  description = "Name of the admin user the circuit creates. Forgejo reserves some names, such as admin."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$", var.admin_username)) && !contains(["admin", "api", "user", "explore", "org", "repo"], lower(var.admin_username))
    error_message = "admin_username must start with a letter or digit, use only letters, digits, _, . and -, and not be a name Forgejo reserves, such as admin."
  }
}

variable "admin_email" {
  type        = string
  description = "Email address of the admin user."

  validation {
    condition     = can(regex("^[^@\\s'\"]+@[^@\\s'\"]+$", var.admin_email))
    error_message = "admin_email must be an email address."
  }
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "Password of the admin user, at least 8 characters. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan. Changing it sets the new one."

  validation {
    condition     = length(var.admin_password) >= 8 && !strcontains(var.admin_password, "\n")
    error_message = "admin_password must be at least 8 characters, on one line."
  }
}

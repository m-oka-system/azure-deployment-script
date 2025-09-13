variable "allowed_cidr" {
  type = list(string)
}

variable "common" {
  type = map(string)
  default = {
    project  = "scripts"
    location = "japaneast"
  }
}

variable "env" {
  type    = string
  default = "dev"
}

variable "az_cli_version" {
  type    = string
  default = "2.52.0"
}

variable "tf_version" {
  type    = string
  default = "1.13.2"
}

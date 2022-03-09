
variable "project" {
  type = string
}

variable "nameprefix" {
  type = string
}

variable "region" {
  type = string
  default = "us-central1"
}

variable "zone" {
  type = string
  default = "us-central1-a"
}

variable "db_password" {
  type = string
  sensitive = true
}

variable "db_tier" {
  type = string
  default = "db-f1-micro"
}

variable "vm_class" {
  type = string
  default = "e2-small"
}

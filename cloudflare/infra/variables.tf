variable "account_id" {
  type        = string
  description = "Cloudflare account selected by the project environment."
  validation {
    condition     = can(regex("^[a-fA-F0-9]{32}$", var.account_id))
    error_message = "Select a valid Cloudflare account."
  }
}

variable "bucket_name" {
  type    = string
  default = "maps"
}

variable "bucket_location" {
  type    = string
  default = "weur"
}

variable "state_bucket_name" {
  type    = string
  default = "sunoh-terraform-state"
}

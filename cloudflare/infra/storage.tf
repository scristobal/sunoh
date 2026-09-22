resource "cloudflare_r2_bucket" "maps" {
  account_id    = var.account_id
  name          = var.bucket_name
  location      = var.bucket_location
  storage_class = "Standard"
  jurisdiction  = "default"
  lifecycle { prevent_destroy = true }
}

resource "cloudflare_r2_bucket" "state" {
  account_id    = var.account_id
  name          = var.state_bucket_name
  location      = var.bucket_location
  storage_class = "Standard"
  jurisdiction  = "default"

  lifecycle {
    prevent_destroy = true
  }
}

# The provider cannot import this resource. Applying enabled=false adopts the
# already-disabled public endpoint without exposing or replacing the bucket.
resource "cloudflare_r2_managed_domain" "maps" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.maps.name
  enabled     = false
}

resource "cloudflare_r2_managed_domain" "state" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.state.name
  enabled     = false
}

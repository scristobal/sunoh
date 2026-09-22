variable "service_tokens" {
  description = "Named service credentials. Creation and rotation happen through Terraform."
  type        = map(object({ duration = string }))
  default     = {}
}

resource "cloudflare_zero_trust_access_service_token" "clients" {
  for_each   = var.service_tokens
  account_id = var.account_id
  name       = each.key
  duration   = each.value.duration

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_zero_trust_access_policy" "readers" {
  account_id = var.account_id
  name       = "Sunō tile clients"
  decision   = "non_identity"
  include = [for token in cloudflare_zero_trust_access_service_token.clients : {
    service_token = { token_id = token.id }
  }]
}

resource "cloudflare_zero_trust_access_application" "tiles" {
  account_id                 = var.account_id
  name                       = "Sunō tiles"
  type                       = "self_hosted"
  app_launcher_visible       = true
  auto_redirect_to_identity  = false
  enable_binding_cookie      = false
  http_only_cookie_attribute = true
  options_preflight_bypass   = false
  session_duration           = "24h"

  destinations = [{
    type      = "worker"
    worker_id = cloudflare_worker.tiles.id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.readers.id
    precedence = 1
  }]

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length(var.service_tokens) > 0
      error_message = "Keep at least one service token declared for the protected Worker."
    }
  }
}

output "service_tokens" {
  sensitive = true
  value = { for name, token in cloudflare_zero_trust_access_service_token.clients : name => {
    id            = token.id
    account_id    = var.account_id
    client_id     = token.client_id
    client_secret = token.client_secret
    expires_at    = token.expires_at
  } }
}

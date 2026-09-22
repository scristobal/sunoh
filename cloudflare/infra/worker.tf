resource "cloudflare_worker" "tiles" {
  account_id     = var.account_id
  name           = "tiles"
  logpush        = false
  tags           = []
  tail_consumers = []
  subdomain      = { enabled = true, previews_enabled = true }
  observability = {
    enabled            = false
    head_sampling_rate = 1
    logs               = { enabled = false, head_sampling_rate = 1, invocation_logs = true, persist = true, destinations = [] }
    traces             = { enabled = false, head_sampling_rate = 1, persist = true, destinations = [] }
  }
  lifecycle { prevent_destroy = true }
}

resource "cloudflare_worker_version" "tiles" {
  account_id         = var.account_id
  worker_id          = cloudflare_worker.tiles.id
  compatibility_date = "2026-09-10"
  main_module        = "serve.js"
  bindings = [
    { name = "BUCKET", type = "r2_bucket", bucket_name = cloudflare_r2_bucket.maps.name },
    { name = "VERSION", type = "version_metadata" }
  ]
  modules = [{ name = "serve.js", content_type = "application/javascript+module", content_base64 = sensitive(filebase64("${path.module}/../worker/dist/serve.js")) }]
  lifecycle { create_before_destroy = true }
}

resource "cloudflare_workers_deployment" "tiles" {
  account_id  = var.account_id
  script_name = cloudflare_worker.tiles.name
  strategy    = "percentage"
  versions    = [{ version_id = cloudflare_worker_version.tiles.id, percentage = 100 }]
}

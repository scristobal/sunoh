output "worker_url" {
  value = cloudflare_worker.tiles.subdomain.url
}

output "deployment_id" {
  value = cloudflare_workers_deployment.tiles.id
}

output "version_id" {
  value = cloudflare_worker_version.tiles.id
}

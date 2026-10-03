output "project_summary" {
  description = "Readable summary for workspace and output screens."
  value       = local.description
}
output "service_urls" {
  description = "A public map with one URL per service."
  value       = { for name, service in terraform_data.service : name => service.output.url }
}
output "nested" {
  description = "Public nested data: objects, lists, null, empty strings, booleans and Unicode."
  value = {
    profile  = var.profile
    tags     = var.tags
    features = var.features
    note     = var.optional_note
    empty    = var.empty_label
    regions  = { for name, region in module.region : name => region.summary }
    unicode  = "Hello, 世界 👋"
  }
}
output "catalog" {
  description = "Public outputs read from a separate local state through a data source."
  value       = data.terraform_remote_state.catalog.outputs
}
output "demo_secret" {
  description = "Entire output is sensitive and must stay hidden. This token is fake."
  value       = var.demo_token
  sensitive   = true
}
output "sensitive_bundle" {
  description = "The whole object is marked sensitive, including its otherwise public label."
  value       = { label = "Demo account", token = var.demo_token }
  sensitive   = true
}
output "worker_ids" {
  description = "Computed IDs become known after apply."
  value       = terraform_data.worker[*].id
}

variable "name" { type = string }
variable "generation" { type = number }
resource "terraform_data" "endpoint" {
  input = { region = var.name, generation = var.generation, enabled = true }
}
resource "terraform_data" "zone" {
  for_each = toset(["zone.a", "zone.b"])
  input    = { region = var.name, zone = each.key, generation = var.generation }
}
module "metrics" {
  source     = "../metrics"
  region     = var.name
  generation = var.generation
}
output "summary" {
  value = { name = var.name, endpoint = terraform_data.endpoint.output, metrics = module.metrics.summary }
}

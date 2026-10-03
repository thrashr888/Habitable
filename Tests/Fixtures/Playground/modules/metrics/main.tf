variable "region" { type = string }
variable "generation" { type = number }
resource "terraform_data" "collector" {
  input = { region = var.region, generation = var.generation, interval = 30 }
}
output "summary" { value = terraform_data.collector.output }

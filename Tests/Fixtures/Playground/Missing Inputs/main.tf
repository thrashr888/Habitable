terraform { required_version = ">= 1.4, < 2.0" }
variable "owner" {
  type        = string
  description = "Required owner: enter a value in Habitable's Variables page."
}
variable "capacity" {
  type        = number
  description = "Required numeric capacity: try the typed number editor."
}
variable "demo_password" {
  type        = string
  sensitive   = true
  description = "Required sensitive value. Enter a fake test password only."
}
resource "terraform_data" "example" {
  input = { owner = var.owner, capacity = var.capacity }
}
output "summary" { value = terraform_data.example.output }
output "demo_password" {
  value     = var.demo_password
  sensitive = true
}

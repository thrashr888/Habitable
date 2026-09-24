terraform {
  required_version = ">= 1.4.0"
}

# Built into Terraform: no provider download, credentials, or cloud resources.
resource "terraform_data" "welcome" {
  input = "Habitable is running again."
}

output "greeting" {
  value = terraform_data.welcome.output
}

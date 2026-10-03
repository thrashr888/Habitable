terraform { required_version = ">= 1.4, < 2.0" }
# Intentionally invalid references for testing source-linked error diagnostics.
resource "terraform_data" "broken" {
  input = var.missing_declaration
}
output "broken_reference" {
  value = terraform_data.not_declared.output
}

resource "terraform_data" "replace_after_destroy" {
  input            = "Default replacement ordering"
  triggers_replace = var.scenario_generation
}
resource "terraform_data" "replace_before_destroy" {
  input            = "Create-before-destroy replacement ordering"
  triggers_replace = var.scenario_generation
  lifecycle {
    create_before_destroy = true
  }
}

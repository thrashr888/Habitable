# Reads a separate local state created by the playground setup.
data "terraform_remote_state" "catalog" {
  backend = "local"
  config = {
    path = "${path.module}/state-source/terraform.tfstate"
  }
}

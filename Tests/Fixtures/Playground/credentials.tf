# Synthetic secret: exercise selective resource masking alongside public fields.
resource "terraform_data" "demo_account" {
  input = {
    username = "playground-user"
    contact  = "tester@example.invalid"
    auth     = { token = var.demo_token, method = "fake-token" }
  }
}

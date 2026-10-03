locals {
  services = {
    api    = { port = 8080, public = false }
    web    = { port = 3000, public = true }
    worker = { port = 9000, public = false }
  }
  description = "${var.project_name} · ${var.environment} · owned by ${var.owner}"
}

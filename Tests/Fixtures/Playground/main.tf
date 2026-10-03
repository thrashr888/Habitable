# These resources store local metadata in state. They do not provision infrastructure.
resource "terraform_data" "workspace" {
  input = {
    description = local.description
    generation  = var.scenario_generation
    tags        = var.tags
    features    = var.features
    profile     = var.profile
    note        = var.optional_note
    empty_label = var.empty_label
  }
}
resource "terraform_data" "service" {
  for_each = local.services
  input = {
    name       = each.key
    port       = each.value.port
    public     = each.value.public
    generation = var.scenario_generation
    url        = "https://${each.key}.example.invalid"
  }
}
resource "terraform_data" "worker" {
  count = var.replicas
  input = {
    index      = count.index
    label      = "worker-${count.index + 1}"
    generation = var.scenario_generation
  }
}
resource "terraform_data" "optional" {
  count = var.enable_optional ? 1 : 0
  input = "Toggle enable_optional to add or remove this local record."
}

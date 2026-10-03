# Setup seeds the old address, then restores this file for a mixed-change plan.
moved {
  from = terraform_data.legacy
  to   = terraform_data.renamed
}
resource "terraform_data" "renamed" {
  input = { label = "A renamed local record" }
}
resource "terraform_data" "new_feature" {
  input = { label = "New feature", generation = var.scenario_generation }
}
# terraform_data import is local bookkeeping; this is a synthetic ID.
import {
  to = terraform_data.imported
  id = "00000000-0000-4000-8000-000000000001"
}
resource "terraform_data" "imported" {}

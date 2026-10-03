module "region" {
  for_each   = var.regions
  source     = "./modules/region"
  name       = each.key
  generation = var.scenario_generation
}

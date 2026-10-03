terraform { required_version = ">= 1.4, < 2.0" }
output "service_names" { value = ["api", "web", "worker"] }
output "catalog_version" { value = 1 }

terraform {
  cloud {
    organization = "pthrasher_v2"

    workspaces {
      name = "habitable-et3-20261002"
    }
  }
}

output "backend_qa_value" {
  value = "remote-output-loaded-in-habitable"
}

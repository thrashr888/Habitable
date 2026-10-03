check "public_services" {
  assert {
    condition     = local.services.web.public
    error_message = "The demo web service should be public."
  }
}

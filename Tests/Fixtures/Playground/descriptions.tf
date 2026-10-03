# A longer source file for testing Find, line numbers, scrolling and diagnostics.
locals {
  onboarding_notes = <<-NOTES
    This playground has no cloud provider and needs no cloud credentials.
    Terraform configuration describes desired state.
    A plan previews differences between the configuration and saved state.
    Apply performs the approved changes.
    These examples only change local metadata and local state.

    Try searching for scenario_generation, description, or terraform_data.
    Try Go to Line on a file with an emoji or a Unicode module key.
    Try changing project_name and saving to trigger automatic validation.
    Try an invalid environment value to produce a source-linked diagnostic.
    Try changing replicas to add or remove counted resources.
    Try enable_optional to test zero-count resources.
    Try optional_note = null and optional_note = "" to compare input values.

    Module source navigation is still limited to root configuration files.
    Nested module resources are useful for resource address and filtering tests.
    Public nested outputs should remain readable.
    Whole-output sensitive values should remain hidden.
    None of the demo tokens are real credentials.
  NOTES
}

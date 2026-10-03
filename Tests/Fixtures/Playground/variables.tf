variable "owner" {
  description = "Person responsible for this playground. Required, supplied by terraform.tfvars."
  type        = string
}
variable "project_name" {
  description = "A friendly name displayed in resource metadata and outputs."
  type        = string
  default     = "Habitable Playground"
  validation {
    condition     = length(trimspace(var.project_name)) > 2
    error_message = "Project name must have at least three characters."
  }
}
variable "environment" {
  description = "Choose development, staging, or production. Try an invalid value to exercise plan diagnostics."
  type        = string
  default     = "development"
  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "Environment must be development, staging, or production."
  }
}
variable "scenario_generation" {
  description = "Increment to update metadata and replace the two lifecycle examples."
  type        = number
  default     = 2
  validation {
    condition     = var.scenario_generation >= 1 && floor(var.scenario_generation) == var.scenario_generation
    error_message = "Generation must be a positive whole number."
  }
}
variable "enable_optional" {
  description = "Creates an optional resource when true; the seeded plan removes it."
  type        = bool
  default     = false
}
variable "replicas" {
  description = "Number of counted worker records. No actual machines are created."
  type        = number
  default     = 3
  validation {
    condition     = var.replicas >= 0 && var.replicas <= 20 && floor(var.replicas) == var.replicas
    error_message = "Replicas must be a whole number from 0 to 20."
  }
}
variable "tags" {
  description = "A map value for testing typed input editors and nested attributes."
  type        = map(string)
  default     = { team = "platform", purpose = "local UI testing" }
}
variable "features" {
  description = "A list value; an empty list is also valid."
  type        = list(string)
  default     = ["search", "audit", "preview"]
}
variable "regions" {
  description = "Module instance keys include dots and Unicode to exercise address parsing."
  type        = set(string)
  default     = ["east.zone", "west", "東京.研究"]
}
variable "profile" {
  description = "An object with optional fields and defaults."
  type = object({
    contact = string
    enabled = optional(bool, true)
    notes   = optional(string)
  })
  default = { contact = "tester@example.invalid", notes = "Local fixture only" }
}
variable "optional_note" {
  description = "Nullable string: compare null with an explicitly empty string."
  type        = string
  default     = null
  nullable    = true
}
variable "empty_label" {
  description = "An intentionally empty string. It should not appear as a missing input."
  type        = string
  default     = ""
}
variable "demo_token" {
  description = "A fake sensitive token. Never use a real credential in this fixture."
  type        = string
  sensitive   = true
  default     = "FAKE-HABITABLE-TOKEN-NOT-A-CREDENTIAL"
}

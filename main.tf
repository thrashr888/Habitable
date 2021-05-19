resource "random_id" "random" {
  keepers = {
    uuid = uuid()
  }
  
  byte_length = 8
}

output "random" {
  value = random_id.random.hex
}

resource "random_id" "random-2" {
  keepers = {
    uuid = uuid()
  }
  
  byte_length = 4
}

variable "test" {
  type = string
}

output "test" {
  value = var.test
}

variable "name" {
  type = string
}

variable "counts" {
  type = list
}

variable "my-version" {
  type = number
}

resource "null_resource" "null-1" {}

resource "null_resource" "env" {
  provisioner "local-exec" {
    command = "printenv"
  }
}

resource "null_resource" "null0" {
  count = 5
  triggers = {
    value = "EXAMPLE"
  }
}

resource "null_resource" "null1" {
  count = 5
   triggers = {
    value = "EXAMPLE-2"
  }
}

resource "null_resource" "provision" {
  triggers = {
    uuid = uuid()
  }

  provisioner "local-exec" {
    command = "sleep 2"
  }

  provisioner "local-exec" {
    command = "ls -l"
  }
}

## TYPES
output "a-true-bool" {
  value       = true
  description = "The true of the main server instance."
}

output "escapes" {
  value       = "line 1\nline 2\n\\\\\\\\\n"
  description = "The true of the main server instance."
}

output "a-false-bool" {
  value       = false
  description = "The false of the main server instance."
}

output "a-string" {
  value       = "example string"
  description = "The private string of the main server instance."
}

output "an-int" {
  value       = 1001
  description = "The private integer of the main server instance."
}

output "a-decimal" {
  value       = 1000.1
  description = "The private decimal of the main server instance."
}

output "a-list" {
  value       = ["example", 1001, 1000.1]
  description = "The private integer of the main server instance."
}

output "a-map" {
  value       = { "example" : 1001, "bar" : 1000.1 }
  description = "The private integer of the main server instance."
}

output "a-long-string" {
  value       = "The private integer of the main server instance is where you want to go when you have the most fun in every Terraform instance you can see in the world that you live in except for dogs because they don't run servers in the same place that humans do."
  description = "A long string is good for you."
}

output "a-sensitive-value" {
  value       = "hopefully you cannot see me"
  description = "The sensitive string of the main server instance."
  sensitive   = true
}
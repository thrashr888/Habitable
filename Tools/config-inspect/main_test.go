package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectRootDeclarationsAndDistinguishesNullDefault(t *testing.T) {
	dir := t.TempDir()
	root := `variable "nested" {
  description = "nested fixture"
  type = object({
    name = string
    labels = map(string)
  })
  default = {
    name = "sample"
    labels = { env = "test" }
  }
  sensitive = true
}

variable "required" { type = string }
variable "null_default" {
  type = string
  default = null
}

`
	if err := os.WriteFile(filepath.Join(dir, "inputs.tf"), []byte(root), 0o600); err != nil {
		t.Fatal(err)
	}
	child := filepath.Join(dir, "child")
	if err := os.Mkdir(child, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(child, "variables.tf"), []byte(`variable "child_only" { type = string }`), 0o600); err != nil {
		t.Fatal(err)
	}

	module, err := inspect(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(module.Variables) != 3 {
		t.Fatalf("got declarations %v", module.Variables)
	}
	if module.Variables["nested"].Required || !module.Variables["nested"].Sensitive || !module.Variables["nested"].HasDefault {
		t.Fatalf("nested metadata: %#v", module.Variables["nested"])
	}
	if !module.Variables["required"].Required || module.Variables["required"].HasDefault {
		t.Fatalf("required variable metadata: %#v", module.Variables["required"])
	}
	if module.Variables["null_default"].Required || !module.Variables["null_default"].HasDefault {
		t.Fatalf("explicit null default was treated as required: %#v", module.Variables["null_default"])
	}
	if _, ok := module.Variables["child_only"]; ok {
		t.Fatal("child module declaration leaked into root inputs")
	}
}

func TestMetadataIncludesManagedAndDataResourcePositions(t *testing.T) {
	dir := t.TempDir()
	source := `resource "aws_instance" "web" { ami = "ami-example" }
data "aws_ami" "base" { most_recent = true }
`
	if err := os.WriteFile(filepath.Join(dir, "resources.tf"), []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	metadata, err := inspectMetadata(dir)
	if err != nil {
		t.Fatal(err)
	}
	for address, line := range map[string]int{"aws_instance.web": 1, "data.aws_ami.base": 2} {
		item, ok := metadata.Resources[address]
		if !ok || item.Pos.Filename == "" || item.Pos.Line != line {
			t.Fatalf("resource %s metadata: %#v", address, item)
		}
	}
}

func TestReadValuesPreservesNestedValuesAndReportsUnknownExpressions(t *testing.T) {
	file := filepath.Join(t.TempDir(), "fixture.auto.tfvars")
	source := `empty = ""
object = {
  labels = { one = "1", two = "2" }
  values = ["a", "b"]
}
unknown = local.setting
`
	if err := os.WriteFile(file, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	values, err := readValues(file)
	if err != nil {
		t.Fatal(err)
	}
	if string(values.Values["empty"]) != `""` {
		t.Fatalf("empty value lost: %s", values.Values["empty"])
	}
	if string(values.Values["object"]) != `{"labels":{"one":"1","two":"2"},"values":["a","b"]}` {
		t.Fatalf("nested value wrong: %s", values.Values["object"])
	}
	if _, ok := values.Values["unknown"]; ok {
		t.Fatal("unresolved expression was guessed")
	}
	if len(values.Diagnostics) != 1 {
		t.Fatalf("got diagnostics %v", values.Diagnostics)
	}
}

func TestReadJSONTfvars(t *testing.T) {
	file := filepath.Join(t.TempDir(), "terraform.tfvars.json")
	if err := os.WriteFile(file, []byte(`{"empty":"","null_value":null,"nested":{"items":[1,true]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	values, err := readValues(file)
	if err != nil {
		t.Fatal(err)
	}
	if string(values.Values["null_value"]) != `null` || string(values.Values["empty"]) != `""` {
		t.Fatalf("JSON distinctions lost: %#v", values.Values)
	}
}

func TestEnvironmentValuesParseTypedHCLAndPreservePlainStringsAndNull(t *testing.T) {
	for _, test := range []struct{ name, raw, want string }{
		{"structured", `{"items":[1,2]}`, `{"items":[1,2]}`},
		{"plain", `us-west-2`, `"us-west-2"`},
		{"empty", ``, `""`},
		{"null", `null`, `null`},
	} {
		t.Run(test.name, func(t *testing.T) {
			values, err := readEnvironmentValue("example", test.raw)
			if err != nil {
				t.Fatal(err)
			}
			if got := string(values["example"]); got != test.want {
				t.Fatalf("got %s, want %s", got, test.want)
			}
		})
	}
}

func TestInspectJSONDeclarationMetadata(t *testing.T) {
	dir := t.TempDir()
	filename := filepath.Join(dir, "variables.tf.json")
	source := `{"variable":{"json_input":{"type":"string","description":"JSON input","default":null,"sensitive":true,"ephemeral":true}}}`
	if err := os.WriteFile(filename, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	module, err := inspect(dir)
	if err != nil {
		t.Fatal(err)
	}
	variable, ok := module.Variables["json_input"]
	if !ok {
		t.Fatalf("JSON declaration was not discovered: %#v", module.Variables)
	}
	if variable.Required || !variable.HasDefault || !variable.Sensitive || !variable.Ephemeral {
		t.Fatalf("JSON metadata was incomplete: %#v", variable)
	}
}

func TestMetadataContainsRootContextWithoutVariableValues(t *testing.T) {
	dir := t.TempDir()
	source := `terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
variable "token" {
  type = string
  default = "must-not-appear-in-context-help"
  sensitive = true
}
module "network" { source = "./network" }
output "endpoint" {
  description = "Service endpoint"
  value = "https://example.invalid"
}
`
	if err := os.WriteFile(filepath.Join(dir, "main.tf"), []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	metadata, err := inspectMetadata(dir)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Variables["token"].Name != "token" || !metadata.Variables["token"].Sensitive || !metadata.Variables["token"].HasDefault {
		t.Fatalf("variable metadata missing: %#v", metadata.Variables["token"])
	}
	if _, ok := metadata.Outputs["endpoint"]; !ok {
		t.Fatalf("output metadata missing: %#v", metadata.Outputs)
	}
	if provider, ok := metadata.RequiredProviders["aws"]; !ok || provider.Source != "hashicorp/aws" || len(provider.VersionConstraints) == 0 {
		t.Fatalf("provider metadata missing: %#v", metadata.RequiredProviders)
	}
	if module, ok := metadata.ModuleCalls["network"]; !ok || module.Source != "./network" {
		t.Fatalf("module call metadata missing: %#v", metadata.ModuleCalls)
	}
	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "must-not-appear-in-context-help") || strings.Contains(string(encoded), "https://example.invalid") {
		t.Fatalf("metadata included a variable default or output value: %s", encoded)
	}
}

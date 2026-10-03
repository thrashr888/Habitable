# Habitable Playground

A richer **local-only Terraform workspace** for testing Habitable. Every resource uses the built-in `terraform_data` type; no cloud account, provider download, shell provisioner or cloud infrastructure is involved.

## Start here

Open this folder in Habitable. Setup already initialized it and applied a generation-1 baseline. Queue a **plan**, review the changes, and apply if you want to exercise local state updates. Automatic apply should stay off while reviewing the app.

The initial generation-2 plan includes new resources, in-place updates, both replacement orderings, removals, a renamed resource and a synthetic local import. After applying it, another plan should have no changes. Increase `scenario_generation` in `terraform.tfvars` for another update/replacement cycle, or change `replicas` and `enable_optional` to add/remove records.

## Things to try

| Page | Exercise |
| --- | --- |
| Configuration | Multiple HCL files, JSON config, Find (⌘F), Save (⌘S), line numbers, Go to Line, format, auto-validation, external editor |
| Variables | Descriptions, required values, strings/numbers/booleans, maps/lists/objects, sets, explicit null, empty string, fake sensitive input |
| Resources | Nested modules, dotted and Unicode keys, counted workers, data sources, type/category/module filters and sorting |
| Runs | Create/update/replace/destroy, move/import metadata, computed values, output changes, source-linked errors, Git context |
| Outputs | Public nested structures, Unicode, null/empty values, and clearly fake whole-output sensitive values |
| README | Headings, table, inline code, links and code block rendering; open this README in your preferred editor |

```hcl
scenario_generation = 3
replicas             = 5
enable_optional      = true
```

## Other test folders

- **Missing Inputs**: three required variables with no supplied values. Fill them in through Habitable, including a fake sensitive password.
- **Validation Errors**: deliberately invalid references in `main.tf`. Validate and follow the source links; fix them in the editor if desired.
- **Readme Only**: a folder with a README but no Terraform configuration.

`state-source` is a separate output-only local state used by the data-source example. `modules` contains local child modules; they are not independent workspace roots.

All tokens and email addresses are synthetic. Never add real secrets to this fixture. See [Terraform's built-in data resource](https://developer.hashicorp.com/terraform/language/resources/terraform-data) for the resource model.

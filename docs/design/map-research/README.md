# Map research scripts (2026-10-04)

Prototype classifier behind the "Habitable Map Research" artifact (https://claude.ai/artifact/Q79RepVbNcKD6GKhXcxJVV).

Setup (expects sibling dirs `aws/`, `google/`, `azurerm/` with provider docs, and `corpus/` with repos):
- `git clone --depth 1 --filter=blob:none --sparse https://github.com/hashicorp/terraform-provider-aws.git aws && cd aws && git sparse-checkout set website/docs/r` (same for google, azurerm)
- Corpus repos: alphagov/govuk-infrastructure, cds-snc/notification-terraform, cds-snc/forms-terraform, ministryofjustice/cloud-platform-infrastructure, terraform-aws-modules/terraform-aws-vpc, hashicorp/terraform-aws-consul, Azure/terraform-azurerm-aks, GoogleCloudPlatform/terraform-google-three-tier-web-app, GoogleCloudPlatform/terraform-dynamic-python-webapp, hashicorp-education/learn-terraform-lambda-api-gateway

- `analyze.py`: corpus-wide stats (writes sub.json type→docs subcategory)
- `classify.py <dir>`: fold facets/helpers into anchors, merge by name stem + same-service refs, report tiles and shelf
- `dump.py <dir>`: list resources with file, subcategory and references
Regex over HCL; the app version should use state `dependencies` and provider schemas instead.

---
name: habitable-workflow
description: Safely inspect a Terraform workspace selected in Habitable, validate it, and request a plan-only run.
---

# Habitable workflow

Use Habitable's local MCP connection for actions against the workspace the user selected in the app.

1. Read `workspace_status` before taking action. If no workspace is selected or the server is disabled, ask the user to select and enable a workspace in Habitable.
2. Read `declarations` for configuration structure and source locations. Read `run_summaries` and `diagnostics` for bounded, redacted status.
3. Run `validate_workspace` before requesting a plan. Validation does not apply changes.
4. `plan_workspace` queues a plan-only run. Report its run identifier and use `run_status` to follow it. Review the result with the user in Habitable.

Never request Terraform state, credential files, raw secret values, or arbitrary shell execution. Do not apply or destroy infrastructure. Habitable's plan-only tool must remain plan-only even when manual auto-apply is enabled in the app.

Optional upstream skills can be installed separately from HashiCorp's pinned `hashicorp/agent-skills` release. Their content does not authorize Terraform changes.

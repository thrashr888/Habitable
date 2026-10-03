# Configuration UX direction

October 3, 2026. Product proposal; these features are not implemented. Beads epic Habitable-3le is the authoritative work record, with declared inputs (.1), authoring (.2), and contextual Registry help (.3).

## Declared inputs

Make the Variables page describe what the root configuration accepts, not just values already supplied. Current checkVariables discovers conventional terraform.tfvars and terraform.tfvars.json values plus app inputs; it does not inspect variable declarations. The text discovery intentionally handles only simple assignments and is not a general HCL parser.

An unset declaration appears in a muted row with its name, description, type, source location and a Set value action. Required inputs show “Required · Not set”; optional inputs show “Uses default”. Muted rows remain interactive and keyboard accessible. Required-only filtering and a missing-input summary make a large configuration approachable. Sensitive metadata controls the editor and previews. Ephemeral metadata must be preserved when supported. Distinguish absent values, explicit empty strings and valid nulls.

Separate declarations from overrides in the model. Merely discovering a declaration must never generate an empty override or replace a default. Resolve supplied values and provenance across app inputs, TF_VAR environment variables, conventional tfvars and ordered auto tfvars, following actual Terraform precedence. Represent unresolved expressions as uncertainty rather than guessing. Refresh on saved configuration changes. Keep root inputs separate from module-call arguments.

Evaluate a pinned helper using official HCL tooling. HashiCorp terraform-config-inspect exposes shallow module metadata and source locations in JSON, but its stated limited scope means newer metadata and complex cases need coverage checks. Do not extend the existing line-based tfvars parser into a declaration parser. Discovery should not require initialization or planning.

## Authoring and learning

A Configuration destination can start with a native file browser, open-in-editor actions and diagnostics that open the offending line. In-app editing can follow with syntax highlighting, explicit save, external-change detection, format previews and validation. Installed provider schemas can inform required fields, descriptions and completion. Starter templates should preview exact files and provider requirements before creation.

The workspace overview should guide users through configuration, inputs, initialization, validation, plan review and apply. Short contextual explanations answer why a provider is needed, where state lives and what a replacement means. Keep advanced detail available through disclosure. Saved edits invalidate old plans. Formatting, provider installation and infrastructure application remain explicit actions. AI authoring remains deferred.

## Registry context

Start with documentation links next to a resource type, provider requirement or module call. Resolve provider aliases to full sources and prefer the locked version, avoiding accidental latest-version guidance. Built-in and private sources require distinct handling.

Then evaluate an inspector with cached documentation, provider attribute schemas, module inputs/outputs and examples. The documented Registry module API supports module metadata; the provider distribution protocol should not be mistaken for a documentation API. No workspace values, state or credentials are needed for public documentation requests. Offline and unavailable documentation should not block editing or plans.

## Sources

- [Configuration inspection helper](https://github.com/hashicorp/terraform-config-inspect)
- [Input variable semantics](https://developer.hashicorp.com/terraform/language/values/variables)
- [Installed provider schema command](https://developer.hashicorp.com/terraform/cli/commands/providers/schema)
- [Registry module API](https://developer.hashicorp.com/terraform/registry/api-docs)

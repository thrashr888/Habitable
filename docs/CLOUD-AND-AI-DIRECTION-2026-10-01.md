# Habitable: cloud and on-device AI direction

Research date: October 1, 2026. This is a proposal; the features below are not yet implemented. Implementation scope lives in Beads: Habitable-gze (description drafting), Habitable-upt (HCP viewer), and Habitable-et3 (real remote-backend QA).

## Product direction

Make Habitable a native desktop workspace for understanding and operating Terraform, with local CLI execution and a connected HCP Terraform view. Preserve exact-plan review and explicit infrastructure actions. Put AI where it reduces reading and writing effort: descriptions, summaries, and explanations.

## API integration and tfctl

Recommendation: a native URLSession client for HCP Terraform, with tfctl as a reference and optional companion. tfctl already offers run management, variables, profiles, JSON output, direct API access, and output redaction. It also has its own configuration and plaintext token storage. Wrapping it could accelerate a prototype, but introduces another binary, configuration precedence, subprocess lifecycle, and output schema to manage. Its redacted responses can omit fields a native artifact viewer needs. These are engineering tradeoffs, not a finding that tfctl is unsuitable. [tfctl documentation](https://github.com/hashicorp/tfctl-cli)

The direct API exposes workspace and run data, plans, policy checks, cost estimates, and assessments. Availability depends on organization entitlements and caller permissions. Authenticate with a user or team token appropriate to the operation; organization tokens cannot perform plans/applies. Store app-owned tokens in Keychain. Keep signed artifact URLs out of logging and history. Paginate lists and use endpoint-specific polling limits: workspace run listing is limited to 30 requests per minute. [API overview](https://developer.hashicorp.com/terraform/cloud-docs/api-docs), [Runs API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/run)

Start with a read-only workspace/run browser: select account and organization, see active and historical runs, review available plan data and logs, and open the corresponding HCP page. Add policy/cost/drift panels when the account exposes those capabilities. [Plans API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/plans), [API capability index](https://developer.hashicorp.com/terraform/cloud-docs/api-docs)

Use separate Local and HCP execution implementations behind shared presentation models. Local identity includes canonical directory, selected Terraform workspace/backend, CLI, and immutable plan artifact. HCP identity includes hostname, organization, workspace ID, configuration version, and run ID. Preserve server run identity across relaunch and refresh its status. Remote cancellation requests and confirmation operate on that server run; the server's current permission/action flags govern available controls. Represent policy checks, cost estimation, queues, and server completion without compressing them into a local Process lifecycle. [Runs API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/run)

## Description drafting with Foundation Models

This is the first recommended implementation. Apple's Foundation Models framework provides native Swift access to the on-device model. Check SystemLanguageModel availability at runtime; OS support alone does not establish that the model is ready. The installed SDK marks this API available from macOS 26, while Habitable currently supports macOS 13, so keep the feature availability-gated. Explicitly select the on-device model for this feature. [Apple overview](https://developer.apple.com/apple-intelligence/), [model availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

Add a Generate description button next to the existing editor. Generate one concise purpose statement from an allowlisted, bounded description of resource types, modules, and variable names/descriptions. Exclude variable values, raw state, credentials, and secret-bearing logs. Present an editable suggestion and apply it only through the user's Use suggestion action. Preserve manual edits and reject results for an old workspace or older request. Use manual entry plus a deterministic resource/module summary when the model is unavailable.

The current workspace description is only an in-memory Published property bound to Settings. Add durable storage keyed by workspace identity alongside this feature. Treat workspace description and run message as separate fields: the former explains infrastructure purpose; the latter explains a particular change. Keep an HCP description edit explicit because accepting local text and publishing remote metadata are distinct actions.

## AI expansion

After description quality is evaluated, add plain-language plan summaries grounded in the existing structured diff, short run messages, and diagnostic explanations with links to the actual events. Keep Terraform-computed counts, replacement markers, and reviewed artifact identity authoritative. AI-generated text is editable supporting context. Evaluate synthetic fixtures for omissions, invented purpose, secret inclusion, malformed output, latency, unavailable models, and asynchronous races before expanding scope.

Recommended implementation order: description persistence and drafting, the read-only HCP viewer, then remote actions backed by a disposable real-backend QA workflow. Keep authentication, remote writes, and model-assisted infrastructure changes out of the first description feature's scope.

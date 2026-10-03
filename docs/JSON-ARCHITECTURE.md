# Terraform JSON in Habitable

Habitable extends the original `JsonLog` and `StructuredLog` models rather than replacing them. The current implementation has two deliberately separate paths, reflecting Terraform's [machine-readable UI](https://developer.hashicorp.com/terraform/internals/machine-readable-ui) and [saved-plan JSON format](https://developer.hashicorp.com/terraform/internals/json-format).

## Live command events

`Runner.plan` invokes `plan -input=false -json -out=<run-specific-plan>`. `Runner.apply` invokes `apply -input=false -json <that-plan>`. A Foundation `Process` runs the executable directly with argument arrays, not a shell command. stdout and stderr are drained independently on a serial lifecycle queue; completion waits for process exit and both streams' EOF. The runner frames bytes into complete lines before UTF-8 decoding, including a final unterminated line.

`Run.appendOutput` passes stdout into `NDJSONStreamDecoder`. That decoder also handles records split across callbacks, bounds incomplete records, and converts non-JSON lines into readable log messages. This fallback accommodates CLI/HCP preambles and unexpected text. Unknown event types retain their `@message` rather than disappearing.

`consumeTerraformEvent` updates the observed `StructuredLog` on the main actor. `planned_change` creates resource entries; apply hooks update their stages by resource address, so interleaved resources remain distinct. Refresh/provision messages remain activity logs. Version, change summary, diagnostics, and outputs have dedicated models. The native views observe those models while the command runs.

The live collection is bounded: 200 log messages, 100 diagnostics, 500 resource entries, eight stages per resource, and the latest summary/version/output event. Command capture is capped at 1 MiB and individual stream lines at 64 KiB; stdout capture overflow rejects the result, so an incomplete plan never becomes confirmable. `show -json` stdout uses full capture because plan/state JSON can legitimately be one large record. Large-state memory behavior remains a separate scale-review item.

Canceled and truncated failures retain the already-consumed live model rather than rebuilding it from the incomplete capture. This preserves late diagnostics and stderr in the current window. History also stores separate bounded tails of complete plan/apply events for these failures. Reopening rebuilds the structured view from those redacted tails and reports when earlier events were omitted; legacy records still fall back to their original capture.

## Review and apply

A successful plan is not immediately confirmable. Habitable runs `show -json <run-specific-plan>` and requires an inspectable saved-plan representation first. `parseTerraformPlan` reads `resource_changes` and `output_changes`; output-only plans are valid even when Terraform omits `resource_changes`.

The diff walker combines before/after values with `before_sensitive`, `after_sensitive`, and `after_unknown` masks. Its value model distinguishes absent, explicit null, unknown, and sensitive values. Paths use JSON-quoted bracket components, so a literal key `a.b` remains distinct from nested keys `a` and `b`, and array indices remain distinct from string keys. `replace_paths` uses the same representation. Resource action arrays retain their original order. Review explains create-before-destroy and destroy-before-create replacements and shows previous addresses and import IDs, including moves/imports whose action is no-op. Output names are sorted for display because the JSON object does not promise output ordering.

Review uses the exact artifact later supplied to apply. Workspace command leases serialize Habitable commands across windows/processes; saved-plan generations and execution-context checks prevent applying plans invalidated by subsequent Habitable operations or context changes. Restored history is for inspection and cannot be applied. Terraform remains responsible for its own state-lock and stale-plan checks.

After apply, `show -json` without a plan argument refreshes the selected backend's current state. That state snapshot is separate from both the live event log and the reviewed plan.

## Diagnostics, secrecy, and limitations

Diagnostics retain severity, filename/range, source snippet, explanation, and highlighted expression. A Terraform 1.16.5 fixture with an emoji before the error reported UTF-8 byte offsets; the renderer validates byte boundaries and falls back to readable unhighlighted source for invalid offsets. Snippet line numbering comes from `snippet.start_line`.

JSON output is not assumed safe to persist verbatim. Terraform's sensitive output metadata and app-marked sensitive inputs are redacted before presentation/history, including nested payloads. Plans and temporary input files use private filesystem permissions. These protections do not establish that Terraform or provider diagnostics can never disclose an unmarked secret.

This is still a selective UI adapter. It does not render every newer event family or all saved-plan metadata (for example, drift and check detail). Explicit unsupported or malformed UI versions stop structured interpretation and reject the plan before inspection/confirmation. Supported UI majors are 0 and 1; saved-plan format major 1 is required. Compatible minor additions are accepted and unknown properties ignored. Streams lacking version events remain tolerated for legacy CLI output. HCP support follows the Terraform CLI's backend behavior; stopping local streaming does not establish that a remote run was canceled.

Relevant source: `Habitable/Models/Runner.swift`, `RunModel.swift`, `ndjson.swift`, `JsonLog.swift`, `StructuredLogModel.swift`, and `RunHistory.swift`. Regression coverage lives in the core JSON, runner, sensitive-run, history, and workspace tests.

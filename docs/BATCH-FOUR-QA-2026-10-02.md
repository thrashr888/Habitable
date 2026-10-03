# Habitable batch four verification

## Changes

Resource inspection now flattens nested attributes into stable paths, supports value search and copy, and applies Terraform's sensitive-values mask before exposing values. Missing or malformed root masks fail closed. Strings already marked sensitive in a resource are also redacted when repeated in other string attributes. Provider links accept only the official Terraform Registry provider address form; built-in and arbitrary identities remain text.

Inputs remain session-only by default. Remembering an app override is an explicit per-input choice, isolated by canonical local folder. Non-sensitive values use private local metadata; sensitive values use opaque Keychain references. Secret updates stage a new Keychain item and atomically commit metadata before retiring the old item. Failed saves preserve editor drafts and previous references. Missing secrets appear as unavailable placeholders and block runs until replaced or removed. Corrupt metadata rejects a folder switch without losing the active folder or inputs.

Saved-plan confirmation verifies the configuration, automatic variable files, installed module manifest and module configuration, selected workspace/backend metadata, local state, effective app inputs, process environment, and CLI identity. Files are hashed off the main actor in bounded chunks before planning, after planning, and before applying. Changed or unverifiable context expires the artifact and asks for a new plan. Cancellation during verification cannot launch a Terraform command afterward.

File > Open… uses the native folder panel and Command-O. Open Recent is focused to the current window, canonicalized, deduplicated, and bounded to ten folders. Failed opens preserve the active workspace. Clear Recent Folders synchronizes across windows without reviving cleared paths. The empty window provides setup guidance and scrollable recent folders; Settings offers Reveal in Finder.

## Scope

Only disposable local built-in terraform_data fixtures are used for live verification. Remote stale-state checks and locks remain Terraform's responsibility. These changes do not add HCP API or AI integration. General large-state performance and comprehensive keyboard/VoiceOver QA remain separate tracked work.

## Verification results

The full suite passed 124 tests with no failures, using managed Terraform 1.16.5 and the official managed-release download test. The universal Debug build passed for arm64 and x86_64.

Native verification used /tmp/habitable-batch-four-20261002 and a second disposable folder. A remembered non-sensitive greeting survived app restart. The inspector showed nested paths, empty maps/arrays, public siblings, and masked input/output duplicates; searching the synthetic secret returned no matches. An external configuration edit expired the reviewed plan before Terraform apply ran, and Validate and plan produced a fresh review. Native Command-O opened the second folder; Open Recent returned to the original with its remembered input and run history. An unavailable recent folder showed an error and preserved the active runs, input, resources, and Ready state.

Saved-plan diff review still has a separate preexisting duplicate-sensitive-value edge: terraform_data before.output can echo a marked-sensitive before.input string without its own mask. This is tracked as Habitable-vov. The new inspector handles that resource-level echo safely; broader plan-review redaction is the next follow-up.

## Signed app and distribution

The signed candidate recovered a remembered synthetic environment secret after restart with Ready status and masked presentation. Its metadata contained only the opaque Keychain reference, no secret value, and used file mode 0600. Removing the test input through the app removed the corresponding Keychain item. No real user credential was used for this test.

A real Terraform named workspace qa produced a plan with the correct local backend label. Switching to default externally expired that plan before apply. No resources were created in the second fixture.

0.4.6 build 10 is published to both the source repository and Homebrew tap and installed through thrashr888/tap/habitable. Exact app build revision: 34f0782b55794a1af9a2e812b504a0efddcd7ca6. Universal ZIP SHA-256: 453efdac9889f81d1feb88dd63d488c2ed161aa295db1df20451a39f3dad07ae. Both uploaded archive and checksum-manifest digests match local artifacts. Installed Developer ID signature, stapled ticket, Gatekeeper assessment, both architectures, and version/build checks passed. The installed app is open on the masked resource inspector fixture.

Remote CI passed: https://github.com/thrashr888/Habitable/actions/runs/37092743344 . Packaging independently passed 124 tests with the optional online-download test skipped; the separate full local and remote runs enabled that download test.

Source release: https://github.com/thrashr888/Habitable/releases/tag/v0.4.6 . Tap release: https://github.com/thrashr888/homebrew-tap/releases/tag/habitable-v0.4.6 . Beads items rt3.8, rt3.9, rt3.15, and rt3.17 are closed. Habitable-vov remains the next plan-review privacy follow-up.

Homebrew cask style and online audit passed for the published 0.4.6 cask.

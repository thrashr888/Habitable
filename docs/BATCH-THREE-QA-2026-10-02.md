# Habitable batch three verification

## Changes

- Explicit incompatible UI schema versions stop structured interpretation and prevent saved-plan confirmation. Saved-plan JSON requires format major 1 while accepting newer compatible minors.
- Review includes no-op moves/imports and original addresses/import IDs; replacement order is explained explicitly.
- Canceled/overflowed runs persist separate redacted compact NDJSON tails for plan and apply. Complete records, a retained version prefix, a 256 KiB phase bound, and omission notices preserve late diagnostics when reopening. Legacy records still decode.
- Runs offers Validate and plan after a configuration/plan failure. Validation must succeed before creating a fresh run; it cannot revive the failed artifact.
- CI checks the core suite, a checksum-verified pinned official Terraform binary, managed release download, and both release architectures. Packaging runs the core gates and verifies the signed/notarized archive against its exact manifest entry.

## Real Terraform fixture

Terraform 1.16.5 initialized and applied a local built-in terraform_data seed in /tmp/habitable-json-complex-20261002, then saved a complex plan without applying it. No provider download or external infrastructure was used. Its show JSON format is 1.2.

The artifact contains a no-op import, a no-op move, a create-before-destroy replacement with triggers_replace, four count instances under two for_each module instances, a removed output, and a nested sensitive output with an unknown child. A reduced stable-ID copy is checked into Tests/HabitableCoreTests/Fixtures/terraform-1.16.5-complex-plan.json. The regression checks the metadata and masking, independently of live NDJSON summaries.

## Boundaries

Resource inspector scale, general durable-input/secret-storage design, comprehensive VoiceOver, crash/offline/missing-CLI QA, and newer drift/check event rendering remain tracked separately in Beads. Local cancellation does not establish remote HCP cancellation. AI and deeper HCP integration remain deferred.

## Validation results

- Full suite: 93 tests, zero failures, with the real Terraform integration and official managed-release download enabled; official Terraform 1.16.5 arm64 verified.
- Universal Debug app built for arm64 and x86_64.
- Native candidate reviewed the complex fixture: import/move rows, replacement order, module/count paths, removed output, and sensitive nested output were visible.
- Native failure/retry: a broken expression produced an Errored run; Validate and plan revalidated and kept the run count unchanged while the expression remained invalid. After restoring the file, the same action produced a fresh Planned run and selected it.
- Initial integration runs caught and fixed compact-NDJSON framing and version-only-history restoration regressions before release.

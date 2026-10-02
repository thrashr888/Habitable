# Input editing and failure recovery — 2026-10-02

This batch implements app-input editing/removal, non-JSON error cleanup, retained live failure events, and focused native keyboard/accessibility/layout improvements. The core suite passed 88 tests, zero failures, one optional release-download test skipped, with the real Terraform 1.16.5 local workflow enabled. Universal Debug and Release builds passed with Xcode 27. The 0.4.3 release candidate was signed, notarized, stapled, and accepted by Gatekeeper.

## Input changes

Both Terraform and environment editors use item-presented sheets carrying an explicit draft and original input. Live QA caught the initial boolean-sheet implementation opening a blank Edit draft; the final release candidate correctly populated existing values. Command-Return saves from the multiline value editor, while Escape cancels. Editing a draft and canceling left the original value unchanged.

In the final candidate, adding `guard=valid`, editing it to `invalid`, and removing it all worked. The variable count remained one on edit and returned to zero on removal. A pending reviewed plan became Discarded after the effective edit, with its apply action removed. Environment input `HABITABLE_QA_INPUT` was added as `first`, reopened with that value, edited to `second`, and removed. No real credentials were used. Inputs explicitly describe their session lifetime and override source; durable input storage remains separate work.

Model regression coverage checks duplicate validation, generation changes for both input kinds, and unchanged generation for description-only edits. Discovered entries remain read-only; Terraform still interprets original workspace files.

## Failures and live events

The real malformed-state fixture `/tmp/habitable-batch-bad-state` previously exposed ANSI CSI sequences in both Settings and Workspace. Updated Debug UI showed readable errors in both locations. Shared command-error normalization handles CSI, OSC and other terminal escapes. The retained live stream is also normalized, with regression coverage ensuring a configured sensitive input is still redacted.

The isolated fixture `/tmp/habitable-next-failures` uses only built-in `terraform_data` and a local provisioner that prints a marker and exits. An apply deliberately failed with exit 1; the app showed the provisioner diagnostic and refreshed the partial state (one resource, one output). Changing the fixture command to exit 0 allowed a fresh replacement plan and a successful apply. The final candidate also showed a structured invalid-variable diagnostic for `guard=invalid`, without an apply action.

Cancellation/overflow regressions verify that cleanup retains the workspace command lease until process exit and stream drain, cancellation refreshes unknown outcomes, and late diagnostics/stderr remain in the observed structured model when raw capture is incomplete. Capture overflow continues rejecting command success. Restored history still uses bounded raw capture and can omit late overflow events; this is recorded under Habitable-rt3.12.

## Native UI and remaining verification

Command-R reloaded saved run history in the candidate and retained the selected run. Run status now uses distinct symbols and spoken change-count labels. Search fields identify their collection, sensitive outputs have a readable lock label, long values wrap, run rows can grow, and the grouped description editor has a bounded height. A narrowed 976 × 612 point candidate window showed readable run history and diagnostic detail.

Actual VoiceOver traversal/text scaling, exact minimum-window behavior, larger long-value fixtures, and the broader live interruption/offline/missing-CLI matrix remain in Habitable-rt3.21. Native AX still aggregates input-row action labels, and Settings can temporarily retain an old outer path label while its nested value updates. These are not claimed fixed by source labels alone. Failed-plan retry currently requires Workspace validation to re-enable planning; its discoverability also needs further review.

See `JSON-ARCHITECTURE.md` for the event-stream versus saved-plan implementation and its schema/persistence limits. Deeper HCP and AI integrations remain deferred.

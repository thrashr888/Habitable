# Core workflow verification — October 1, 2026

Verified the Debug app built from this checkout with Xcode 27, Swift 6 language mode, and both arm64 and x86_64 architectures. This is development-build verification; the installed signed 0.3.0 release has not been replaced by this pass.

The final SwiftPM suite ran with the real Terraform integration enabled: 64 tests, zero failures, one optional official-release download test skipped. Model and test compilation produced no Swift concurrency warnings.

Local copies of terraform-fast, terraform-outputs, terraform-empty, and terraform-apply-fail were exercised in isolated temporary directories. Terraform 1.16.4 initialized and validated the fixtures; saved plans and local applies completed. No HCP Terraform writes were performed.

The live app restored workspace descriptions after switching folders and restarting. Missing state and optional variable files use neutral check indicators. Structured apply diagnostics display readable messages and source locations. Large nested output values remain visible, scalar and empty values retain their meanings, and sensitive outputs stay masked.

History loaded 50 records on the first page and six on the second, with the total count remaining 56. A new output-only plan retained the existing history, allocated run 57, reached Planned, and applied successfully. This caught and fixed a parser assumption that every saved plan contains resource_changes.

The native export flow produced a JSON file with owner-only permissions (0600). Store regression coverage also checks re-redaction of sensitive output, interrupted index updates, numbering, corruption preservation, and deletion eligibility.

A slow local terraform_data apply streamed its progress. Cancel produced Canceled, released the workspace lock after Terraform exited, and refreshed the partial state to show the resource created before cancellation.

Follow-up defects are tracked in Beads: Habitable-ci9 covers the unnecessary status message for absent state; Habitable-uxl covers output changes in the Review tab.

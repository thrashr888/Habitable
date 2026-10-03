# Native page review — October 2, 2026

Reviewed installed 0.4.6, then a universal Debug candidate containing the two layout fixes below. Used disposable local Terraform fixtures, including remembered inputs, nested resource attributes, sensitive outputs, and applied, expired, discarded, and errored run history. No production infrastructure changed.

## Corrected and verified

Terraform variable rows now display nonempty descriptions below their values, with wrapping. The saved demonstration description was absent in 0.4.6 and visible in the candidate.

Resource details now occupy the leading edge of the detail pane. A native two-column Grid keeps metadata labels and values aligned together instead of sending values to the trailing edge. Address and provider text wrap at narrower widths; attributes retain their scrolling list and sensitivity masking.

Both fixes were inspected in the running candidate. The universal arm64/x86_64 Debug build and whitespace checks passed. This candidate is not a new signed release; the installed Homebrew release remains 0.4.6.

## Page assessment

| Surface | Evidence and assessment | Tracking |
| --- | --- | --- |
| Start / recent folders | Live missing-folder alert, start screen, and successful recent-folder recovery. Clear primary folder action; getting-started copy unnecessarily directs users to the CLI for initialization. | Habitable-rt3.30 |
| Workspace | Live initialized/valid local folder. Checks are readable, but the page lacks folder identity and a useful overview/next action. Source inspection shows sidebar “Ready” reflects unlocked state rather than successful checks. Reinitialization remains useful, but its label should explain the action. | Habitable-rt3.28 |
| Runs | Live applied, expired and discarded history; error panel and structured event tabs inspected. Restored plan navigation nests phase selection, a single Events tab, and another tab group. Summary hierarchy and recovery actions need consolidation. Existing saved-plan duplicate-sensitive-value finding remains the highest priority. | Habitable-rt3.25; Habitable-vov |
| Resources | Live simple/nested attributes, sensitive masking, metadata, and narrower detail pane. Reported alignment defect fixed. Long IDs and paths wrap; retaining enough detail width is important. Large-state performance remains a separate gate. | Habitable-rt3.24; Habitable-rt3.12 |
| Outputs | Live simple string and sensitive object detail. Sensitive object stays masked in list and detail. Name/Type/Value hierarchy differs from resources; structured non-sensitive values and copy deserve a consistent inspector. | Habitable-rt3.29 |
| Terraform Variables | Live remembered input, edit/save description, and candidate row verification. Description defect fixed. Empty page lacks guidance; provenance text is lengthy and editors need clearer persistence language. | Habitable-rt3.24; Habitable-rt3.26; Habitable-rt3.27 |
| Environment Variables | Live empty page and Add sheet. Blank list gives no next-step explanation. Sheet immediately displays a red error for the untouched blank key; introductory text visibly truncates. | Habitable-rt3.26; Habitable-rt3.27 |
| Settings | Live grouped form at normal and narrower widths. Version selection, active managed version, folder actions, executable disclosure and description editor are coherent. Execution is below the fold and the form scrolls. No new blocking layout defect reproduced with these fixture paths. | Existing adaptive review Habitable-rt3.14 |
| Input editors | Both inspected; Terraform description saved and displayed after the fix. Environment Escape dismisses correctly. Mixed field layouts, verbose/truncated help and session-only language conflict with remembering inputs. | Habitable-rt3.27 |
| Folder opening | Command-O opens the native folder panel; complex fixture loads successfully. Missing saved folder produces actionable recovery without losing recent folders; renamed disposable fixture was restored immediately. | Habitable-rt3.30 |

## Quality order

Resolve saved-plan sensitive echoes (Habitable-vov, P1) before cosmetic work. Then simplify Runs navigation (.25), improve input editors (.27) and empty states (.26), and make Workspace a useful overview (.28). Output consistency (.29) and onboarding copy (.30) follow. Beads is the authoritative status and acceptance-criteria record.

Use consistent leading detail layouts, native controls and focus behavior, readable wrapping, explicit primary actions, and meaningful empty/error states. Avoid adding decorative containers or extra navigation levels. Match resource/output inspection and Terraform/environment input editing while preserving their different semantics.

This is a page-by-page product review, not completion of every accessibility or failure-mode test. Full VoiceOver traversal, comprehensive keyboard focus, light appearance, minimum-height long-error behavior, active cancellation/interruption, and large-workspace performance remain tracked in Habitable-rt3.21 and the existing reliability/native-UX backlog. Deeper AI and HCP integrations remain deferred.

## Implementation follow-up — October 3, 2026

Three Luna subagents implemented the six page follow-ups, followed by parent review. Runs retain phase selection and safe run actions while presenting review and labeled events in one scrolling list. Input pages explain empty states and provide Add actions; editors wrap persistence guidance, align fields, and defer validation until interaction. Workspace identifies the local folder and execution context, offers initialize/validate/plan according to readiness, and scrolls long content. Sidebar readiness distinguishes idle from ready to plan. Outputs use leading metadata, structured formatting and accessible non-sensitive copy. Onboarding directs users to initialization inside Habitable.

The saved-plan redaction candidate normalizes provider-marked sensitive values before review flattening. Synthetic regressions cover unmarked echoes across resources and outputs, composite type transitions, sensitive map keys and replacement paths, and numeric values echoed as text. An independent read-only review identified the latter cases before final validation. Existing action order, ordinary values, masks and exact binary plan application remain covered by passing regressions. Inspected plan JSON is transient; the binary plan is deliberately unchanged.

Final quality gates: universal arm64/x86_64 Debug build passed; 126 core tests ran with zero failures and one opt-in online-download test skipped; focused plan/privacy tests passed; whitespace check passed. Native live verification was blocked by repeated “Sky Computer Use native pipe closed before response,” including a reset and reconnect. The final page appearance, keyboard flows and live privacy reproduction therefore remain pending under Habitable-rt3.21; implementation issues remain in progress until that verification. No new release was published. Candidate: `/tmp/habitable-next-debug/Build/Products/Debug/Habitable.app`.

## HCP-inspired local UI batch — October 3, 2026

Implemented plan action counts, address/operation filters and expandable resource/output changes; routine events collapse while diagnostics remain visible. Resources provide sortable Address/Provider/Type/Module columns when the browser is wide enough and compact selectable rows at narrower widths, with managed/data/provider/module filters. Module parsing preserves quoted instance keys. Input rows group keys with descriptions, safe value previews, sensitivity/JSON/persistence labels and explicit provenance. Workspace adds its description, resource/output counts, latest-run status/change counts and a Review run action, plus separate CLI location and state-backend information. Unknown remote execution mode is not inferred from remote state. Latest-run loading accounts for paginated history rather than labeling an older loaded page as latest.

The Environment Variables sidebar defect was reproduced visually on the empty-input fixture: accessibility still listed sidebar rows while the sidebar rendered blank. A first stable NavigationSplitView attempt did not pass the user's check. The second candidate replaces that automatic container with a native HSplitView and explicit sidebar visibility, retaining an accessible Hide/Show Sidebar control. The rebuilt candidate was restarted for another user check. That second check and broader final visual QA remain pending; the native inspection connection again failed after restart.

This batch's universal build passed, and 126 regression tests completed with zero failures and one opt-in download test skipped. Tracking: Habitable-rt3.31–.35; live verification under .21. Stage timing/Git context is separately tracked in .36 because the current run records do not provide truthful phase durations. No production cloud operations or new release were performed.

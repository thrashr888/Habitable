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

The Environment Variables sidebar defect was reproduced visually on the empty-input fixture: accessibility still listed sidebar rows while the sidebar rendered blank. A first stable NavigationSplitView attempt did not pass the user's check. The second candidate replaces that automatic container with a native HSplitView and explicit sidebar visibility, retaining an accessible Hide/Show Sidebar control. The user confirmed the second candidate still rendered a blank sidebar. Their paired screenshots then isolated the defect to zero environment variables: adding an override restored the sidebar immediately. The third candidate keeps the native List mounted in both input pages and overlays bounded empty-state guidance instead of replacing the list with a full-height placeholder. The broader sidebar rewrite was discarded. Its universal build passed and the candidate was restarted. The user confirmed the sidebar stays visible with zero environment variables. Broader keyboard, narrow-window and cross-page QA remains tracked under .21 because the native inspection connection still fails after restart.

This batch's universal build passed, and 126 regression tests completed with zero failures and one opt-in download test skipped. Tracking: Habitable-rt3.31–.35; live verification under .21. Stage timing/Git context is separately tracked in .36 because the current run records do not provide truthful phase durations. No production cloud operations or new release were performed.

## Unified review scope — October 3, 2026

The user authorized implementation of the page-review findings, HCP Terraform comparison improvements and newcomer configuration features together. This document is the shared product review record; Beads remains the authoritative task and dependency tracker. Earlier sections record historical observations, not the latest completion state. User review follows implementation and verification.

| Workstream | Beads references | Review evidence / current state |
| --- | --- | --- |
| Runs, empty input pages, editors, workspace, outputs and onboarding | rt3.25–.30 | Implemented in the candidate; final cross-page verification underway. |
| HCP-inspired plan filters, resource table, variable provenance and latest-run overview | rt3.32–.35 | Implemented in the candidate; final cross-page verification underway. |
| Empty input page sidebar | rt3.31 | Closed after user confirmed zero-variable sidebar remains visible. |
| Saved-plan sensitive echoes | Habitable-vov | Regression coverage passes; live fixture reproduction remains part of review. |
| Native accessibility, adaptive layout, interruption and responsiveness | rt3.10–.14, .21 | Existing quality gates remain in scope; record evidence and limitations individually. |
| Run stage timing and captured Git context | rt3.36 | Implemented with backward-compatible records and bounded Git snapshots; regression coverage passes; live review is tracked in .21. |
| Declared inputs and value resolution | Habitable-3le.1 | Official HCL helper discovers root declarations; unset/default rows, required filter, source precedence and app environment refresh implemented; automated verification passes; final live review pending. |
| Configuration authoring and beginner workflow guidance | Habitable-3le.2 | Native source editor, explicit save, external-change protection, diagnostic navigation, direct formatting and starter preview implemented; automated verification passes; final live review pending. |
| Direct formatting, validation on saved updates, draggable validation pane | Habitable-3le.4 | Direct format-and-save, debounced validation of visible saved-file updates, and native vertical split implemented; seven editor tests pass; live divider review pending. |
| Version-aware Registry context | Habitable-3le.3 | Locked-provider and installed-module documentation links implemented; on-demand installed-provider attributes and Configuration provider/module/input/output declaration help implemented; automated verification passes, final live review pending. |

Deeper AI and HCP account/API integrations remain deferred. Registry documentation supports the local workflow without changing this boundary. All new code must preserve saved-plan identity, input secrecy, external-edit detection and explicit infrastructure actions.

## Newcomer feature design

The following design paragraphs record the agreed direction. The implementation notes and evidence above and below describe what is present in the current candidate.

## Declared inputs

Make the Variables page describe what the root configuration accepts, not just values already supplied. Current checkVariables discovers conventional terraform.tfvars and terraform.tfvars.json values plus app inputs; it does not inspect variable declarations. The text discovery intentionally handles only simple assignments and is not a general HCL parser.

An unset declaration appears in a muted row with its name, description, type, source location and a Set value action. Required inputs show “Required · Not set”; optional inputs show “Uses default”. Muted rows remain interactive and keyboard accessible. Required-only filtering and a missing-input summary make a large configuration approachable. Sensitive metadata controls the editor and previews. Ephemeral metadata must be preserved when supported. Distinguish absent values, explicit empty strings and valid nulls.

Separate declarations from overrides in the model. Merely discovering a declaration must never generate an empty override or replace a default. Resolve supplied values and provenance across app inputs, TF_VAR environment variables, conventional tfvars and ordered auto tfvars, following actual Terraform precedence. Represent unresolved expressions as uncertainty rather than guessing. Refresh on saved configuration changes. Keep root inputs separate from module-call arguments.

Evaluate a pinned helper using official HCL tooling. HashiCorp terraform-config-inspect exposes shallow module metadata and source locations in JSON, but its stated limited scope means newer metadata and complex cases need coverage checks. Do not extend the existing line-based tfvars parser into a declaration parser. Discovery should not require initialization or planning.

## Authoring and learning

A Configuration destination can start with a native file browser, open-in-editor actions and diagnostics that open the offending line. In-app editing can follow with syntax highlighting, explicit save, external-change detection, direct formatting and validation after saved changes. Installed provider schemas can inform required fields, descriptions and completion. Starter templates should preview exact files and provider requirements before creation.

The workspace overview should guide users through configuration, inputs, initialization, validation, plan review and apply. Short contextual explanations answer why a provider is needed, where state lives and what a replacement means. Keep advanced detail available through disclosure. Saved edits invalidate old plans. Formatting, provider installation and infrastructure application remain explicit actions. AI authoring remains deferred.

## Registry context

Start with documentation links next to a resource type, provider requirement or module call. Resolve provider aliases to full sources and prefer the locked version, avoiding accidental latest-version guidance. Built-in and private sources require distinct handling.

Then evaluate an inspector with cached documentation, provider attribute schemas, module inputs/outputs and examples. The documented Registry module API supports module metadata; the provider distribution protocol should not be mistaken for a documentation API. No workspace values, state or credentials are needed for public documentation requests. Offline and unavailable documentation should not block editing or plans.

## Sources

- [Configuration inspection helper](https://github.com/hashicorp/terraform-config-inspect)
- [Input variable semantics](https://developer.hashicorp.com/terraform/language/values/variables)
- [Installed provider schema command](https://developer.hashicorp.com/terraform/cli/commands/providers/schema)
- [Registry module API](https://developer.hashicorp.com/terraform/registry/api-docs)

## Native design acceptance — combined batch

The user requested Apple HIG and high-quality macOS design throughout this work. Review every page for clear typography hierarchy, consistent optical spacing, leading alignment, bounded readable help, adequate whitespace, system controls and explicit primary actions. Check keyboard focus, accessible names, non-color status labels, normal/narrow windows, and light/dark appearance. The relevant Apple references are [macOS design](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). These are acceptance references, not an accessibility certification.

Live inspection resumed for the existing candidate on October 3. Empty Variables and Env Vars retain visible navigation; the Terraform editor opens without immediate validation errors and Escape dismisses it. Two additional defects were found during inspection: duplicated native text-field labels intruded outside the input sheet, and resource metadata clipped because the inner split allowed a 300-point pane while the inspector required 400 points. Repairs are included in the combined candidate and require a rebuild/live recheck.

## Combined candidate implementation notes

Declared placeholders never become CLI overrides. Required inputs use explicit text and remain actionable while visually muted. Defaults, explicit nulls, empty strings, unresolved expressions and supplied values stay distinct. Discovery uses a pinned universal helper built from HashiCorp HCL/config-inspect tooling; it does not require init or plan. App inputs have command-line precedence; tfvars files take precedence over TF_VAR environment values, including app environment overrides. Configuration edits preserve unsaved drafts across navigation and detect disk conflicts before saving. Saved changes invalidate prior plans.

Run records now capture real plan/apply phase timestamps and optional Git branch/commit when planning starts. Old records omit unavailable metadata. Sensitive discovered values and declared defaults participate in run-log redaction. Provider help loads installed schemas only on request and never silently initializes or installs a provider. Public documentation links do not send workspace values or credentials.

This remains a review candidate, not a new signed release. The final visual matrix includes normal/narrow windows, light/dark appearance, keyboard traversal and VoiceOver labels. Native inspection has repeatedly lost its connection after restarts; do not treat build/test success as completion of that visual matrix.

The HIG design pass also gives Configuration a compact file picker below 620 points, accessible refresh/save controls, a text-and-icon unsaved marker, a resizable, scrolling validation pane and direct formatting of the current file. Required-input summaries and filtering distinguish an empty filter from an empty configuration. Installed schema attribute help has a searchable, bounded panel with required/optional/computed/sensitive labels. Keyboard and VoiceOver behavior still require the live acceptance matrix.

## Verification and review handoff — October 3

The combined Swift suite completed **150 tests, zero failures, one optional online-download test skipped**. The Go parser tests passed, including declaration-only metadata excluding defaults and output values. The universal Debug app and bundled helper contain arm64 and x86_64. Project validation, shell syntax checks and whitespace checks passed. Final focused checks cover editor formatting, external edits, draft retention, bounded cancellation and module/provider context. Actual Terraform 1.16.5 exercised local plan/apply history, formatter output and built-in provider schema loading; no production infrastructure operations occurred.

Configuration help includes provider requirements/aliases/constraints and exact locked-version links, root input/output declarations, pre-init module calls, and installed module input/output declarations. Help omits values and defaults; installed paths must remain within the selected workspace. Registry examples are reached through version-specific documentation links. A full Registry catalog and cached remote documentation remain future design direction. The native editor deliberately limits source reads to 1 MB and offers the external editor for larger files.

The review candidate is `/private/tmp/habitable-next-debug/Build/Products/Debug/Habitable.app`. The installed signed app remains unchanged; this is not a new release. Native inspection failed again after restarting the candidate with `Sky Computer Use native pipe closed before response`. Consequently the final screenshot, light/dark, exact minimum-width, keyboard and VoiceOver matrix remains **open** under rt3.21/.10–.14. User-confirmed empty-sidebar behavior is already closed separately under .31. Do not describe this batch as fully visually verified or accessibility-certified.

## Configuration feedback — October 3, 1:02 AM screenshot

The user requested direct formatting, automatic validation after saved changes to the file currently being viewed, and a draggable editor/validation divider. This supersedes the preview-only formatting interaction in the earlier direction. The current repair uses a native vertical split, keeps validation results reachable through scrolling, and labels validation as checking the saved configuration. Formatting must write only Terraform's formatted stdout, preserve external-change protection and stale-draft checks, and trigger the same save/invalidation/validation path. Debounce/coalesce automatic validation, wait for active Terraform commands to finish, and cancel it when Configuration is hidden or the selected file/workspace changes. Never apply infrastructure automatically.

Tracking: Habitable-3le.4; final live separator interaction remains within rt3.21.

The repaired candidate was reopened after the user confirmed all editor changes were saved. Its running process was verified against the candidate executable. Native inspection still could not reconnect; the divider interaction was explicitly handed to the user for review. Seven focused editor tests pass, including direct formatting with stderr excluded, saved-file auto-validation, rapid-save coalescing, navigation cancellation, external-edit conflicts and draft retention. `.tf.json` remains editable and validated, but Format is disabled because Terraform’s stdin formatter accepts HCL.

Final post-feedback regression: **150 tests, zero failures, one optional online-download test skipped**. The seven Configuration tests passed separately. The final universal Debug build succeeded, both app architectures were verified, and project/shell/whitespace validation passed. Automated implementation checks are complete; the documented live review matrix remains open.

## Agent access, Git context and copy actions — October 3 proposal

The user proposed Alchemy-style agent connections, official Terraform MCP/skills installation, richer Git context, commit-triggered plan-only runs and convenient copying. This section records researched direction, not implemented features. Existing branch/commit run snapshots and safe output/resource-attribute copying were verified in the current source. The new work is tracked in Beads.

| Proposed work | Tracking | Scope |
| --- | --- | --- |
| Built-in Habitable MCP | Habitable-3le.5 | Opt-in local app control and redacted inspection through existing models. |
| Agent connection and skills settings | Habitable-3le.6 | Client-aware connection, Habitable skill, optional official Terraform server/skills. |
| Workspace Git and richer run source | Habitable-rt3.37 | Live repository context and truthful immutable run metadata. |
| Plan-only after new commits | Habitable-rt3.38 | Explicit per-workspace setting, deduplicated background planning with no auto-apply. |
| Consistent copy actions | Habitable-rt3.39 | Paths, identifiers, source references and safe values with native feedback. |

### Swift MCP and native Agents settings

The [official Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) provides server/client APIs, tools, resources, prompts, stdio and Streamable HTTP server transports. The current [published release is 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1); its package requires Swift 6.1 and macOS 13, compatible with Habitable’s current toolchain/deployment target. Pin a release for implementation, not main. The HTTP transport still needs an HTTP listener/framework adapter: its [transport source](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift) accepts requests from that adapter rather than opening a socket itself. Prototype compatibility before adding a networking dependency.

Use a native Agents settings section with server toggle/status, endpoint Copy, recent activity, and client rows with Connect, Disconnect and Copy configuration. Match Alchemy’s useful information structure with Habitable’s system controls and typography. Prefer authenticated loopback Streamable HTTP in the app; supply a bundled stdio bridge for clients requiring subprocess servers. Alchemy’s current source demonstrates a runtime endpoint/token bridge and an MCPB installation path; it is architectural evidence, not proof of another client’s current installation contract.

The first Habitable tool surface should expose workspace readiness, declarations and provenance, redacted run/resource/output summaries, file/line diagnostics, navigation, validation and explicit plan-only requests. Use the same workspace identity, command coordinator, saved-plan invalidation and redaction guards as the UI. Plan requests return a job/run identifier and support cancellation/status polling rather than blocking indefinitely. Defer apply/destroy tools until an explicit in-app review/approval workflow exists. Server access must be scoped to user-selected workspaces; do not expose raw state, credential files or arbitrary shell execution. App controls should show what the agent did.

Keep Habitable MCP separate from [HashiCorp’s Terraform MCP server](https://github.com/hashicorp/terraform-mcp-server), which integrates Registry and HCP/TFE APIs. Offer its Registry tools without automatically granting account operations; deeper HCP integration remains deferred. Offer selected [official Terraform skills](https://github.com/hashicorp/agent-skills/tree/main/plugins/terraform/skills), initially style guide, tests and module refactoring, alongside a Habitable workflow skill. HashiCorp documents individual-skill and Claude/Codex product-plugin installation in its [README](https://github.com/hashicorp/agent-skills). Pin provenance/version and make each optional installation explicit.

Client adapters must respect their current JSON/TOML/native-extension formats, preserve unrelated entries, detect malformed config, and provide backups, atomic changes and rollback. Do not blindly rewrite private extension installation registries. Distinguish Installed/Configured/Connected: a config entry alone does not prove a live connection. Keep credentials out of copied config and skills; use a local runtime bridge where appropriate. No agent configurations or permissions were changed during this research.

### Git context and commit-triggered plans

RunGitContext already captures branch and full commit at plan start, persists them in RunRecord, and displays a short SHA in the run view. Workspace should show repository, current branch or detached HEAD, commit subject/SHA, dirty status and Open repository/Copy actions. Enrich run snapshots with dirty status and trigger source so an uncommitted configuration is never represented as being exactly the commit. Do not persist raw diffs or sensitive file contents merely to capture provenance. Git reads should be asynchronous and bounded and handle subdirectories, linked worktrees, packed refs and absent repositories. Normalize repository URLs without embedded credentials.

A per-workspace “Plan after new commits” setting should default off and work while Habitable is running. Establish a baseline without triggering a run on activation/relaunch. Resolve commit events versus checkout/reset/rebase changes explicitly; watching HEAD alone cannot distinguish them. Coalesce bursts, deduplicate commit IDs, wait for active commands, and show why a plan was blocked by missing inputs or initialization. Capture the exact source at actual plan start.

Crucially, Workspace.didPlan currently checks global autoApply. Automated and agent-requested plan-only runs require a per-run execution policy that prevents this callback from applying them, even when auto-apply is enabled for manual runs. Verify that boundary with regression tests before exposing the setting. Do not install hooks or perform Git writes for this feature.

### Copy actions and delivery order

Add small native doc.on.doc buttons beside workspace/config paths, full commit SHA, resource addresses/IDs, input keys or var references, documentation links and diagnostic file:line locations. Offer context-menu equivalents and clear accessible labels, with short Copied feedback. Existing non-sensitive output and resource-attribute copy behavior should share a reusable control; masked fields must not copy hidden underlying secrets. Keep primary toolbars focused on workflow actions.

Recommended implementation order: copy controls and Git overview; richer run provenance and plan-only policy; a bounded read/validate/plan Habitable MCP prototype; client/skill installation settings; commit-triggered plans after the execution-policy tests pass. Public documentation access remains useful independently of any deeper AI or HCP account features.

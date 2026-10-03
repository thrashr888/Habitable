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

## Scrolling, disclosure targets and following live runs — October 3

User feedback: page scrolling should work over the surrounding container, disclosure titles should be clickable rather than requiring an arrow hit, and run details should reveal the phase currently receiving events.

Habitable-rt3.40 replaces the constrained Settings form with a full-pane ScrollView. System GroupBox sections retain a readable 760-point content limit inside the viewport, so margins belong to the scroll surface. Workspace and output pages already put their readable content inside full-pane scroll views. Run metadata, plan review, apply events and errors now share one native List instead of fixed headers around separate vertical scroll containers. Raw console output remains a dedicated text viewport with its own horizontal scrolling.

A shared [DisclosureGroupStyle](https://developer.apple.com/documentation/swiftui/disclosuregroupstyle) makes each arrow, title and trailing header area one native Button. It exposes Expanded/Collapsed accessibility state and keyboard activation. Module documentation links moved into expanded content to avoid nesting a link inside the disclosure button. This applies to settings, onboarding, provider/module help, resource schema help and run changes/events.

Habitable-rt3.41 follows meaningful Plan/Apply/Errors transitions, including confirmed Apply before its first event, automatic apply, completion and failure. Incoming live version/activity/summary/output sections reveal once; subsequent events respect manual collapse. Final outputs arriving in the same UI update as completion still reveal. Historical runs retain compact disclosures and manual phase selection between transitions. Phase changes do not force scrolling or focus jumps.

Verification: three new presentation tests pass; full regression **153 tests, zero failures, one optional online-download skip**. Universal Debug build and architecture/whitespace checks pass. Native inspection temporarily reconnected to the registered /tmp candidate path and verified no unsaved edits before restart. After reopening the final candidate it again reported cgWindowNotFound/native pipe failures, so final gutter-scroll, full-header click, keyboard and active-phase visual checks remain open under rt3.21 and these interaction issues. The review candidate was reopened; this is not a signed release.

Landing history: two initial Git signing attempts through the configured 1Password signer failed (buffer/agent errors). Signing subsequently succeeded after the user approved the request; the interaction repair is committed together with the follow-on workspace navigation and README changes. Existing unrelated CLI deletion remains unstaged. Native acceptance remains open.

## Independent Astra UX assessment — October 3

The user requested an independent **gpt-6-astra** assessment of newcomer usability, power-user workflows and native quality. Astra reviewed current source, including the staged interaction repair, and this document. Native inspection failed with the existing native-pipe error; no live visual conclusions, app restarts, infrastructure operations or implementation changes were made for this assessment. Review tracking: Habitable-rt3.42.

**Assessment:** Habitable has a strong foundation in explicit saving, external-edit protection, declared-input provenance, version-aware help, structured changes and exact saved-plan application. The highest return now is making those features one predictable edit → supply inputs → validate → review → apply workflow. Finish interaction acceptance before adding agent configuration or commit-triggered planning. Repeated explanations and status panels compete with the next action; more capability alone will not resolve that hierarchy.

### Ranked next batch

| Rank | Improvement and observed source behavior | Tracking | Acceptance |
| --- | --- | --- | --- |
| 1 | Make automatic apply unmistakable. Planning controls still say Plan/Queue plan while `Workspace.didPlan` can immediately apply (`SettingsListPage.swift`, `WorkspaceModel.swift`, `RunListPage.swift`). | Habitable-rt3.43 | Persistent mode indicator and an initiating label explaining automatic application at every entry point. Preserve the efficient expert mode. |
| 2 | Put readiness and the next action immediately below workspace identity. It follows Latest run, Terraform context and Getting started; its icon only checks initialization/validity, potentially contradicting missing inputs (`WorkspacePage.swift`). | Habitable-rt3.44 | One clear next action in every readiness state, with matching icon/text. Active progress and Cancel remain in the same place; secondary detail is below. |
| 3 | Make missing inputs directly actionable. Required only includes already supplied required declarations (`VariablesListPage.swift`). | Habitable-rt3.45 | Separate Show missing and Required only filters, name/description search, workspace navigation to the missing subset, and declaration description/type in editing context. |
| 4 | Put consequences beside Apply. The action precedes planned counts; replacement consequences are buried in disclosures (`RunPage.swift`). | Habitable-rt3.46 | Compact create/update/replace/destroy summary beside Apply; replacement/destruction visible at resource-header level; consistent Destroy terminology. |
| 5 | Follow active phases while retaining inspection. The picker disappears during commands and rendering forces live output (`RunPage.swift`). | Habitable-rt3.47 | During Apply, users can inspect Plan and return to live activity. Follow the transition once, then respect deliberate selection without focus/scroll jumps. |
| 6 | Present validation once, truthfully. Saved-valid and valid messages can repeat alongside unsaved guidance; command locks create generic running states (`ConfigurationPage.swift`). | Habitable-rt3.48 | One state line distinguishes unsaved draft/last saved result, waiting for another command, validating and diagnostic counts. |
| 7 | Standardize terms and native commands. Plan/Queue plan and Variables/inputs/Env Vars vary; principal workflow commands lack a coherent menu/shortcut surface (`ContentView.swift`, `RunListPage.swift`, `HabitableApp.swift`). | Habitable-rt3.49; copy actions remain Habitable-rt3.39 | Consistent planning vocabulary, visible primary labels where space allows, discoverable menu commands/shortcuts, and shared safe-copy feedback. |

### Later bounded improvements

| Rank | Improvement | Tracking | Acceptance |
| --- | --- | --- | --- |
| 8 | Use known declaration types for boolean/numeric/string entry; retain raw JSON for complex/expert values. Put This session/Remember for this workspace near Save. | Habitable-rt3.50 | Ordinary values do not require learning JSON representation first; explicit null/empty/default and sensitive rules remain intact; Terraform is the final authority. |
| 9 | Connect resource and planned-change views to configuration with Open declaration. Extend existing diagnostic navigation rather than building a full visual Terraform builder. | Habitable-rt3.51 | Navigate to a confidently resolved file/line; unknown/generated sources remain honest. |
| 10 | Add status/date/text filtering across saved run history, with clear current-versus-captured configuration context. | Habitable-rt3.52; provenance Habitable-rt3.37 | Large histories stay responsive and navigable. Dirty/trigger metadata prevents a SHA from implying unsaved configuration exactly matched that commit. |

### Cleanup and delivery gate

Use small shared components for page gutters, section spacing, metadata, errors and safe-copy behavior. Reduce repeated Workspace status/context and Configuration success messages. Clarify workspace-scoped Settings. Keep novice guidance contextual and collapsible so experienced users retain a compact working surface.

The resource table needs a deliberate adaptive-width policy: its own collection pane requires 560 points alongside a 400-point inspector and 180-point sidebar, roughly 1,140 points before dividers (`ContentView.swift`, `ResourceListPage.swift`). This is source evidence of a breakpoint to test, not proof of clipping in the running app. Adaptive/accessibility verification remains in Habitable-rt3.10–.14/.21; do not create a second competing acceptance checklist.

The live delivery gate covers 900×560, typical laptop and wide windows; empty/unset/invalid/ready/planning/planned/applying/failed states; gutter scrolling; all disclosure header hit areas and keyboard announcements; manual phase inspection during Apply; save/format/rapid saves/external edits/navigation; keyboard and VoiceOver; light/dark and long paths; create/update/replace/destroy/output-only/no-change plans; safe masked copying; and large state/history responsiveness. Native inspection remains unavailable, so these checks stay open.

The assessment is recorded and follow-ups are filed; recommendations are **not implemented by this review**. Its initial landing was blocked by the configured 1Password Git signer, subsequently resolved during the follow-on workspace changes. No new release or tap update occurred.

## Workspace plan navigation and repository README — October 3

User feedback: the Workspace Plan button should open the run it starts, and the overview should render the repository README. Tracking: Habitable-rt3.53.

The Plan action now passes the existing new-run callback to overview navigation. It selects the exact run only after successful validation and history creation, before Terraform starts planning. Failed validation does not navigate. Review run continues to use the same navigation path.

The overview includes native formatted Markdown with headings, lists, links, code and tables, using pinned [MarkdownUI 2.4.1](https://github.com/gonzalezreal/swift-markdown-ui/releases/tag/2.4.1). Repository-root documentation is preferred when the selected Terraform directory is a subfolder; otherwise the selected directory is used, with a subfolder fallback if the repository has no README. Case-insensitive README.md/README.markdown and plain README/README.txt are recognized. Loading runs off the main actor with a 512 KB limit and rejects symlinks outside the repository. The section shares the page scroll surface and offers Refresh/Open README. Images are explicit links rather than background downloads; unsupported URL schemes and local links outside the repository are rejected. Missing documentation shows an explanatory empty state.

Verification: four focused tests pass, covering exact created-run callback after successful validation, no callback on invalid configuration, repository/subfolder lookup, Markdown/plaintext recognition, missing/oversized files, path boundaries and outside symlinks. The universal Debug build succeeds with both app architectures; native visual acceptance remains open. This is candidate implementation, not a signed release. The configured Git signing succeeded after the user approved the 1Password request; the earlier signing blocker is resolved.

## Navigation performance — October 3

The user reports roughly 250 ms page changes, especially Runs, Configuration, Resources and Workspace. Tracking: Habitable-rt3.54. Process inspection confirmed the current open app is the earlier `/private/tmp/habitable-next-debug` candidate, built without optimization. This does not prove that Debug optimization or any one function explains the entire observed delay.

Source-confirmed avoidable work and repairs:

- Resource view getters repeatedly flattened and redacted the same attributes and synchronously read provider/module documentation files. Cache attribute presentation per resource, invalidate it when values or sensitivity masks change, and load documentation off the main actor with canceled/stale-result checks.
- Settings rebuilt its release catalog on each visit, repeatedly sorted the same versions, and compiled regexes inside comparison-time version parsing. Keep the catalog for the window lifetime, cache its sorted presentation, use strict ASCII numeric parsing, perform installed-version scans in the background, and reuse fresh results for five minutes. Explicit Refresh still fetches immediately; canceled page requests do not mark results fresh.
- Workspace recreated and reparsed README Markdown on rendering/reentry. Retain its parsed immutable presentation for the window, prepare it in the background, reuse unchanged content, and check saved documentation again off the main actor. New workspace identities cannot display the previous workspace's document.
- Outputs repeatedly parsed and pretty-printed JSON during rendering/copying. Cache the formatted presentation and invalidate it for value or sensitivity changes.
- Configuration revisits repeated directory scans and watcher teardown/setup. Keep its existing draft and watcher, refresh the file index in the background on reentry, and reject results after directory changes or newer requests. Initial editor construction/loading still needs live profiling for unusually large files.
- Run action counts repeated the same reduction for each displayed total. Calculate them once per summary rendering. No synchronous saved-plan filesystem verification was found in the run confirmation getters; execution safety checks remain intact.
- Page-selection transactions explicitly disable navigation animation. This addresses a possible contributor to uniform perceived delay, not a measured animation diagnosis. Disclosure animations remain available for user actions.

An opt-in benchmark (`HABITABLE_PERF_BENCHMARK=1`, NavigationWorkTests) compared five resource reads for 1,000 nested values/2,000 displayed rows: repeated flattening **210.28 ms**, cached reads including the cold calculation **41.10 ms**. Five sorts of 300 versions took **32.87 ms** with the previous regex parser versus **16.84 ms** with strict numeric parsing; cached catalog reads do not repeat those sorts. These are Debug component measurements, not measured UI navigation times or a promise of an equivalent improvement for every workspace.

The core regression suite passed **161 tests, zero failures, two expected opt-in skips** (online release download and the separate benchmark). The benchmark and 24 focused navigation/version/redaction tests ran separately with zero failures. Seven focused editor tests ran after the reentry change, with zero failures and the real-formatter test skipped in that focused invocation; the real-formatter test passed in the full suite. Coverage includes sensitivity/value cache invalidation, malformed versions, fresh catalog reuse and forced refresh, external edit conflicts, draft preservation and navigation cancellation.

An optimized universal candidate is built under `/private/tmp/habitable-next-release`. `Page navigation` signposts measure selection to the next AppKit layout and can be correlated with Instruments' main-thread activity. They do not measure actual pixel presentation, completion of background help or network requests. Only static page names are recorded, not workspace contents or paths. Native inspection again failed with a native-pipe error; the optimized candidate's live interaction timings and first/warm-switch acceptance remain open. Verify first and repeated switches across the four reported pages, plus empty/populated states, active run updates, saved/draft/external editor changes, and sidebar/disclosure behavior. This remains a review candidate, not a signed distribution release.

## README destination, editor choice, and workflow hierarchy — October 3

Tracking: Habitable-rt3.55, Habitable-rt3.43, Habitable-rt3.44, Habitable-rt3.47. These implementations are candidates for the existing native acceptance gate, Habitable-rt3.21.

README now has its own sidebar destination, removing its long document from the workspace overview. It retains the background loading, cached Markdown, repository-root lookup, bounded reads and safe links introduced earlier. Its entire page scrolls, with a readable left-aligned content width.

Open in Editor now detects installed Visual Studio Code, Cursor, Zed, Windsurf, Sublime Text, Nova, BBEdit, CotEditor and Xcode through Launch Services. The menu opens the file explicitly in the selected application and remembers that choice across launches. It is shared by Configuration and README. Choose Other Editor supports an explicit application selection; Refresh Editors rescans installations. A removed preferred editor does not silently substitute another application. The inventory lives with the window rather than being scanned during every page render. Local bundle identifiers were verified for installed VS Code, Cursor and Sublime Text.

Workspace readiness and its next action now appear beneath workspace identity and description, before counts, history and context. Command cancellation stays in the same readiness section while workspace commands run. Missing inputs no longer get a ready checkmark merely because initialization and validation succeeded. Automatic apply is explicit in the workspace readiness warning, initiating action, Runs banner and planning control labels/help; Terraform execution behavior is unchanged.

The run phase picker remains available during Apply, allowing inspection of the existing plan. New runs follow the current phase by default; manually choosing a phase suspends following, including through completion or failure. Follow active phase resumes live output. Existing automatic disclosure behavior remains intact.

Verification: **163 core tests pass, zero failures, two expected opt-in skips** (online download and separate performance benchmark). Added coverage checks editor discovery, persisted choice and removed-editor behavior, plus manual plan inspection through Apply updates/failure and explicit following resumption. The final optimized universal app builds successfully for arm64 and x86_64 and passes the universal verifier. Whitespace checks pass.

The earlier Debug app remains the last verified running process. Replacement is awaiting the existing save/quit question; native visual checks, actual external-editor opening and live navigation timings remain open. No distribution release or tap update is claimed for this candidate. Remaining priorities retain their Beads records and the ranked review above: consequences beside Apply, direct missing-input navigation, coherent validation/draft status, keyboard commands, typed input editing, declaration navigation, safe copying, and saved-history filtering.

## Window identity, configuration clarity and workspace cards — October 3

User screenshot follow-up: internal automatic-validation cancellation prose was unhelpful, the configuration-list disclaimer was noise, the page title crossed the sidebar divider, workspace identity was missing on other pages, and overview cards lacked internal space. Tracking: Habitable-rt3.56; related validation and Apply work: Habitable-rt3.48 and Habitable-rt3.46.

Configuration navigation now silently cancels its scheduled automatic validation. Validation activity is tracked separately as idle/queued/running rather than using cancellation and success paragraphs as status. The panel has one saved-configuration status, with a concise Save-to-validate hint when the draft is unsaved. Save/format notices are shorter; actual failures, external-edit conflicts and source diagnostics remain visible. The configuration file-list disclaimer is removed. Regression assertions check actual saved/draft and validation state rather than depending on the removed prose.

The principal toolbar displays the current page and workspace folder name on every workspace destination, including when the sidebar is hidden. The page title has its own natural width, independent of the sidebar column; a long workspace name truncates in the middle and the full path remains in its help text. Native window identity includes the workspace/page for window selection. Live minimum-width and long-title verification remains under Habitable-rt3.21.

Workspace Readiness, Latest run, Terraform context and Checks share a native card component with 12 additional points of internal padding. The existing page gutter and readable content width remain consistent. This addresses cramped contents without adding another scrolling surface.

The local complex QA configuration declares an actual output named `nested` and explicitly marks the entire output `sensitive = true`. It is not an app-generated placeholder. Terraform exposes whole-output sensitivity in [its machine-readable output](https://developer.hashicorp.com/terraform/internals/machine-readable-ui), so Habitable cannot decide that specific children of this output are public. Whole-output redaction remains intact. Plan review already supports selective redaction when actual attribute masks provide that distinction. Structured output rows now show public values using cached formatted presentation; marked outputs get a clear lock and Sensitive value hidden label rather than a cryptic suffix. No value is unmasked by guessing from a key name.

The Apply decision now includes a nearby summary of create/update/replace/destroy/read/import/move and output changes, with a short warning for destructive actions. Replacements count once as replacements, rather than duplicating create/destroy counts; output-only plans remain explicit. A regression checks replacement/deletion/import counts and an output-only summary.

Verification: **164 tests pass, zero failures, two expected opt-in skips** (online download and separate benchmark), including real local Terraform fmt, validation debounce/visibility/external-edit behavior, draft preservation and redaction coverage. Native inspection again returned a closed-pipe error; no live visual or timing acceptance is claimed. The optimized universal Release build succeeds and its verifier confirms arm64 and x86_64. The remaining ranked Beads work and live acceptance matrix are unchanged.

## Restrained titlebar and content styling — October 3

Screenshot feedback showed the previous title repair was inadequate: the page's native navigation title still crossed the sidebar divider while the new principal title appeared as a separate glass capsule. The Alchemy reference uses a plain titlebar identity and an independent content heading. Tracking: Habitable-rt3.57; this supersedes the previous title presentation candidate in rt3.56.

Every page's `.navigationTitle` is removed. A single page heading is laid out above the content pane, after the sidebar divider, with two-line wrapping available. The titlebar contains only a plain workspace name and native sidebar control. It retains useful window-menu identity and full-path help. The Workspace body's duplicate large page heading is removed.

All toolbar items use Apple's supported `sharedBackgroundVisibility(.hidden)` on macOS 26 and newer; older macOS versions retain their ordinary toolbar presentation. This hides the shared glass capsules without replacing native action semantics, shortcuts or menus. Ordinary actions use borderless native buttons; explicit primary actions retain their native emphasis.

Group boxes use opaque, flat control-background panels with restrained four-point corners, thin separators and consistent internal padding. Workspace cards no longer add a second layer of padding. These changes apply across destinations, rather than producing another bespoke title or card treatment for one page.

This batch changes presentation only. Native visual acceptance still requires checking the long Environment Variables title, narrow/wide sidebars, hidden sidebar, toolbar actions, keyboard focus, light/dark appearance, and workspace switching in the rebuilt candidate. Existing data/command execution and sensitivity behavior are unchanged. Build and delivery verification are recorded on the associated Beads issue.

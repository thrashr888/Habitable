# Habitable design refresh: handoff to Claude

## Start here

The user requested this handoff because of Codex quota. Continue the existing design refresh; do not restart or create a competing implementation. Latest implementation commit is `8a52e4a` (separate cloud/local/Settings windows), pushed to `codex/resource-map-classifier`. Draft PR: https://github.com/thrashr888/Habitable/pull/2. Original exploration PR: https://github.com/thrashr888/Habitable/pull/1.

**Active checkout:** `/Users/thrashr888/.codex/worktrees/resource-map/Habitable`.
**Primary checkout:** `/Users/thrashr888/Workspace/Habitable` — do not overwrite its unrelated changes. Work in the active checkout. It was clean and synchronized with origin at handoff preparation.

Read `AGENTS.md`, `docs/design/DECISIONS.md`, and `docs/design/DESIGN-ACCEPTANCE.md` first. Use `bd` for all task tracking (`bd prime`, `bd ready`, `bd show`). The repository requires committing and pushing completed work, and syncing beads using `bd dolt push`; old `bd sync` instructions are obsolete for the installed version. Preserve unrelated changes/stashes.

## User expectations

- Keep working until one coherent page/flow can be tested end to end. Do not repeatedly stop to ask whether to continue.
- Compare actual running UI against the original mocks before saying it is ready. A build/test pass is not visual acceptance. Include screenshots and exact test steps in handoffs.
- Use the user's real infrastructure in product flows. No sample cloud-map onboarding. Fixtures are for isolated tests only.
- The user authorized cheaper subagents for bounded tasks. Delegate independent model/testing work where useful; retain ownership of integration and live QA.
- Maintain one stable preview app installation and one running app process. Multiple intentionally separate native windows are now desired; duplicate app builds/processes are not.
- Read-only diagnosis of existing HCP state was authorized. Do not print credentials, signed URLs, raw private Terraform state, or variable values. No apply/plan/variable write is needed for UI QA. Variable Save is an explicit user action.

## Latest approved architecture (overrides older mocks)

The user explicitly requested:

1. A separate HCP Terraform/Terraform Enterprise window for remote organizations and workspaces, owning the full viewport.
2. Separate local-only workspace windows.
3. A separate shared Settings window for Connections.
4. Remove HCP Terraform from the local sidebar.
5. Link between windows, including a local folder's matching remote workspace.

Implemented in `8a52e4a`:

- `HCP.browser`: reusable cloud window, Map / Runs / Variables sections. Variables is a full page, no longer the temporary bottom drawer.
- `Workspace.viewer`: local WindowGroup, local Terraform actions scoped to the focused local window. Local Variables button opens the local Variables page.
- `App.settings`: reusable Settings/Connections window, sharing the cloud model with the HCP window. Command-comma and toolbar/menu links open it.
- Folder-specific execution, Terraform and agent options remain explicitly labeled **Workspace settings** in the local window. Shared Connections is separate.
- Initialized `cloud`/`remote` backends with an exact `workspaces.name` expose **Open in HCP Terraform**. Resolution reads bounded `.terraform/terraform.tfstate` backend metadata, including Terraform's null hostname/tags fields. Default host is app.terraform.io. Exact remote selection searches at most five pages, refreshes organizations, and reports failure without selecting a substitute workspace.
- Local folders with a verified remote backend and no loaded local state show **State managed in HCP Terraform**, with the remote window link, instead of a misleading Map state-read failure.
- This supersedes the original unified local/cloud Library proposal. `Habitable-847` was closed as superseded, not delivered as originally described.

The user has not yet reviewed this last build. Do not describe the overall design refresh as accepted or complete.

## Design sources and remaining truthfulness constraints

Original checked-in sources:
- `docs/design/design-explorations.html`: Exploration B, Map/Inspector/Timeline. One workspace owns inventory left, canvas center, Inspector right, timeline bottom.
- `docs/design/map-research.html`
- `docs/design/RFC-resource-map-classification.md`
- `docs/design/DECISIONS.md` (settled decisions, latest window override appended)
- `docs/design/DESIGN-ACCEPTANCE.md` (comparisons, tests, screenshots and remaining gaps)

User PDF exports:
- `/Users/thrashr888/Downloads/Habitable Design Refresh.pdf`
- `/Users/thrashr888/Downloads/Habitable Map Research.pdf`

Prefer the HTML for complete mock width: PDFs crop wide figures. Prior rendered references are in `/tmp/habitable-design-review/` (refresh-07.png, map-4.png; extracted refresh.txt/map.txt).

Accepted details: omit empty map bands, minimum/default 100% zoom, readable 15pt card titles/13pt subtitles/12pt labels, org selection top navigation, no manual regroup/rename override layer. State is authoritative. Do not infer live health/drift, CPU/RAM from an instance class, runtime reads/writes relationships, source file/line, or per-resource history from absent data.

## Current Map and Inspector implementation

Earlier commits `47a42aa` and `386314e` introduced:

- Populated resource-kind bands, resource/endpoint inventory, clearer duplicate tile names, service subtitles and readable sizing.
- Pure orthogonal connection routing with rounded corners and exact attachment points.
- Directed Terraform edges retain exact source/target resource evidence. Collapsing an acyclic resource graph into groups can create reciprocal group edges. Those appear once as `.mixed` grouped connections, have no arrowhead, are excluded from topology ordering, and disclose exact directional pairs. Do not incorrectly delete an underlying dependency to make the grouped graph look acyclic.
- Facts-first Inspector: database engine/version/class/storage/encryption/availability/backup details, endpoints, connected groups, exact members/attributes and copy controls.
- Defined in: local declaration lookup can open the real file in the default editor. Remote state only supplies exact addresses; remote source location remains missing.
- History: recorded state date/serial/version and navigation to workspace Runs. This is state provenance, not per-resource last-change history.
- Displayed values use the production redacted attribute formatter. Its root attribute keys are JSON-quoted keys (e.g. `"engine"`), not `$["engine"]`.
- HCP variable display masks API-sensitive values AND credential-like names via `isMaskedForDisplay`. Some actual variables are credential-like but not API-marked sensitive; do not dump accessibility trees or screenshots containing their unmasked values. Masked editor starts empty, does not prefill the existing value, and requires explicit Save. Presentation masking does not change the server's isSensitive setting.

Main implementation files:
- `Habitable/HabitableApp.swift`: scene ownership, shared cloud model and window commands.
- `Habitable/ContentView.swift`: local-only navigation, scoped commands, remote backend link.
- `Habitable/Views/Pages/HCPWorkspaceViewerPage.swift`: remote sections, connection UI, variable UI.
- `Habitable/Views/Pages/ResourceMapPage.swift`: Map, inventory, Inspector, copy controls.
- `Habitable/Models/ResourceMap.swift`: classification/grouping/dependency evidence.
- `Habitable/Models/MapConnectionRoute.swift`: obstacle routing and rounded path segments.
- `Habitable/Models/MapResourcePresentation.swift`: safe service facts/endpoints.
- `Habitable/Models/HCPWorkspaceViewer.swift`: HCP model/API, exact linked-workspace route.
- `Habitable/Models/HCPMapSnapshot.swift`: state decoding/provenance.
- `Habitable/Models/TerraformConfigurationInspector.swift`: local declarations and TerraformRemoteWorkspaceLink resolver.

## Build, tests and installation

Stable app: `/Users/thrashr888/Applications/Habitable Preview.app`
Bundle ID: `com.thrashr888.Habitable.map-preview`

From the active checkout:

```sh
bash scripts/build-map-preview.sh > /tmp/habitable-preview-build.log 2>&1
```

This stops/replaces the existing stable signed preview and preserves identity. It does not launch it. Open that exact app afterward. Do not create a new app copy per iteration. SwiftUI restores native windows; close only extra QA windows you created.

Full test command:

```sh
HABITABLE_CONFIG_INSPECT_PATH=/tmp/habitable-config-test/Contents/Helpers/habitable-config-inspect \
  swift test --scratch-path /tmp/habitable-map-build > /tmp/habitable-tests.log 2>&1
```

If the helper is missing:

```sh
TARGET_BUILD_DIR=/tmp/habitable-config-test CONTENTS_FOLDER_PATH=Contents \
  bash scripts/build-config-inspector.sh
```

Without the helper, several Workspace/configuration tests fail or skip for environmental reasons. Avoid concurrent SwiftPM builds using the same scratch path.

Final build succeeded and was installed. Final full suite: **292 tests, 8 skipped, 0 failures**. Log: `/tmp/habitable-windows-tests-final.log`. Build log: `/tmp/habitable-windows-installed.log`. Verified exactly one running preview process before handoff. There is one local window, one cloud window and Settings left for review; additional test-created local windows were closed.

## Live verification completed

Real workspace: HCP organization pthrasher_v2, Rookery. Local folder: `/Users/thrashr888/Workspace/Rookery/terraform` (filesystem path may canonicalize case to rookery).

- Opened local Rookery and verified local sidebar contains no HCP/Connections destination.
- Followed both toolbar and content cloud links to the exact remote Rookery workspace, showing 17 groups/57 managed resources/13 data sources.
- Cloud Map owns the full window and its Inspector/inventory; checked minimum and large window layouts.
- Opened cloud Variables as a full page, filtered to a hidden variable for screenshot safety.
- Opened Settings/Connections separately and returned to the same cloud section.
- Confirmed local Plan/Initialize/Validate menu commands are disabled while cloud window is focused.
- Earlier Inspector pass verified copying an engine fact and pasting it into Map search, grouped Certificate/DNS dependency evidence, hidden-value editor with disabled Save and cancel, and History navigation to Runs.
- No remote variables or infrastructure were modified.

Final local-only screenshots (do not commit/upload private account/state images):
- `/tmp/habitable-map-review/cloud-window-final.jpg`
- `/tmp/habitable-map-review/cloud-variables-window-final.jpg`
- `/tmp/habitable-map-review/local-window-final.jpg`
- `/tmp/habitable-map-review/settings-window-final.jpg`

Earlier details screenshots:
- `/tmp/habitable-map-review/inspector-facts-final.jpg`
- `/tmp/habitable-map-review/inspector-provenance-final.jpg`
- `/tmp/habitable-map-review/grouped-connections-final.jpg`

## Where to continue

First get the user's review of the dedicated-window build, then address concrete feedback against the original design. Keep the current Map acceptance work (`Habitable-9gp`) distinct from broader missing functionality. Consult live beads state; this list is an orientation, not a substitute tracker.

- `Habitable-3pb`: completed window separation and basic verified cross-window link.
- `Habitable-5j9`: links before initialization, tagged/prefixed backend workspace selection, reverse cloud-to-known-local-folder links.
- `Habitable-e04`: saved multiple HCP/TFE connection profiles (currently one shared selected connection).
- `Habitable-s1c`: verified remote source file/line provenance.
- `Habitable-g20`: actual history Timeline and change preview. Neither has been delivered.
- `Habitable-fee`: broader classifier/topology corpus validation.
- `Habitable-tuo`: non-AWS, especially GitHub/Datadog-only grouping.
- `Habitable-cvn`: fresh/expired AWS/Azure/GCP Connect login QA. Existing authenticated checks worked; do not claim every expired login path was exercised.

Other limitations worth preserving in handoff: local source editor opening was implemented but not live-tested in the previous Inspector pass; state provenance must not be sold as per-resource history; live HCP was tested, not a real TFE installation; visual acceptance remains the user's decision.

Before each final handoff: build, run appropriate tests, inspect the actual installed app, compare screenshots to the design, record residual gaps in beads, commit/pull-rebase/push, sync beads, and verify clean/up-to-date status. Do not strand completed code in the worktree.

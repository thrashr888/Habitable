# Map visual review checkpoint — 2026-10-04

## Running the preview

Run `bash scripts/build-map-preview.sh`. Every build updates `~/Applications/Habitable Preview.app` using bundle identifier `com.thrashr888.Habitable.map-preview`. The helper requires an Apple Development signing identity (or `HABITABLE_PREVIEW_SIGN_IDENTITY`), builds and verifies a staged replacement, stops previous Habitable map-preview processes, then replaces the installed preview. It does not replace the release app. Open the same preview after the build; do not copy it to a new name or change its identifier. Stable signing avoids creating a new permission identity for every build, though macOS may prompt once when migrating from the older ad-hoc builds.

## Reference comparison

Compared the running native app with `docs/design/map-research.html` Exploration B and the supplied screenshot. Settled decisions in `docs/design/DECISIONS.md` take precedence over older prototype details.

| Reference feature | Current checkpoint |
| --- | --- |
| Dotted canvas and tinted horizontal kind bands | Implemented; empty bands remain compact and visible |
| Compact colored-icon cards with resource composition | Implemented |
| Repeated-resource stack and multiplicity badge | Implemented; badge counts repeated anchors, inspector lists all members |
| Connections visible without selecting a card | Implemented; arrows explicitly mean Terraform dependencies |
| Neighboring workspace pills | Alias-only references from recorded state, with consumer navigation; destination identities are not verified |
| Supporting shelf | Superseded by the settled Identity & monitoring row |
| Screenshot's curved, adjacent workspace ports and exact placement | Not yet matched; current routing uses perimeter lanes and a reference row |
| Security expansion, Flow layout, shared-ID workspace resolution | Remaining work, tracked in beads |

This is a user-review checkpoint, not final visual-spec acceptance. The original PR and checked-in design artifacts are sufficient for this pass; any newer decisions from the original conversation would be useful if they supersede those files.

## Validation

The full Swift package suite passed: 252 tests, 8 skipped, 0 failures. Native Debug build and signed preview installation passed. Model tests cover deterministic ordering, cycles, tile bounds, wrapping, preserved empty bands, remote-state aliases/consumers, and offline sample isolation.

Live native inspection verified the Map reference sample at 75% zoom, stacked Bedrock selection, switching to its second indexed member, closing the inspector, opening a workspace-reference popover, navigating to a consumer, searching/clearing search, and switching to distinct empty and unavailable states. The visual review found a connection crossing behind an intervening card; it now routes through band padding, verified in the rebuilt native app. Earlier HCP read-only verification loaded Rookery with 17 groups and 57 managed resources; that is backend evidence, not acceptance of the new visual layout.

## User test route

Open Habitable Preview and select an existing local workspace, or open HCP Terraform and connect to the saved organization. Select a real workspace and inspect its Map, resource details, search, and dependency connections. No plan or apply is needed. Sample exploration and demo startup have been removed from the app; new workspaces use the existing creation workflow.

## Readability correction after user review

The user correctly rejected the small, low-contrast text at 75% zoom. The earlier visual check missed this usability defect. The minimum/default zoom is now 100%, with 125% and 150% enlargement available. Card titles are 15 points, category labels 13 points, summaries/band labels/badges at least 12 points. Summaries and empty-band messages use secondary instead of tertiary contrast. Cards are 264 by 120 points to accommodate readable text. The rebuilt stable preview was visually inspected at 100% in the native sample sheet; user interaction was observed, so further navigation was stopped. Native build and all 18 Map model/layout tests passed. Overall visual acceptance remains pending.

## Real-workspace product flow

Following user feedback, the sample cloud entry point and sheet are removed. Preview startup now restores the real workspace through the normal app flow; neither a launch argument nor a bundle flag substitutes demo data. Synthetic models remain available to automated tests only. The stable preview identifier and signing workflow are unchanged. Native build passes.

Live verification after removal: normal startup restored the prior local directory; the HCP disconnected screen contains no sample CTA. Connecting through the saved credential loaded the selected real workspace, cool-website in pthrasher_v2, showing 2 groups, 8 managed resources and 4 data sources. No infrastructure mutations were performed.

## Startup failure found by user

The preview still remembered `/private/tmp/Habitable Map Checks/Malformed`, a deliberately invalid QA state fixture. Earlier verification saw that failure and then switched to HCP; that was an inadequate handoff. Switching to HCP did not survive restart, so launch fell back to the local Map and the old fixture.

The app now remembers whether the last selected source was local or HCP. HCP startup does not load an unrelated saved local directory. Local folder opens still select the local Map. State failures identify the workspace, offer refresh, and preserve selectable, left-aligned Terraform diagnostics behind a disclosure.

Verified with the rebuilt stable preview: opened and expanded the malformed-state diagnostic; switched to HCP; quit via Command-Q; relaunched; confirmed HCP was selected with no local fixture loaded; connected using the existing saved credential; confirmed Rookery loaded with 17 groups, 57 managed resources and 13 data sources; refreshed Rookery and confirmed the same loaded counts with no error. No Terraform state or infrastructure was modified. Native build and diff checks passed. This verifies startup and state loading, not full Map design acceptance.

## Collapsible workspace and variable context

Map now offers Workspaces on the left and Variables on the right. Each can be hidden. Selecting a resource replaces the variable panel with its inspector; closing the inspector restores variables. The local Map reuses the existing input summary and links to Manage variables. HCP loads workspace-specific Terraform/environment variables, masks sensitive values, and offers an explicit value-only editor. Inherited variable sets and configuration-file values are explicitly outside this panel's current scope.

HCP API behavior follows https://developer.hashicorp.com/terraform/cloud-docs/api-docs/workspace-variables. Save preserves the variable key, category, HCL and sensitive flags. Sensitive replacements start blank, unchanged drafts cannot save, Cancel discards drafts, and failed saves retain the loaded value. Responses from a previous workspace cannot populate the newly selected one. A successful PATCH requires a valid matching variable resource in the response. Neither editing nor saving queues a run or applies infrastructure.

Validation: native Debug build passes; full suite passes 261 tests, 8 skipped, zero failures. New API/model tests cover pagination, sensitive masking, value-only PATCH, sanitized errors, invalid success responses, successful update metadata preservation, unknown-variable rejection, stale reads and stale saves. Live native QA against real HCP data covered panel toggles, variable loading, Rookery to cool-website and back, empty variables, tile inspector and return, sensitive editor with disabled Save, ordinary draft edit/Cancel and remote refresh confirming unchanged original value. No real variable writes were performed. Live screenshot review caught and fixed a footer clipping issue after panel toggles.

Screenshots are local review artifacts, not uploaded to the repository: `/tmp/habitable-map-review/rookery-map-panels.png`, `/tmp/habitable-map-review/rookery-map-panels-hidden.png`, and `/tmp/habitable-map-review/sensitive-variable-editor.png`. The variable panel screenshot is filtered to a sensitive variable so it contains no variable value.

User test route: use the existing Habitable Preview on HCP/Rookery; toggle Workspaces and Variables; clear the variable filter; switch workspaces and confirm both map and variables follow; select a tile and close the inspector; edit a value then Cancel. For a variable change you actually intend, choose Save to HCP Terraform, refresh, and verify the value in HCP. That real write/readback remains unperformed by agent QA. The broader Map design acceptance and port/routing refinement remain open.

## Separate connection navigation

Moved hostname, credential import, connect/disconnect and connection refresh to a dedicated Connections sidebar page. The connected workspace browser now puts the organization picker in its top navigation row. Variables is the far-right Map toolbar control. Custom Terraform Enterprise hostnames remain supported; multiple saved connection profiles are tracked separately in Habitable-e04.

Validation: native Debug build passed; 32 HCPWorkspaceViewer tests passed with zero failures; diff check passed. Live inspection of the rebuilt stable Habitable Preview covered disconnected Map to Connections, connection using the existing credential, Open workspaces returning to real ethertext data (3 groups, 10 managed resources, 1 data source), opening the top organization menu, and workspace sidebar visibility. The Map screenshot confirms the connection form is absent and Variables is rightmost. No real variable or infrastructure changes were made.

Final-build screenshots: `/tmp/habitable-map-review/connections-page.png` and `/tmp/habitable-map-review/compact-map-navigation.png`. User test route: Connections, Open workspaces, select an organization/workspace, then toggle the far-right Variables control. Overall Map visual acceptance remains open.

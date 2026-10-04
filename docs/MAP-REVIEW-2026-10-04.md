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

Open Habitable Preview → HCP Terraform → Explore a sample cloud map → choose Map reference. Inspect groups and stacked members, follow purple reference pills, search, toggle connections, and switch between reference, Acme, empty, and unavailable samples. Then use the existing HCP connection to inspect a real workspace. No plan or apply is needed.

## Readability correction after user review

The user correctly rejected the small, low-contrast text at 75% zoom. The earlier visual check missed this usability defect. The minimum/default zoom is now 100%, with 125% and 150% enlargement available. Card titles are 15 points, category labels 13 points, summaries/band labels/badges at least 12 points. Summaries and empty-band messages use secondary instead of tertiary contrast. Cards are 264 by 120 points to accommodate readable text. The rebuilt stable preview was visually inspected at 100% in the native sample sheet; user interaction was observed, so further navigation was stopped. Native build and all 18 Map model/layout tests passed. Overall visual acceptance remains pending.

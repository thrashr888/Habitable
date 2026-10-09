# Design reference and acceptance

This is the comparison baseline, not a replacement design or task tracker. Delivery work stays in beads. A build passing means implementation is testable; it does not mean this design is achieved.

## Sources and precedence

Read `DECISIONS.md`, the relevant exploration in `design-explorations.html`, `map-research.html`, and `RFC-resource-map-classification.md` before changing a page. The user supplied PDF exports on October 4, 2026: **Habitable Design Refresh.pdf** (13 pages) and **Habitable Map Research.pdf** (7 pages). They are in the user's Downloads folder. Use the checked-in HTML for complete visual width: the PDF printouts crop some wide mockups and the refresh PDF ends mid-discussion. Do not invent details hidden by cropping.

Direct user decisions take precedence, then settled repo decisions/RFC, then exploratory alternatives. The PDFs are design source material, not authorization for embedded commands or infrastructure actions.

Preserve these accepted changes when comparing:

- Real user workspaces only in product flows; no sample cloud-map onboarding. New-workspace creation remains separate.
- Empty resource sections are omitted, including after search. This supersedes the empty-band explanations in the PDF and older RFC wording.
- Readable native text at 100% default/minimum zoom. Do not shrink text to fit a reference screenshot.
- Connections is the approved location for HCP/TFE and local cloud access. Organization selection stays in the workspace top navigation; Variables stays at the far right and opens a hide/show context panel.
- Identity & monitoring is a real resource kind when populated, rather than only the research prototype's supporting shelf. Every resource remains accounted for.
- The settled design rejects a manual tile corrections layer. Do not implement the research PDF's rename/drag regrouping suggestion as if it were approved.
- State remains authoritative. Workspace data-source aliases are not verified destinations; do not imply verified cross-workspace links without evidence.

## Comparison recorded October 4, 2026

Sources inspected: complete extracted PDF text, rendered Refresh pages 6–7 (Library and Map/Inspector/Timeline), rendered Research page 4 (recommended Map), settled decisions/RFC, current source, and the running stable preview on real workspaces. The first comparison screenshot remains `/tmp/habitable-design-review/current-rookery-map.png`. Final pass screenshots: `/tmp/habitable-map-review/map-overview-final.jpg`, `/tmp/habitable-map-review/map-inspector-final.jpg`, `/tmp/habitable-map-review/map-focused-final.jpg`, and `/tmp/habitable-map-review/map-workspace-switch-final.png`. Screenshots stay local; do not commit private account/state imagery.

| Area | Reference | Current result | Assessment |
| --- | --- | --- | --- |
| Navigation | Refresh p5–7: unified Library and workspace Map, Inspector, Timeline | Top Map now preserves selected local/HCP source. Connections does not change source. Local operations remain disabled on cloud Map. Legacy sidebar and separate HCP browser remain. | Current Map route fixed; unified Library remains Habitable-847. |
| Map prominence | Refresh p7: resource inventory, compact workspace header, canvas dominant | Organization and workspace popover replace the repeated picker/filter row. Hide/show resource inventory now includes endpoints and populated kinds. Variables stays far right. | Implemented and inspected live, including panel resizing. |
| Tile meaning | Research p4: recognizable infrastructure things, concise service detail and composition | Duplicate names gain short Certificate/CDN/DNS/Bucket/Network qualifiers. Service subtitles use redacted state facts such as engine, desired count and CIDR. Exact members are one disclosure away. | Major naming gaps corrected; generic Terraform names and non-AWS semantics still need broader corpus review. |
| Grouping correctness | Research p2–4, RFC: facets/helpers belong to the thing they serve | Auto Scaling is Apps; Elastic IP is Network; database/cache subnet helpers now attach to their service. Rookery still accounts for all 57 managed resources across 17 groups. | Regression-tested and inspected live. Broader corpus/topology validation stays in Habitable-fee. |
| Connections and layout | Research p4: clean within-row flow and neighboring-workspace ports | Obstacle-aware orthogonal routes connect neighboring card sides; selected service relationships are emphasized. Cards fit three columns at the reviewed overview width without shrinking text. | Improved and inspected; ports still represent unverified aliases, not a Library system graph. |
| Inspector | Refresh p7: human explanation, endpoints, exact detail one step away | Safe service facts and endpoints precede connections and collapsed membership/attributes. Inventory selection scrolls the card into view. Full inspector opens the exact resource. | Implemented and inspected with real database state. No invented health/drift/capacity claims. |
| History and change | Refresh p7–9: Timeline, preview colors/counts and consequences by Apply | Current-state map and separate Runs; no history scrubbing or plan overlay on Map. | Not delivered; tracked in Habitable-g20. |
| Visual foundation | Purple selection, restrained kind colors, compact groups; readable text | 100% minimum zoom, 15pt titles, 13pt service subtitles, 12pt counts/band labels. Empty sections hide. Inventory, canvas and Inspector work together. | Current-state Map + Inspector review build delivered; user visual acceptance remains pending. |
| Connections | Later user-approved addition | Real local AWS/Azure/Google authentication checks and guarded CLI Connect actions retained. | Supporting page; fresh expired-session login QA remains Habitable-cvn. |

This pass is the **current-state Map + Inspector** review target (Habitable-9gp), not completion of the whole original refresh. Broader Library/Timeline/preview scope is explicitly retained above. GitHub/Datadog grouping remains Habitable-tuo.

Validation: final native build installed into the single stable preview; full Swift suite executed 280 tests, 8 skipped, zero failures with the pinned configuration-inspector helper. Earlier missing-helper failures and a stale layout-width expectation were resolved before the final pass. Live QA covered real workspace switching both ways, exact-type search, no-results recovery, empty-band omission, inventory/endpoint selection, panel resizing, Variables hide/show without writes, full resource drilldown and return. Visual inspection caught and fixed the attribute-path mismatch, selection scroll positioning, and workspace-list click handling. Infrastructure and variable values were not changed.

## Inspector review follow-up, October 4, 2026

Compared the user's 9:53 PM Inspector mock with the installed real Rookery map. Rounded orthogonal connector corners now retain exact attachment points. Opposing dependencies produced by collapsing different resources into tiles appear once as a grouped connection, without an arrowhead; expandable evidence preserves every exact directed resource pair. A synthetic acyclic resource graph verifies this case.

Variables now has its own resizable bottom drawer and can remain open alongside the Inspector. Copy controls cover displayed facts, endpoints, Terraform addresses, types, state versions and non-private variable values. Credential-like variable names are hidden even when HCP does not mark them sensitive; their editor starts with an empty replacement field. This changes presentation only, not the HCP sensitivity setting.

The Inspector now includes At a glance (database engine/version/class, storage/encryption, availability, backups, protection and last recorded status when present), endpoints, connected resources, Defined in, and History. Local source declarations can open in the default editor. Remote source file/line remains unavailable and is tracked in Habitable-s1c. History shows the recorded state date/revision/version and opens workspace Runs; per-resource history and the timeline remain Habitable-g20. State status is not presented as a live health or drift check. CPU/RAM values are not guessed from instance class names.

Final native build succeeded; full Swift suite: **288 tests, 8 skipped, 0 failures** with the configuration-inspector helper. Exactly one stable Preview process was running. Live QA verified real Rookery load, rounded paths, Certificate/DNS grouped-link evidence, copying a database fact and pasting it into Map search, independent drawer/Inspector visibility and retained selection, masked variable editor plus disabled Save and cancel, and History navigation to Runs and back. No cloud variable writes or infrastructure operations were performed. Local source opening is implemented but not exercised against a local workspace in this pass.

Final screenshots inspected locally: `/tmp/habitable-map-review/inspector-facts-final.jpg`, `/tmp/habitable-map-review/inspector-provenance-final.jpg`, `/tmp/habitable-map-review/variables-inspector-final.jpg`, `/tmp/habitable-map-review/grouped-connections-final.jpg`. These contain private workspace context and stay out of the repository. User visual acceptance remains pending on Habitable-9gp.

## Separate workspace windows, October 4, 2026

The user explicitly replaced the unified Library direction with separate HCP/TFE, local workspace, and Settings windows. HCP now owns the whole content area, with organization/workspace selection and Map, Runs and Variables sections. Cloud Variables is a full page. HCP Terraform and Connections are removed from the local workspace sidebar; titlebar and File/Window menu actions link the native windows. Folder-specific settings remain labeled Workspace settings; shared Connections opens in the reusable Settings window (also Command-comma). Cloud and Settings share connection state without sharing the local Terraform runner.

Initialized named cloud/remote backends expose an Open in HCP Terraform link. The resolver reads bounded backend metadata only, accepts Terraform's null default hostname fields, and never infers a remote workspace from a directory name. Routing uses the exact hostname, organization and workspace name, checks up to five pages, refreshes available organizations, and fails explicitly without selecting another workspace. Broader uninitialized/tag/prefix/reverse-link discovery remains Habitable-5j9. A local folder whose state is remote shows a cloud handoff when no local state is loaded.

Final validation: native build installed in the existing stable Preview; **292 Swift tests, 8 skipped, zero failures**, including serialized backend resolution, exact routing across pages and no-fallback routing. Live QA opened the real Rookery local folder and followed its link to Rookery in the cloud window, checked local navigation without cloud destinations, separate full-page Variables, Settings round-trip preserving the cloud section, restored windows and disabled local Terraform commands in the cloud window. No variables or infrastructure were changed. Extra local QA windows were closed, leaving one local window, the cloud window and Settings in the same app.

Final live captures inspected: `/tmp/habitable-map-review/cloud-window-final.jpg`, `/tmp/habitable-map-review/cloud-variables-window-final.jpg`, `/tmp/habitable-map-review/local-window-final.jpg`, `/tmp/habitable-map-review/settings-window-final.jpg`. Private workspace screenshots remain local. The window boundary now matches the workspace-owned Map in Exploration B while following the user's newer cloud/local separation. Timeline, remote file/line provenance and visual acceptance retain their existing tracked gaps.

## Exploration B window pass, October 5, 2026

Compared against Refresh p7 (Exploration B: one workspace window, inventory left, Map as the viewer, Inspector right, Timeline along the bottom, compact title and a Map | List toggle) and the window-ownership decision of October 4.

| Area | Reference | Now | Still open |
| --- | --- | --- | --- |
| Local window chrome | Compact title `acme-web / production · AWS us-west-2 · This Mac`, Map \| List | Native title is the folder; subtitle is `<terraform workspace> · <state location> · This Mac`. Toolbar: Map \| List, **Preview Changes** (prominent; "Preview and apply automatically" when auto-apply is on), Inputs, Changes, a Workspace menu (Overview, About, Source files, Outputs, Environment variables, Workspace settings), cloud link, Settings. The page sidebar is gone; secondary pages open in place with a **Map** back control (⌘[). | Inputs still opens the full Variables page rather than a sheet. Workspace Info is a menu, not a ⌘I panel. |
| Cloud window chrome | Same single row with an HCP Terraform badge | One toolbar row: workspace chooser (organization picker + workspace list popover), Map \| Runs, Variables far right. Title is the workspace; subtitle `<organization> · HCP Terraform`. The Map header is one row: inventory toggle, search, zoom, connections, List, refresh. | Runs section layout unchanged from the three-column viewer. |
| Timeline | `Changes · 12 applied since Sep 2`, date labels, clips with +add ~change −remove, selected clip in purple | Timeline strip at the bottom of both Maps built from recorded runs only: local clips carry recorded add/change/destroy counts; HCP clips show their recorded status because the run list carries no counts. Each card shows its day; selection scrolls into view and opens the run. | No map scrubbing: Habitable has no historical state versions and must not simulate them. HCP plan counts would need one plan request per run. |
| Status chips | `23 resources · 22 in sync · 1 drifted` | Chips for resources, groups and data sources (data sources open List). | Sync/drift are not known from state and are not shown. |
| Tile names | `app.acme.com · DNS record`, `TLS certificate`, `Uploads · S3` | Tiles whose plain name collides (every Rookery resource is named `rookery`) now take their state identity: `rookeryhq.com · DNS`, `rookeryhq.com · Certificate`, `rookeryhq.com · CDN`, bucket `rookery-prod-h48xufya`, key pair `rookery-prod`. Identities come only from redacted display attributes. | `Rookery · SES domain` style remains where no identity attribute exists; GitHub/Datadog grouping (PR #3) is included but not corpus-validated. |
| Links between windows | Later user decision | Uninitialized cloud/remote declarations, tag/prefix selectors and reverse cloud→local folder links (PAUL-168). | Tag/prefix and uninitialized paths are unit-tested, not exercised on a real folder. |

Validation: native build installed in the single stable Preview; full Swift suite **313 tests, 8 skipped, 0 failures**; Go helper tests pass. Live on Rookery: local window with the new toolbar and Changes page back control, cloud window single-row chrome, workspace chooser popover, identity tile titles, timeline strip with day labels and selection, HCP → Open local folder. Screenshots (local only): `/tmp/habitable-map-review/cloud-window-explorationB.jpg`, `/tmp/habitable-map-review/local-window-explorationB.jpg`.

Test route: open the stable Preview → cloud window shows Rookery with one toolbar row; click the workspace name to change organization/workspace; toggle Map/Runs; Variables at far right; scroll the Changes strip and click a clip to land on that run; toolbar **Open local folder** opens `~/Workspace/Rookery/terraform` in a local window whose toolbar shows Map \| List, Preview Changes, Inputs, Changes, Workspace; **Changes** shows the page with a **Map** back control.

Issue tracking moved to Linear on October 5, 2026: this pass is PAUL-169; Map acceptance remains PAUL-33.

## Feedback round, October 5, 2026 (after the Exploration B pass)

Paul's review of the Exploration B build: much closer to the mocks; inventory should animate and toggled slowly (~500 ms); Map zoomed in but not out; Runs UI had tiny text and raw log output; inputs/variables were hard to follow as wrapping cards (compare HCP Terraform's table); toolbar glass capsules looked wrong.

| Feedback | Change | Verified |
| --- | --- | --- |
| Inventory animation and speed | Inventory is a fixed 204pt column that slides in/out (`.move(edge: .leading)`, 0.22 s). Layout, obstacle routing and service facts are memoized per visible tiles/width step/zoom, so toggling no longer recomputes routes for every frame or render. ⌃⌘S toggles it. | Toggled live both ways; routing work no longer repeats on toggle. Exact timing not instrumented. |
| Zoom | Zoom menu now 50/75/100/125/150% with Zoom In ⌘=, Zoom Out ⌘-, Actual Size ⌘0. 100% stays the default. | Live: menu opened, 50% scaled the whole Rookery map into view, ⌘0 returned to 100%. |
| Runs | HCP run detail parses Terraform JSON-UI lines and the plain text format (ANSI colors stripped): consequences row (to add/change/replace/remove), planned changes with action chips, apply activity, diagnostics as callouts, other output and raw logs collapsed. Nothing below 12pt; run list rows 13/12pt with status dots. Errored runs show their status instead of a false "No changes". | Live: the errored "Fix HCP Terraform GitHub provider auth" run shows a Diagnostics callout with the provider install error and address. Live: the applied "Verify clean plan after stabilized validation" run shows 0/0/0/0 with No changes, its data-source reads collapsed under one disclosure, apply activity and the health-check warning diagnostics. HCP emits text or JSON-UI logs depending on the workspace setting; both parse. |
| Inputs/variables | Both the local Inputs page and HCP Variables are tables with a pinned header: Key (mono, description, type · declaration), Value (mono, single line, masked values keep their placeholder with a lock), Source/Category chips, trailing actions. Compact single-column rows under 760pt. | Live: local Inputs page on Rookery shows the table with masked sensitive values and tfvars provenance. |
| Toolbar glass | Toolbar groups use the existing `QuietToolbar` (shared glass background hidden) in both windows; the inventory toggle is a plain symbol button. | Live: flat toolbar items in both windows. |

Validation: full Swift suite re-run after these changes (see commit message for the count); native build installed into the stable Preview. Screenshots stay local.

## Inspector faces and Settings, October 5, 2026

Taken from Alchemy's inspector and System Settings shapes (see `DESIGN.md` §2).

| Area | Change | Verified |
| --- | --- | --- |
| Inspector faces | The Map's right pane is always present when faces exist: a segmented control (Inspector · Changes N · Inputs N locally; Inspector · Runs N · Variables N in the cloud window) above the chosen face. Selecting a tile returns to Inspector. With nothing selected the Inspector shows the workspace name and state provenance. Changes/Runs is a compact newest-first list of recorded runs (status dot, title, relative date, counts or status); Inputs/Variables is a compact key/value list with the page's own masking and an Open link. | Live in the cloud window: Runs 50 and Variables 19 faces, masked credential-like values, Open Variables link. Local window: Changes and Inputs 43 faces present on the remote-state Rookery folder. |
| Remote-state folders | The local window keeps the Map shape: the canvas shows "State managed in HCP Terraform" with the Open button as the Map's empty state, so Inputs and Changes stay on the right. | Fixed after a first pass showed the state-read error instead; re-checked live. |
| Settings | `Window("Settings")` is a 220pt sidebar (identity block with version, General · Connections · Terraform rows with colored symbol tiles, accent wash on the selected row, selection remembered) and a pane with a centered header tile and grouped forms. General holds Windows and Links groups; Connections is the restyled HCP/TFE and local cloud groups; Terraform shows the active version, executable and latest stable read-only with a link to Workspace settings, because version switching is per workspace. | Live: all three panes; Connect/Refresh/Disconnect controls present; local cloud rows with disclosures. |

Follow-up the same day: the local Inputs face was checked live (43 inputs, sensitive values masked, defaults labelled). Light mode was checked by forcing the preview app's appearance: light canvas with white tiles and hairlines, readable timeline and chips, Settings panes correct; nothing needed changing. The two General toggles now feed the next local window (open last folder) and the next Map (inventory shown). Terraform version changes stay in Workspace settings.

## Library and Inspector Reference, October 6, 2026

| Area | Reference | Now | Verified |
| --- | --- | --- | --- |
| Library | Refresh p6 (Exploration A): every workspace as a card with a miniature map, sidebar of This Mac / HCP, needs-attention lead | A local window with no folder shows the Library: 220pt sidebar (All infrastructure, This Mac, one row per HCP organization, Open Folder…), a sheet of cards grouped This Mac / `<org> · HCP Terraform` with a filter field, and a status line (`5 folders · 50 cloud workspaces`). Cards: a miniature of the map (one row per populated kind, blocks colored by kind), name, location, `N resources · N groups · <relative date>`. Summaries come only from `terraform.tfstate` (local backend) or the workspace's current state version (cloud, cached by version); a remote-state folder borrows its linked workspace's summary. Opening a card opens the folder in this window or the workspace in the cloud window. File › Library (⌘⇧L) and a Library toolbar button open it from a workspace. | Live: 5 folders and 50 pthrasher_v2 workspaces; Rookery folder and workspace both show the 57-resource thumbnail; test workspaces without state say "No recorded state". No attention/drift chips: nothing recorded supports them. |
| Inspector reference | Refresh p7 (Inspector: exact detail one step away) and Paul's request for Registry info | A Reference section after Defined in: type, provider and version (locked version locally; Registry-resolved in the cloud), Open in Registry and Provider links, Attribute reference from the installed provider schema (local, initialized), and Registry documentation fetched read-only from the public Registry API with Argument/Attribute Reference first. | Live in the cloud window on `aws_db_instance.postgres`: `hashicorp/aws 6.67.0`, links, Registry documentation sections loaded. Local Attribute reference not exercised live (Rookery's state is remote). |

Validation: full Swift suite (see commit), native build installed into the stable Preview. Screenshots stay local.

## Library round 2, October 6, 2026

Paul's review: thumbnails overflowed their cards; switching organization reloaded the organization list and showed "Connect…" instead of a loading state; cards loaded only when scrolled to; asked for checkout of HCP workspaces onto this Mac and a purple loading mark.

| Feedback | Change | Verified |
| --- | --- | --- |
| Thumbnails | Canvas-drawn miniature: bands and tiles scale to the 118pt thumb, `+N` for overflow, placeholder rules until a summary exists. | Live: Rookery's 15-group thumbnail fits; small workspaces draw one or two tiles. |
| Organization switching | `switchOrganization` keeps the connection and organization list and reloads only workspaces; the row and sheet show the loading mark. | Live: hc-ric-demo → pthrasher_v2 without a "Connect…" flash. |
| Loading mark | `LoadingIndicator`: three accent bars rising in turn, static under Reduce Motion; used in the Library, Map loading and Variables loading. | Live in the Library. |
| Background loading | `refreshAll` loads every card with three workers, local first, refreshes every five minutes while the Library is open, and skips cloud downloads whose state version id is unchanged. | Live: 50 pthrasher_v2 cards populated without scrolling. |
| Check Out | Repository-backed workspaces get **Check Out…** (card context menu, cloud toolbar when no linked folder): choose a parent folder, `git clone` without prompts, remember the link, open the folder. Folders show "Checked out from …", workspaces "On this Mac". | Model tested against a local bare repository; not yet run against a GitHub-backed workspace live. |
| Window identity | A Library window stays a Library across relaunch (content keyed on the window value). | Live after relaunch. |

## Library round 3, October 6, 2026

| Feedback | Change | Verified |
| --- | --- | --- |
| Real checkout | **Check Out…** on the ethertext workspace (thrashr888/ethertext) cloned with the panel's Check Out Here (the panel now defaults to `~/Documents/Habitable`, GitHub Desktop style, changeable in Settings › General › Checkouts), showed "Checking out…" in the toolbar, recorded the link, and opened a local window titled `ethertext · Checked out from HCP Terraform · This Mac` whose Map empty state explains the checkout and links back. The cloud window's toolbar then offers Open local folder for it. | Live. |
| Window menu | Every window registers with the Window menu (`WindowMenuMembership`). | Live: HCP Terraform, Settings and the local windows listed. |
| Filter fields | `FilterField` with a clear button and Escape in the Library, the workspace chooser, the Runs column and the Variables page. | Live in the Library. |
| Variable sets | The Variables page lists applied variable sets (name, Global/Priority chips, description) with their variables as read-only masked rows. | Live: ethertext shows `aws-personal · 3 variables` with secrets masked. |
| Tags, projects, run status, attention, recent | Workspaces carry project, current run, updated time and HCP's resource count; Explorer rows add drift and check results when the plan allows (silent fallback otherwise). Library sidebar: Recent, Needs attention (only when HCP reports something), project rows under the organization, Tags with counts and stable colors. Cards: status dot + word (Applied, Needs approval, Errored, Drifted…), tag chips, HCP's resource count before state is read. Cloud groups sort by last change; an attention strip leads All infrastructure. | Live: Recent 8, Needs attention 1 (new-website: latest run errored), projects Examples/Health/Personal/meridian-demo, Applied dots. No tags on these workspaces, so the Tags block stays hidden. |
| Cached details | Summaries persist to `~/Library/Application Support/Habitable/library-summaries.json` (30-day expiry, 4 MiB bound) and restore at launch before the background refresh. | Unit-tested; cache file written on this Mac. |
| Changes strip | Chevron hides or shows the strip; remembered. | Live. |
| Remembered views | Cloud section (Map/Runs/Variables) and the inspector face persist per window via SceneStorage. | Built; not exercised across relaunch. |
| Wording | Status chips and cards say "tiles" instead of "groups": a tile is one thing on the Map, a band is a row of one kind. ethertext's "3 tiles" are Ssl Cert, S3 Distribution and Website Bucket across two bands. | Live. |

Open question filed (PAUL-174): why `aws_route53_record.route53_record` folded into the Ssl Cert tile rather than the CloudFront distribution it points at; the classifier needs real-world validation beyond Rookery.

## Library round 4, October 6, 2026

| Feedback | Change | Verified |
| --- | --- | --- |
| Changes → state | Clicking a change in the cloud window's Changes strip now shows the Map as HCP Terraform recorded it after that run (its state version), with a banner "State as recorded <date> · revision N" and **Return to current state**. Runs that produced no state (plan-only, errored) open the run instead. Current state is never replaced; the historical snapshot is a separate read-only download. | Built and unit-tested (state-version list, state-version map without credentials on the download, forRunID true/false, clearing on workspace change). Live click not completed in this session (input blocked while Paul was typing). |
| Runs in the inspector | The Runs face is gone from the cloud inspector and the Changes face from the local one; the strip carries a status dot (green applied, red errored, orange running) on every card. | Built. |
| Source links | "Defined in" resolves file and line from a checkout of the workspace's repository and links **Open on github.com** (blob URL with line anchor; GitLab/Bitbucket forms too). Without a checkout, a repository-backed workspace shows an Open <repo> link and says a checkout would resolve the line. | Built; needs a checked-out repository-backed workspace with state to see a resolved line. |
| Inspector attributes | Each resource in a tile is its own disclosure; opening one shows that resource's type and attributes beneath it. No more flat attribute list under a list of resources. | Built. |
| Disclosure headers | `HeaderDisclosureStyle`: the whole header toggles. Applied in the cloud window, Library and Settings. | Built. |
| Tags | Tags sit under their organization, after its projects: top 8 by count, "N more…" folds the rest with a tooltip listing them. | Built; pthrasher_v2 has no tags to show. |
| gym-* workspaces | 144 empty `gym-*` workspaces in pthrasher_v2 deleted with HCP's safe-delete (refuses workspaces that manage resources). | Done, 144 of 144. |
| Descriptions | Workspace descriptions decode and show on Library cards (two lines) and in the cloud inspector when nothing is selected. | Live: terraform-fast's description in the inspector. |
| Sorting | Library sort menu: Last change (default), Name, Resources, Status; remembered. | Built. |
| Checkout folder | Default `~/Documents/Habitable`, Settings › General › Checkouts. | Live: Paul checked terraform-fast out there. |

## Round 5: gaps against the design, October 6, 2026

| Gap | Change | Verified |
| --- | --- | --- |
| Preview Changes on the Map (Exploration C) | A local folder's saved plan now renders on the Map itself: existing tiles stay in place and dim when untouched; planned creates become dashed green tiles with a **New** badge; updates, replacements and removals take amber, pink and red outlines with a word. The footer becomes the review bar (to add / to change / to replace / to remove, **Changes only**, **Discard Preview**, **Review and Apply…**). Pressing Preview Changes stays on the Map instead of jumping to Runs. `MapChangePreview` builds the overlay from `terraform show -json` without reclassifying existing tiles. | Live on a random-provider folder: +2 overlay, New badges, Discard clears. Unit-tested (6 cases). Restored runs from an earlier launch carry no parsed plan, so they do not preview; filed. |
| Agents settings | Agent access is app-wide in Settings › Agents (one switch, what it exposes, status, client connect rows) instead of per-workspace. | Live. |
| Auto-init | A folder with configuration initializes itself on open and before Preview Changes; Settings › General › "Initialize folders automatically". | Live: scratch folder gained `.terraform` and the lock file on open with no prompt. |
| Opening errors | Opening a folder could show "Couldn't read state" because the open-time validation collided with another short command on the same folder (a lease held by the window SwiftUI tears down while restoring). Busy state reads and validations now wait and retry quietly instead of surfacing that error. | Live: reopen is clean where it previously errored every time. |
| Folders from Finder | The app accepts folders from Finder's Open With, the Dock, and `open -a` (`public.folder` document type). A folder has one window; the window carries the folder as its represented file (proxy icon), and a second open brings it forward. | Live via `open -a`. |
| Changes → state (cloud) | Clicking a change card now verified live: banner "State as recorded Jan 13, 2024 at 8:53 PM · revision 2" on terraform-fast, card highlighted, footer updated. The Inspector's History section follows the viewed version instead of always showing the current one. Cards keep their press action for assistive technology (the label-flattening modifiers had removed it). | Live. |
| Tile subtitles | A tile with no recorded anchor (planned, or outside the known schemas) names its resource types instead of repeating the card's count line. | Live: "Port · random_integer · 1 resource". |

Still open from the design: Exploration D's empty-map welcome, ⌘K, and previewing a cloud workspace's speculative plan on the Map.

### Round 5 feedback, October 6, 2026

| Feedback | Change | Verified |
| --- | --- | --- |
| Prompt for folders from outside | A folder handed in by Finder, the Dock or `open -a` no longer initializes itself. The Map shows "Initialize this folder?" with what init does and an **Initialize** button; nothing runs until then. Preview Changes counts as that choice. Folders opened from inside the app still auto-initialize. | Live: no `.terraform` until Initialize was pressed, then init and validate ran. |
| Open… and Open Recent with no window | Both worked only through the focused window, so closing every window left Open disabled and Open Recent empty. They now open a new window when none is in front. | Live: Open Recent listed ten folders with no window open and opened terraform-fast. |
| AllBeadsWeb/terraform | Opened an initialized cloud-backend folder: validate and the remote state read take a while, then the Map says the state is in HCP Terraform. The `allbeads-web` workspace truly has no state version and no runs (checked against the API), so the cloud window's "no managed resources" is accurate. | Checked. |
| Changes strip | Hide/show is per window (`SceneStorage`), and the strip clips and slides as one container instead of the chevron, title and content animating separately. | Live: one window collapsed while another stayed open. |
| Wording | "Checked out from X" became "From X" on Library cards, the window subtitle ("From HCP Terraform · This Mac") and the Map's empty title ("From terraform-fast"). | Live. |

### Round 5 feedback, part two, October 6, 2026

| Feedback | Change | Verified |
| --- | --- | --- |
| "Connect first" while connecting | The cloud window showed the disconnected prompt with a small spinner while a stored credential was still connecting. It now shows the purple loading indicator, "Connecting to HCP Terraform…", and the prompt only when there is nothing to connect with. | Built. |
| "Stuck" workspaces | new-website and the other Needs-attention workspaces have no current state version (their only runs errored before an apply). The Map treated the 404 as "Couldn't read state" and printed `true` where the local window prints a folder path. A workspace with no state version is now an empty Map with "No state recorded yet", the footer notice "HCP Terraform · No state recorded yet", and a History section that says the first applied run creates state. The folder line appears only in local windows. | Live on new-website; 404 confirmed against the API. |
| Changes footer height | The strip takes its content's height up to the old maximum, so one row of cards leaves no empty space. | Live. |
| Latest on the right | With no selection the strip scrolls to its right edge on appear and when runs arrive. | Live on Rookery (24 runs). |
| New-run card | A dotted accent card ends the strip: **Preview Changes** (or **Preview and apply**) in a local window; **New run in HCP Terraform** in the cloud window, which opens the workspace's new-run page since Habitable does not queue remote runs. | Live in both windows; the cloud card's link not clicked. |

## Making changes (Exploration G), October 6, 2026

| Figure | Change | Verified |
| --- | --- | --- |
| Proposal face | The cloud inspector gains a **Proposal** face. With no folder on this Mac it offers Check Out… (repository-backed) or Choose Folder…. API-driven workspaces: folder row, message, **Start Run in HCP Terraform**, then a card with steps Uploaded → Planned → Confirmed → Applied and **Discard** / **Confirm Apply**. Repository-backed: files changed in the checkout, message, **Open Pull Request…** (branch `habitable/<slug>`, commit, push, `gh pr create`), then the PR card (number, branches, state, review decision, +/−) with **View on GitHub**, **Merge…** (`gh pr merge --squash --delete-branch`), **Close Proposal**, and other open pull requests. **Latest runs** lists the four newest remote runs with **Show on Map**, and **Confirm Apply** / **Discard** on a planned one. | Live: face renders for `blank` with the linked folder; the empty Map's **Make a change…** and the strip's dotted card open it. Starting a real run was blocked by this session's permission classifier (it writes to HCP Terraform); the API calls are unit-tested but not yet exercised live. `gh` calls are untested against GitHub. |
| The PR's plan is the preview | A remote run's plan JSON (`/plans/{id}/json-output`) renders on the Map through `MapChangePreview` against the current state; the review bar reads **Discard Run** / **Confirm Apply** with a caption naming the run. Nothing changes until Confirm Apply, which calls HCP's apply action. | Built; awaits a live run. |
| Every apply is remote | `HCPAPIClient` gains configuration-version create and upload (tar.gz of the folder without `.git`, `.terraform`, state files), run create, run fetch, apply and discard; plan downloads follow HCP's redirect to archivist without the token. `GitProposal` wraps git and `gh` with redacted errors. | Unit-tested (HCPProposalTests 4, GitProposalTests 4 incl. a bare-repo fixture). |
| Words | WRITING.md's safety sentence is now "Habitable never applies from your Mac. Runs happen in HCP Terraform; you confirm them here." The disconnected prompt and the Proposal footnote carry it. | Done. |

Not in this round: policy and cost checks on the Map, approvals and conversation from GitHub, hold-to-apply for replace and destroy, and `terraform_data`-style previews for templates.

**Follow-ups, October 9:** Runs no longer show an Apply stage for plan-only runs (HCP's "unreachable"). Library folder cards gain **Remove from Library** (forgets the folder; nothing on disk changes). Local cloud access rows each resolve as their own checks finish instead of all waiting for the slowest, and each CLI command is capped at 10 s; live, AWS, Azure and Google Cloud all reported within the window.

**Walkthrough, October 9:** full suite 381 tests, 0 unexpected failures. Walked Library, the checkout window, the cloud window's four faces, Runs, and Settings › General/Connections/Agents/Terraform in the installed build. Fixed from it: a checkout's Preview Changes ran a local plan although its runs happen in HCP (now **Make a Change in HCP Terraform**, which opens the cloud window on the Proposal face, including when that window is still connecting); "1 managed resources"; the no-selection History sentence spoke of "this resource"; the Settings face now follows the workspace record when it changes under it. Verified: the merge run's source link resolves to `main.tf:14` from the checkout with Open on github.com; the Connecting indicator shows on reconnect; a switch in an inactive window renders grey, which is macOS, not a wrong value. Left as is: the Runs section's "Apply · Unreachable" is HCP's own apply status for plan-only runs; the Library has no way to forget a folder (noted for later); Make a change from a checkout reconnects the cloud window, which takes a few seconds.

**Design pass, October 9:** the Proposal pane was busy. The pull request is now Exploration G's timeline: Pull request opened (branch, +/−, GitHub link) → Plan in HCP Terraform (the recorded run's status and Show on Map; the run outranks GitHub's status context) → Checks (a count with a Details disclosure; "Terraform Cloud/" prefixes dropped) → Review → Merge → Confirm apply, then one action row. The folder row hides once the pull request exists, and the runs list is gone from the face: only runs waiting for a confirmation appear, since the Changes strip is the run list. The collapsed Changes strip now shrinks its content to nothing instead of clipping, so no cards peek under the header.

**Live, October 9:** both paths now verified end to end. API-driven: `blank` uploaded, planned, Confirm Apply applied one `random_pet`, and the Map shows the Habitable Test tile from state. Repository-backed: terraform-fast's checkout had a `terraform fmt` edit; Open Pull Request… created `habitable/format-main-tf-and-record-the-provider-h`, pushed, and opened thrashr888/terraform-fast#2. The card shows GitHub's checks (status rollup: HCP Terraform runs across four workspaces and a Sentinel check), the workspace's own check offers **Show plan on Map**, and the PR's speculative run from Latest runs rendered on the Map as "Print Junk · New", 1 to add, with the caption naming the run. The PR stays open for Paul to merge from the card. Run-list refresh is now one fetch per 8 s; the app's own refreshes wait it out silently and the PR card re-reads GitHub every 20 s.

**Follow-up, October 8:** the first live run on `blank` reached HCP and failed at remote init because the workspace was pinned to Terraform 0.13.1 (no `cloud` block before 1.1). The Proposal card now shows the failed run's log tail (ANSI stripped, wrapped, with Copy) and, for that cause, a hint with **Change Terraform Version…**. A **Settings** face joins the cloud inspector: Terraform version (Latest, the current value, released versions), execution mode, working directory, and "Apply without confirmation"; nothing is sent until Save, HCP's answer replaces the local record, and a link opens the rest in HCP Terraform. Verified built and launched; the save awaits Paul's click.

## Gate for every page handoff

1. Name the relevant exploration/figure and settled decisions in the work notes before implementation.
2. Compare hierarchy, content, interaction and meaning, not only colors or whether code builds. Explain deliberate deviations and their user decision.
3. Exercise the real end-to-end page in the one stable `~/Applications/Habitable Preview.app`. Check normal window size, long labels, search, selection/inspector, error/empty states and relevant local/HCP behavior. Use isolated fixtures for failure tests only; never surface them as product onboarding.
4. Capture and inspect the final running build, compare to the reference, and record concrete remaining mismatches in beads. Do not claim missing behavior works because a screenshot or unit test looks plausible.
5. Report separately: implemented, automated tests, installed build, inspected live, and unresolved design acceptance. Provide the exact user test route and screenshots. Do not call the refresh complete while the gap table still contains unfulfilled required behavior.

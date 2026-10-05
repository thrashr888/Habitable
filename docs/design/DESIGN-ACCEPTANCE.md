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

## Gate for every page handoff

1. Name the relevant exploration/figure and settled decisions in the work notes before implementation.
2. Compare hierarchy, content, interaction and meaning, not only colors or whether code builds. Explain deliberate deviations and their user decision.
3. Exercise the real end-to-end page in the one stable `~/Applications/Habitable Preview.app`. Check normal window size, long labels, search, selection/inspector, error/empty states and relevant local/HCP behavior. Use isolated fixtures for failure tests only; never surface them as product onboarding.
4. Capture and inspect the final running build, compare to the reference, and record concrete remaining mismatches in beads. Do not claim missing behavior works because a screenshot or unit test looks plausible.
5. Report separately: implemented, automated tests, installed build, inspected live, and unresolved design acceptance. Provide the exact user test route and screenshots. Do not call the refresh complete while the gap table still contains unfulfilled required behavior.

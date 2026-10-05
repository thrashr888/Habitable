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

Sources inspected: complete extracted PDF text, rendered Refresh pages 6–7 (Library and Map/Inspector/Timeline), rendered Research page 4 (recommended Map), settled decisions/RFC, current source, and the running stable preview on a real Rookery workspace. Live screenshot: `/tmp/habitable-design-review/current-rookery-map.png`. Screenshots stay local; do not commit private account/state imagery.

| Area | Reference | Current result | Assessment |
| --- | --- | --- | --- |
| Navigation | Refresh p5–7: unified Library and workspace Map, Inspector, Timeline | Legacy sidebar still lists Terraform internals as peers. HCP still has a separate browser. | Not achieved; added Connections does not replace the larger navigation redesign. |
| Map prominence | Refresh p7: resource inventory, compact workspace header, canvas dominant | Workspace filters/picker, Map header, search and notices take roughly the top third of the live content pane before resources start. The optional left column lists workspaces rather than resources/endpoints. | Partial; reduce duplicate workspace chrome and add resource-oriented navigation. |
| Tile meaning | Research p4: recognizable infrastructure things, concise service detail and composition | Many distinct live cards have the identical title Rookery; subtitles and type-count fragments carry the distinction and truncate. | Partial; names need semantic disambiguation, not just title-cased Terraform stems. |
| Grouping correctness | Research p2–4, RFC: facets/helpers belong to the thing they serve | Live 57 managed resources become 17 groups. An autoscaling app group is under Other and includes database/cache subnet helpers; an elastic IP is a standalone Apps tile. | Needs classifier audit with exact resource-accounting tests; do not assume smaller tile count alone is correct. |
| Connections and layout | Research p4: clean within-row flow and neighboring-workspace ports | Fixed-height grid cards and long parallel routes at the canvas edge. Ports show unverified aliases; no Library system graph. | Partial; route readability, provider coverage and verified cross-workspace resolution remain open. |
| Inspector | Refresh p7: human explanation, endpoints, exact detail one step away | Inspector starts with resource membership and attribute detail. | Partial; resource-oriented summaries/endpoints are not yet the reference experience. |
| History and change | Refresh p7–9: Timeline, preview colors/counts and consequences by Apply | Current-state map and separate Runs; no timeline or plan overlay on Map. | Not achieved. |
| Visual foundation | Purple selection, restrained kind colors, compact groups; readable text | Native cards, kind bands, stacks, selection, Map/List, search, real state and context panels exist. Empty sections now hide. | Foundation delivered, not full visual acceptance. |
| Connections | Later user-approved addition | Real local AWS/Azure/Google authentication checks and guarded CLI Connect actions | Functionally testable supporting page; does not prove Map or overall refresh acceptance. |

The next full-page acceptance target remains **Map + Inspector** (Habitable-9gp), supported by classifier/topology work (Habitable-fee) and GitHub/Datadog grouping (Habitable-tuo). Broader Library/Timeline/preview work belongs to the established refresh scope. Do not silently expand a small connection fix into all of those features, or silently mark them done.

## Gate for every page handoff

1. Name the relevant exploration/figure and settled decisions in the work notes before implementation.
2. Compare hierarchy, content, interaction and meaning, not only colors or whether code builds. Explain deliberate deviations and their user decision.
3. Exercise the real end-to-end page in the one stable `~/Applications/Habitable Preview.app`. Check normal window size, long labels, search, selection/inspector, error/empty states and relevant local/HCP behavior. Use isolated fixtures for failure tests only; never surface them as product onboarding.
4. Capture and inspect the final running build, compare to the reference, and record concrete remaining mismatches in beads. Do not claim missing behavior works because a screenshot or unit test looks plausible.
5. Report separately: implemented, automated tests, installed build, inspected live, and unresolved design acceptance. Provide the exact user test route and screenshots. Do not call the refresh complete while the gap table still contains unfulfilled required behavior.

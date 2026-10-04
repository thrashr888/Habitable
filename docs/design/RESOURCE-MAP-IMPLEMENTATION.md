# Resource map foundation

The first native slice implements deterministic map metadata in `ResourceMap.swift`.
It is compiled into both the app and the model test target. Opening a local
workspace now lands on the Map, with searchable kind rows and a group inspector.

## Input and ownership

`ResourceMapStateReader.read` accepts raw Terraform state v4 from local or HCP
workspaces, or `terraform show -json` values. It copies only addresses, types,
names, module paths and raw-state dependencies. It does not retain resource
attribute values or credentials. Deposed objects are excluded from the current
map. Data sources are listed separately and counted by the caller.

Show JSON has no exact dependency graph. Its adapter deliberately returns no
edges. State-loading integration must obtain raw state for helper folding and
connections, and disclose reduced topology when only show JSON is available.

The classifier uses provider documentation categories with type overrides,
explicit facet-parent relationships, and an undirected three-hop helper search.
Equal-distance owners prefer the same module, then lexical address order.
Dependency connections retain their original direction: source depends on target.
Helpers with no owner remain visible in Identity & monitoring; unrecognized
non-helper resources remain visible as Other.

Same-kind, two-word name stems merge only within a module instance. Generic
single-word names do not merge unrelated types. Count and for_each instances
of the same block form a stack. Same-category direct references may merge
anchors within the same module. Stable addresses identify tiles, and all output
collections are sorted. No user corrections or hand-authored grouping is stored.

## Provider table

Run `python3 scripts/generate-map-categories.py` to regenerate the checked-in
Swift table from `docs/design/map-research/sub.json`. The supplied research
snapshot has 3,997 type/category entries. This reproduces the bundled metadata;
it does not fetch newer provider docs. The research `analyze.py` produces the
snapshot from provider docs and the corpus. A standalone upstream refresh tool
and provenance pinning remain follow-up work.

## Validation and remaining scope

`ResourceMapTests` covers provider overrides, exact facet parents, nearest helper
ownership, three-hop limits and cycles, module isolation, semantic grouping,
instance keys, block dependencies, malformed state, duplicate addresses, unknown
resources, data sources, and input-order independence. The 1,000-resource check
is synthetic and is not a production performance guarantee.

Production-state corpus snapshots, listener-mediated merging, region suffixes,
unindexed module dependency expansion, crossing minimization, security expansion,
workspace ports and shared-ID matching are not implemented in this slice.
The existing research corpus contains HCL, not state snapshots, so its published
compression ratios have not been validated against this implementation.

Follow-up tracking: Habitable-nvm (state loading and Map/Inspector), Habitable-fee
(corpus validation and remaining topology rules). Foundation: Habitable-bgl.

## First interactive preview

Run `bash scripts/build-map-preview.sh` to build `/tmp/Habitable Map Preview.app`.
The separately identified, locally signed app starts with an in-memory sample:
10 synthetic resources, 8 groups, 6 kind rows, and no runnable workspace or cloud
connection. It does not replace the installed Habitable. Open a real local folder
with File → Open to leave the sample and use the installed Terraform normally.
The normal app supports `--map-demo` for the same explicit sample.

Try Web Service → Orders in Connections, the masked password in Orders, searching
for uploads, selecting its versioning resource, and List / Full inspector. A
connection selection scrolls the destination tile into view. Connections are
currently listed in the inspector; canvas edge drawing is still pending.

Local refresh runs `show -json` followed by `state pull` under one existing command
lease. It uses the selected backend and workspace, keeps raw state in memory only,
and retains a clearly labeled inventory-only map if dependencies cannot be loaded
or resource identities differ between the two snapshots. Clearing state or changing
workspace clears the map and selection. Direct HCP API workspace maps are implemented in the follow-up below.

Validation: 233 model tests executed, 8 optional tests skipped, zero failures;
native Debug build passed. Live UI verified sample selection, dependency navigation,
search, List, masked password, and switching from sample to the provider-free
playground (26 managed resources plus one data source). Empty/malformed behavior is
covered by model tests; the complete live fixture matrix remains unverified.

## HCP Map and Inspector

The HCP workspace viewer now defaults to Map, with Runs available in a segmented
control. It fetches the current immutable state version and downloads its raw and
stable JSON artifacts. Raw state supplies dependencies; stable JSON supplies the
sensitivity masks. Resource inventories must agree before combining them. If an
older version has no stable JSON artifact, topology remains available with no raw
attribute values exposed. Each artifact is limited to 32 MiB and kept in memory;
only redacted display strings enter the shared inspector presentation.

Signed storage downloads receive no API bearer token. Terraform Enterprise's
same-origin `/api/state-versions/` downloads may receive the token, with the existing
redirect policy still enforced. No write API or local Terraform execution is used
by the HCP Map. Missing state and missing state permissions are presented as
unavailable state rather than an empty workspace. Workspace/host/organization
changes and disconnects invalidate map requests; late responses are discarded.

HCP Terraform → Explore a sample cloud map opens a separate offline viewer with
populated, empty, and unavailable-state workspaces. It does not read credentials,
make network requests, or persist account selections. List and Full inspector
use the same already-redacted resource records as the map.

Validation: 242 model tests executed, 8 optional skips, zero failures. The native
Debug app and packaged preview build successfully. Request tests cover signed
artifact authentication boundaries, Enterprise authentication, nested/repeated
secret redaction, malformed/mismatched artifacts, size limits, late responses,
disconnect, missing state/access, metadata-only empty state, and offline isolation.

Live checks passed for the cloud sample's tile selection, dependencies, redaction,
empty workspace switching, and unavailable-state message; local output-only,
empty, and malformed-state Maps also behaved correctly. The expanded cloud
inspector initially failed to update its selected resource. It now owns its
selection in a dedicated sheet and compiles, but the computer-control connection
failed before the final click-through could be repeated. That verification and a
real-account HCP smoke test remain outstanding under Habitable-q7i. No real HCP
state was accessed during this implementation.

API contract: https://developer.hashicorp.com/terraform/cloud-docs/api-docs/state-versions

## Selected-group canvas connections

Selecting a group now draws arrows to its visible dependencies and dashed arrows
from groups that use it. Arrowheads point to the dependency. Connections follow
the space above grid rows and a reserved left gutter; native card controls retain
keyboard navigation and the inspector remains the complete accessible connection
list. Search omits edges to filtered groups. Lazy-grid tiles without layout anchors
are omitted from drawing until laid out. Workspace changes clear selection.

Validation: 12 Map regression tests pass; the native Debug build, preview packaging,
and signature verification pass. Latest pre-change CI also passed. Native app
automation timed out on both the prior and new preview, so visual verification
of arrows at different widths, scrolling, and search remains under Habitable-cbk.
This first renderer shares routes for dense graphs; crossing minimization remains
part of Habitable-fee.

## Map page review, October 4

Live native automation recovered. Verified selected outgoing and incoming arrows,
scrolling, narrow and maximized layouts, dependency navigation, search and clearing
search. Filtering out a selected tile now clears its inspector, filtered counts
show matching versus total groups, and no-results offers a Clear search action.
Unavailable state no longer claims to be an empty current state. A new local
folder without state is labeled No recorded state.

The cloud sample's expanded inspector correctly preselects the requested resource
and updates its visible heading and attributes when another resource is selected.
Populated-to-empty and unavailable cloud sample switching clear prior selection.
Local malformed, empty, output-only, and populated provider-free playground states
were exercised in the native app. The playground loaded 26 managed resources in
19 groups plus one data source. Narrow and wide screenshots were inspected.

All 242 model tests pass (8 optional skips). Native Debug builds and signed preview
verification pass. Preview builds may set HABITABLE_PREVIEW_BUNDLE_ID to keep app
identity separate from older running previews. The Map review uses
com.thrashr888.Habitable.map-review at /tmp/Habitable Map Page.app.

Real-account HCP smoke testing still awaits a chosen workspace (Habitable-q7i).
Production corpus/topology refinements remain Habitable-fee. Lazy-grid connections
are drawn for laid-out endpoints; the inspector lists all dependencies, including
offscreen groups. Dense routes may overlap in the gutter.

The final No recorded state label was verified in the rebuilt app. The existing
HCP connection subsequently listed workspaces successfully, but its restored
workspace returned the fixed Map-loading error. Diagnosis requires private state
inspection and is awaiting explicit workspace approval; automatic approval review
blocked the proposed diagnostic request. No diagnostic state payload was retrieved.
This replaces the earlier assumption that only a routine HCP smoke test remained.

## HCP live-loading fix

With explicit user approval, read-only diagnosis found that both state download
endpoints return HTTP 302 to archivist.terraform.io. The ordinary API redirect
policy correctly refused to forward a credential across origins, but that policy
also prevented the Map from downloading the artifacts.

State downloads from app.terraform.io now use a dedicated per-task redirect
policy, restricted to GET requests from /api/state-versions/ and the exact
archivist.terraform.io HTTPS/443 destination without URL userinfo. A fresh GET
request preserves the artifact URL but carries no original headers, cookies, or
body. Ordinary API redirects and Enterprise behavior remain unchanged.

The approved real workspace now loads 17 groups and 57 managed resources in the
native preview. Refresh and resource-card selection also passed. No infrastructure
changes were made and private state values were not written to diagnostic logs.
The prior HCP loading blocker is resolved. Other regions and Enterprise remain
unverified live. Latest preview: /tmp/Habitable Map Cloud Review.app, isolated
bundle ID com.thrashr888.Habitable.map-cloud-review.

Final validation: 246 model tests executed, 8 optional skips, zero failures;
native Debug and signed preview builds pass.

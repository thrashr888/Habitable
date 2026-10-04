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
workspace clears the map and selection. Direct HCP API workspace maps remain pending.

Validation: 233 model tests executed, 8 optional tests skipped, zero failures;
native Debug build passed. Live UI verified sample selection, dependency navigation,
search, List, masked password, and switching from sample to the provider-free
playground (26 managed resources plus one data source). Empty/malformed behavior is
covered by model tests; the complete live fixture matrix remains unverified.

# Resource map foundation

The first native slice implements deterministic map metadata in `ResourceMap.swift`.
It is compiled into both the app and the model test target; the current UI does not
call it yet.

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

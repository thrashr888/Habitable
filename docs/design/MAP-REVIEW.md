# Map page review

Open `/tmp/Habitable Map Cloud Review.app`. It starts with offline sample infrastructure.
No cloud credentials are needed for these checks.

| Check | Expected behavior |
| --- | --- |
| Select Web Service | Purple selection, two grouped resources, links to Orders, Public Entry, Uploads, and Main. |
| Follow Orders | Selection and details move to Orders; password stays masked. Dashed arrows point from its users; solid arrows point to its dependencies. |
| Resize and scroll | Cards reflow; inspector remains usable; lines stay outside card bodies. Offscreen dependencies remain accessible through inspector links. |
| Search uploads | One of eight groups; a previously selected hidden group clears from the inspector. |
| Search nonsense, then Clear search | Explicit no-results message, then all eight groups return. |
| Select Uploads and its versioning member | Both resource addresses remain accessible within the group. |
| HCP Terraform → Explore a sample cloud map | Same Map behavior in an offline cloud viewer. |
| Cloud sample → Orders → Full inspector | Orders is preselected; choosing the bucket updates heading and attributes. |
| Switch cloud sample to Empty, then Unavailable | No stale resources or selection; empty and inaccessible states have different messages. |

For local state checks, use File → Open on the folders under
`/tmp/Habitable Map Checks`: Empty, Outputs only, and Malformed. The populated
`/tmp/Habitable Map Playground` has 26 managed resources plus one data source.
Opening these fixtures only reads their existing state; no apply is needed.

Real-account HCP loading, refresh, and card selection passed on the approved workspace (17 groups, 57 managed resources). Its download redirect bug is fixed: the authenticated HCP state endpoint can redirect only to Archivist over HTTPS, with no credentials, cookies, or request body forwarded. Other HCP regions and Enterprise deployments have not been live-tested.
Broader provider-state grouping and dense-graph route improvements remain tracked
separately. This review build is not a release.

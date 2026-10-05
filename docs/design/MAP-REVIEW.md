# Map page review

Start with [Design acceptance](DESIGN-ACCEPTANCE.md), [settled decisions](DECISIONS.md), Refresh exploration B, and Map Research exploration B. Use the latest **~/Applications/Habitable Preview.app**. There is one installed preview; do not create or launch older temporary bundles. Product validation uses the user's actual local/HCP workspaces, not sample cloud maps.

| Check | Expected behavior |
| --- | --- |
| Open an authorized real HCP workspace | Its current state loads; workspace identity and totals agree; no stale previous workspace data. |
| Inspect Map at 100% in normal window | Readable labels, no unnecessary empty bands, compact chrome, understandable distinct titles. Compare the actual screenshot with the reference. |
| Select a group and its members | Every underlying address stays reachable; inspector follows selection and sensitive values stay masked. |
| Follow dependencies | Edges and inspector links agree with state, preserve dependency direction, and remain readable without crossing labels. |
| Search one group, search no matches, clear | Newly empty sections disappear, whole-map no-results message appears when appropriate, clearing restores groups. |
| Toggle Workspaces and Variables | Canvas remains usable; selecting a tile shows inspector, closing it restores context without clipping. |
| Switch workspace and refresh | No previous workspace resources, inputs, selections or errors remain. |
| Compare grouping | Recognizable services rather than ambiguous stems; helpers belong to the correct owner; every managed resource is accounted for exactly. |
| Inspect references | Unverified aliases are labeled honestly; no fabricated neighboring-workspace destination. |
| Review missing design behavior | Library, resource inventory, semantic inspector/endpoints, Timeline, Preview Changes, Flow/security views remain explicit gaps until implemented and inspected. |

Use [the detailed evidence log](../MAP-REVIEW-2026-10-04.md) for past tests and limitations. Old entries are historical evidence, not current completion claims. Readability fixes and successful builds do not close visual acceptance (Habitable-9gp). Classifier/topology issues remain in Habitable-fee; GitHub/Datadog grouping in Habitable-tuo.

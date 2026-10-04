# RFC: Resource Map Classification

Oct 4, 2026 · Paul Thrasher · Source: [Claude Doc](https://claude.ai/code/artifact/93d905df-144f-4ff7-8cf5-b821e8a4d9df)

## Summary

Habitable will draw each workspace as a map of a few named tiles instead of a list of resource blocks. Each tile's kind comes from its resource type, looked up in the provider's own docs categories. Which resources make up a tile comes from references and shared name stems. Tile order comes from references, and neighbouring workspaces come from `tfe_outputs` and remote state.

On real production configs this turns a median workspace of 25 resources into 4 tiles, and it accounts for every resource it doesn't draw. The [research page](https://claude.ai/artifact/Q79RepVbNcKD6GKhXcxJVV) has the full evidence and five map explorations.

## Background

The October 2026 design refresh made resources the main subject of Habitable: "manage infrastructure, not code." It replaces ten sidebar pages with a Library, a Map, an Inspector and a Timeline, and the Map is the default view for every workspace ([design explorations](https://claude.ai/artifact/8jwxxWFhYociwhNtjFanZe)).

The explorations drew the map with hand-picked groups such as Edge, Compute, Data and Network. Real state carries no such labels. It has resource addresses, types, attribute values and dependencies, and its names are whatever the author chose. This RFC answers whether those signals are enough to draw a useful map automatically, and how.

## Research

The signals hold up: resource types classify 95% of cloud resources, and references plus name stems fold a typical workspace down to a handful of tiles. The corpus is 3,449 resources in 10 repos, 63 of them root modules with 10 or more resources. Most come from production infrastructure: [GOV.UK](https://github.com/alphagov/govuk-infrastructure), Canada's [GC Notify](https://github.com/cds-snc/notification-terraform) and [GC Forms](https://github.com/cds-snc/forms-terraform), and the [UK Ministry of Justice cloud platform](https://github.com/ministryofjustice/cloud-platform-infrastructure). HashiCorp, Google and Azure reference configs fill out the rest.

| Finding | Measure | What it means for the map |
| --- | --- | --- |
| Provider docs give every resource type a category | 95% of AWS, Google and Azure resources; 255, 178 and 111 categories | Kind can come from the type alone |
| Plumbing dominates | 43% are IAM, CloudWatch, logs, secrets or keys | Helpers must fold into what they serve |
| Facets of a parent resource | 22%, such as `aws_s3_bucket_versioning` or `aws_iam_role_policy_attachment` | They become details on the parent's tile |
| Shared name stems across types | 56% share a two-word stem with another type | Names identify which thing, not which kind |
| Generic names | 3% use `this`, `main` or `default` | Production roots name things well; modules do not |
| count / for\_each | 33% of blocks | Copies become stacks |
| Shallow dependency graphs | 91% within three reference hops | Rows and flows stay short |
| Cross-workspace links | 18 of 133 folders use `tfe_outputs` or remote state | Neighbours can be drawn as ports |
| Files outside main.tf | 90% | File names are a usable fallback label |

A prototype classifier of about 150 lines runs over raw `.tf` files. It turns GOV.UK Chat's 36 resources into 6 tiles with 4 resources left on a shelf. It turns GOV.UK's 155-resource publishing workspace into 13 tiles, 3 of which were split wrongly; those 3 are covered under Proposal. Across the corpus the median root goes from 25 resources to 4 tiles, the 90th percentile is 14 tiles, and 6 of 63 roots produce no tiles because they hold only IAM, secrets or alarms. Scripts are in [map-research/](map-research/).

## Proposal

The map is built in six steps from data Habitable already loads.

1. **Classify each resource by kind.** Look up the resource type in a bundled table of provider docs categories and map the category to one of six kinds. About 20 type-pattern overrides handle cases the docs categories get wrong, mainly Google's "Compute Engine", which also holds networks, firewalls and load balancers.
2. **Fold facets into their parent.** A resource whose type starts with another present type and references it (`aws_s3_bucket_versioning` → `aws_s3_bucket`) becomes a detail of that parent.
3. **Fold helpers into what they serve.** IAM roles and policies, security groups and rules, log groups, parameter and subnet groups, DNS records and alarms attach to the nearest non-helper resource within three reference hops.
4. **Merge into tiles.** Resources that remain merge when they share a two-word name stem (`chat_redis_cluster`) or reference each other within the same docs category, so the parts of one API Gateway become one tile. Region and zone suffixes (`_dublin`, `_london`, `_a`, `_b`) and count/for\_each become a stack with a count.
5. **Place the rest.** Helpers with no owner go to the Identity & monitoring row. Data sources are hidden and counted. Every resource is in a tile, in the Identity & monitoring row, or in the data sources count.
6. **Place and connect.** Tiles go into kind rows and are ordered within a row to minimize crossing references. `tfe_outputs` and `terraform_remote_state` reads become ports to neighbouring workspaces.

| Kind | Typical docs categories | Row |
| --- | --- | --- |
| Front door | Route 53, CloudFront, ELB, API Gateway, WAF, ACM, Cloud DNS, Front Door | 1 (top) |
| Apps & AI | EC2, ECS, EKS, Lambda, App Runner, Bedrock, Cloud Run, App Service, plus all Kubernetes and Helm resources | 2 |
| Messaging & events | SQS, SNS, EventBridge, Kinesis, SES, Pub/Sub | 3 |
| Data | RDS, DynamoDB, S3, ElastiCache, OpenSearch, BigQuery, Cloud SQL, CosmosDB | 4 |
| Network | VPC, Transit Gateway, VPN, Network Firewall, Google VPC networks | 5 |
| Identity & monitoring | IAM, KMS, Secrets Manager, SSM, CloudWatch, Logging | 6 (bottom) |

**Naming.** A tile's title comes from its name stem (`chat_redis_cluster` → "Chat Redis"). Its subtitle is the docs category and resource type. A module name labels a group when one exists, and the file name is the fallback.

**Fixes found at scale.** On the publishing workspace, target groups stayed apart from their load balancer because they connect only through a listener. WAF logging also stayed apart from its firewall. Folding through listeners and logging configurations fixes both and takes that map from 13 tiles to 10.

**State is the only source of truth.** The map is derived entirely from Terraform state, from HCP Terraform for cloud workspaces and from the local state file otherwise. Habitable keeps no hand-made groupings or tile names of its own. A resource that lands in the wrong tile is a classifier bug, fixed in the kind table or the folding rules and shipped to everyone. The only things saved locally are view preferences such as layout choice and zoom.

## Map layouts

Kind rows are the default. The app picks another layout only when the workspace's shape calls for it, and people can switch at any time.

| Layout | Used when | Real example |
| --- | --- | --- |
| Kind rows (default) | Any workspace with at least one tile | GOV.UK Chat: 36 resources → 6 tiles, with no front door or network of its own; ports point to root-dns, cluster and vpc |
| Flow, left to right | Most tiles are messaging or functions in a chain three or more deep | GOV.UK Chat's alerting: health events → SNS topics → Slack channel |
| List | The workspace produces no tiles, or the person prefers it | 6 of 63 corpus roots are pure IAM, secrets or alarms |
| System map (Library) | An organization or folder holds linked workspaces | GOV.UK's 35 workspaces, layered from vpc up through cluster-infrastructure to apps |

Empty rows collapse into a single line that names where that part of the system lives, for example "Chat's public entry points live in other workspaces." Identity & monitoring is a real row at the bottom of every map. Helpers already folded into a tile stay inside it, and the row shows the rest. A security-focused view expands the row to show every IAM, KMS, secrets and logging resource, grouped by the tile that uses it. That keeps the 43% of resources that are plumbing reachable without crowding the rows above.

## Implementation

The classifier runs in the app on structured data, not regex over HCL. Every input below is already loaded or a single API call away.

| Input | Source in the app | Used for |
| --- | --- | --- |
| Resource instances, types, names, module paths | HCP Terraform state version JSON, or `terraform show -json` on a local folder | Everything |
| Exact dependencies | Each state instance's `dependencies` field, across modules | Folding, merging, ordering |
| Config references and file:line | Plan JSON `configuration`, and the existing config inspector helper | Workspaces with no state yet, file labels, "Defined in" |
| Kind table | Generated at build time from provider docs `subcategory` frontmatter and shipped as JSON | Classification |
| Neighbours | Shared resource IDs across states, plus `terraform_remote_state` and `tfe_outputs` reads | Ports and the system map |
| View preferences | Local, per workspace | Layout choice and zoom only |

**Finding neighbours.** HCP Terraform workspace links are not widely used, so the system map can't depend on them. Habitable reads every state it can reach, HCP Terraform workspaces and local folders alike, and links two workspaces when an ID created in one appears as an attribute in another. For example, a `vpc-0abc` created by the vpc workspace and used in a subnet in the app workspace links the two. `terraform_remote_state` and `tfe_outputs` reads confirm a link when present. Matching on a resource's ID and ARN rather than on free text keeps false links rare; this needs testing on real multi-workspace states.

**Kind table.** A build script reads `website/docs/r/*` in the AWS, Google and Azure provider repos and emits a type → category map of about 4,000 entries, plus the category → kind table and overrides. Providers not in the table fall back to keywords in the type name (`_db_`, `_bucket`, `_queue`, `_lb`), then to Other. The table is refreshed with each app release.

**Performance.** Classification is linear in resources and references. A 1,000-resource state should classify in well under 100 ms on device; this is an estimate to confirm with a benchmark. Layout reuses the last arrangement so tiles don't jump when state refreshes.

**Determinism.** The same state always produces the same map. Tests snapshot the tile output for the corpus roots, so a classifier change shows up as a reviewable diff.

## Abandoned ideas

- **Kind from name prefixes.** Names rarely say "edge" or "data". The most common name tokens are app parts such as `notification`, `api`, `sms`, `admin` and `celery`. Prefixes are kept for merging resources into tiles instead.
- **One tile per resource.** GOV.UK Chat drew 36 tiles, and 22 of them were IAM, security groups, log groups or alarms. The thing a person would name first, the Redis cluster, was one chip among five.
- **Grouping by file.** Files usually group by service (iam.tf, secrets.tf, cloudwatch\_alarms.tf), which scatters a single feature across several groups. They remain a fallback label.
- **Flow layout as the default.** It reads well for pipelines, but 16% of resources reference nothing in their folder, so data-heavy and network workspaces collapse into a single column.
- **Tags.** 240 files set tags, but keys and values vary too much between teams to drive layout. Tags remain filters.

## Decisions

Decided by Paul on October 4, 2026.

- **Identity & monitoring is a row,** not only a shelf, and a security-focused view expands it.
- **Kubernetes and Helm resources are Apps & AI.**
- **The system map uses local copies of state as well as HCP Terraform,** linking workspaces by shared resource IDs because workspace links are not widely used.
- **No corrections layer.** Terraform state in HCP Terraform is the source of truth, and the map is always derived from it.

## Milestones

1. Port the classifier to Swift over state JSON, with snapshot tests on the corpus roots.
2. Build the kind table generator and ship the first table with the app.
3. Draw kind rows, including Identity & monitoring, and ports in the Map view.
4. Add the security-focused view and the flow layout.
5. Build the Library system map from shared IDs across local and HCP Terraform states.

## Sources

- [Habitable Map Research](https://claude.ai/artifact/Q79RepVbNcKD6GKhXcxJVV): evidence and five map explorations
- [Habitable Design Refresh](https://claude.ai/artifact/8jwxxWFhYociwhNtjFanZe): the redesign this RFC serves
- [hashicorp/terraform-provider-aws](https://github.com/hashicorp/terraform-provider-aws), [terraform-provider-google](https://github.com/hashicorp/terraform-provider-google), [terraform-provider-azurerm](https://github.com/hashicorp/terraform-provider-azurerm): docs subcategories
- [map-research/](map-research/) scripts and [map-research.html](map-research.html)

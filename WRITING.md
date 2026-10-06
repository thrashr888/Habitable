# Habitable — WRITING.md

Source of truth for words a person reads in Habitable: in-app copy, menus,
help text, errors, release notes, README and docs. `DESIGN.md` governs how
the app looks; this file governs how it talks.

## The voice

Habitable speaks like a careful operator explaining your infrastructure to
you. Plain, specific, calm. It names the thing (`Orders database`,
`rookeryhq.com`) before the Terraform address, and it never claims more than
state or a run actually recorded.

## Register by surface

| Surface | Register | Example |
| --- | --- | --- |
| Window titles, tile titles | The thing's name, nothing else | `Rookery` · `rookeryhq.com · DNS` |
| Subtitles, status lines | Fragments joined by middle dots | `pthrasher_v2 · HCP Terraform` · `Applied · 5 months ago` |
| Toolbar and menu verbs | Verb + object, title case in menus | **Preview Changes**, Open in HCP Terraform, Initialize Terraform |
| Inspector facts | Label left, value right, no sentences | `Engine · postgres`, `Backup retention · 7 days` |
| Empty states | One plain sentence, then the action | "No changes recorded yet. Preview Changes starts the first one." |
| Help text and hints | One clipped line saying what the control does | "Map shows resources grouped by what they do. List is the complete table." |
| Errors | What failed in user terms, then one concrete fix | "Couldn't read state for terraform. Refresh after resolving the state error." |
| Consequences | Counts first, then the one thing that can hurt you | `1 to replace` · "Orders database will be replaced. Its data is deleted once the new one is up." |
| Release notes | Bold benefit, then the evidence | "**Runs read like runs.** Plan logs parse into counts and diagnostics; nothing under 12pt." |

## Vocabulary

| Say | Not |
| --- | --- |
| Preview Changes | Plan |
| Apply | Confirm and apply |
| Remove, destroy (counts: `to remove`) | Delete and destroy in the same sentence |
| Inputs | Variables (local Terraform inputs); HCP keeps "Variables" because that is HCP's word |
| Changes | Runs (the local history strip); the HCP section stays "Runs" |
| tiles (`15 tiles`) | groups, rows: a tile is one thing on the Map; a band is a row of tiles of one kind |
| Workspace settings | Settings (when scoped to one folder) |
| Connections | HCP Terraform / cloud sign-in settings |
| This Mac | local, locally |
| HCP Terraform state / Local state | backend identity strings |
| Recorded in Terraform state | healthy, in sync, live |
| data sources read during the plan | reads, data reads |
| Hidden / Sensitive value hidden | redacted, masked |

Terraform's own nouns (workspace, state, backend, provider, module, plan,
apply, run) stay as Terraform spells them when the user will see the same
word in Terraform's output. Never rename `terraform init` in a sentence that
tells someone to run it.

Banned: "seamless", "powerful", "leverage", "supercharge", "delve",
exclamation points, "honestly", drift or health adjectives that state did
not record.

## Mechanics

- Sentences in paragraphs; fragments only in micro-copy and tables.
- At most one em dash per paragraph and none in micro-copy; prefer a period
  or a middle dot.
- Numbers belong in their own column, chip or count line, not in prose.
- Dates are relative in lists (`5 months ago`) and absolute in facts
  (`Apr 25, 2026 at 9:06 PM`).
- Status is a dot plus a word; the word is Terraform's status in sentence
  case with underscores removed (`Planned and finished`).
- Safety sentences repeat verbatim wherever they apply: "Nothing changes
  until you apply." · "Workspace variables are updated only when you choose
  Save." · "Habitable does not queue or apply remote runs."
- Title case for menu items and toolbar verbs; sentence case for everything
  else. An ellipsis on any item that asks for more before acting.

## Claims

Every statement about infrastructure comes from state, a recorded run, or
an API response, and says which. "State recorded Apr 25" is a fact;
"healthy" is not. When something is unavailable, say so and say why in one
line ("File and line are unavailable in remote Terraform state."). Report a
failure as plainly as a success.

## The tell check

Before shipping copy, scan for: em-dash pivots, three-item rhythms, the same
sentence template on parallel rows, winking at the reader, internal names
(classifier, snapshot, selector, resolver) on a user surface, and encoding
artifacts (`â`, `Ã`). If a sentence could open a LinkedIn post, rewrite it.

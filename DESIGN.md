# Habitable — DESIGN.md

How Habitable looks and behaves. Native macOS app (SwiftUI + AppKit, macOS 27
"Golden Gate" minimum). Agents and people treat this file as the source of
truth for visual and interaction decisions; `docs/design/DECISIONS.md` records
*why* Paul decided them and `docs/design/DESIGN-ACCEPTANCE.md` records how the
running app compares to the mocks. The companion `WRITING.md` governs words.

## 1. Atmosphere

Manage infrastructure, not code. Resources are the subject; files, runs and
CLI flags are supporting detail. The references are GarageBand and iMovie for
layout and Linear, Finder and Apple's own apps for restraint. The quality bar
is an Apple Design Award.

The grammar in one paragraph: everything sits on one sheet. Regions separate
by hairlines and spacing, never tonal fills. Color appears only when it means
something: resource kind on an icon, change semantics on an outline, status
on a dot. Text carries hierarchy, not boxes. Motion is short (≤250 ms) and
never springy. System appearance, text size and reduced motion are law.

## 2. The window formula

Every Habitable window is **one toolbar, side panes, an uncontained center,
and a strip along the bottom** (Exploration B in `docs/design/design-explorations.html`).

- **Toolbar is the title bar.** Native title and subtitle name the subject
  (`terraform` / `acme-platform · HCP Terraform state · This Mac`; `acme-platform` /
  `acme · HCP Terraform`). The view switcher (Map | List, Map | Runs)
  is a segmented control at navigation size. Primary verbs sit trailing:
  **Preview Changes** is prominent; Inputs, Changes, Workspace, the cross
  window links and Settings follow. Toolbar groups hide the shared glass
  background (`QuietToolbar`); items read as flat native controls.
- **Panes are flush.** The inventory (left) and Inspector (right) have no
  radius and no card; one hairline separates each from the center. The
  inventory slides (0.22 s) rather than snapping; the Inspector appears when
  something is selected.
- **The center is the paper.** The Map canvas, or a secondary page opened in
  place with a **Map** back control. Nothing wraps the center in a card.
- **The bottom strip is provenance.** Status chips (`57 resources · 15 groups
  · 13 data sources`) and the Timeline of recorded changes. The Timeline
  shows what Terraform recorded; it never simulates past state.

Windows: local workspace (`Workspace.viewer`), HCP Terraform (`HCP.browser`),
Settings/Connections (`App.settings`). They link to each other only through
verified identities (an initialized or declared backend; never a folder name).

## 3. Color

- **Accent** is Terraform purple: `#7B42BC` light, `#A067DA` dark
  (`AccentColor` asset). Selection outlines, selected clips, emphasized
  connections, links. Never system blue.
- **Change semantics** are fixed and never reused for anything else:
  create green, change amber/orange, replace pink, remove red. Destructive
  actions never use violet.
- **Resource kind color** lives only in the 24pt icon tile and the
  inventory glyph: front door teal, apps & AI orange, code mint, messaging
  pink, data cyan, network blue, identity & monitoring and other secondary.
  Kind color and change color never share a surface: a tile's outline and
  chips speak change, its icon speaks kind.
- **Status** is a dot plus a word, never a dot alone: applied green,
  errored red, active orange, everything else secondary.
- Text colors are `primary` and `secondary` only. `tertiary` is reserved
  for disabled affordances; dates, notices and IDs are secondary.
- Surfaces come from system materials (`windowBackgroundColor`,
  `controlBackgroundColor`, `underPageBackgroundColor`). Hairlines are
  `Color.primary.opacity(0.09–0.12)`; selected rows wash `accent.opacity(0.15)`.

## 4. Type

System font (SF Pro) via `.system(size:)` so Dynamic Type and the system
text size apply. No webfonts, no custom families.

| Role | Size / weight | Where |
| --- | --- | --- |
| Page title | 22 / semibold | Settings page headings, empty-state heroes |
| Card title | 15 / semibold | Map tiles, run detail headline |
| Timeline clip title | 14 / semibold | Changes strip |
| Body, rows, controls | 13 / regular (medium for selected) | Inventory rows, lists, tables, chips, band labels, subtitles |
| Caption | 12 / regular | Tile subtitles, metadata, help text, run IDs |
| Count badge | 12 / semibold tabular | Inventory counts, chips |

**12pt is the floor.** `.caption` and `.caption2` render at 10pt on macOS and
are banned in app views; `.callout` is 12pt and is used only where a caption
is intended. Monospace (`design: .monospaced`) for Terraform addresses,
values, keys and IDs, same sizes as the prose beside them.

## 5. Components

- **Map tile**: 264×120 at 100%, radius 13, system control background, a
  hairline, a 2pt accent outline when selected. 24pt kind icon tile, 15pt
  title, 13pt service subtitle, 12pt count. Duplicate names take their state
  identity (zone, certificate domain, bucket) before a service qualifier.
- **Bands**: one per populated kind, in request order (front door → identity
  & monitoring). Empty bands are omitted, including under search. Label 13pt
  semibold uppercase secondary.
- **Connections**: orthogonal, rounded (radius 12), hairline secondary;
  accent and 1.8pt when they touch the selection; arrowheads only on
  directed dependencies; reciprocal group edges draw once without a head.
- **Inventory**: 224pt pane. Endpoints first (accent, arrow glyph), then one
  block per kind with 13pt rows and a 12pt tabular count; selected row washed
  in accent 0.17.
- **Inspector**: facts first (At a glance), then endpoints, connections,
  Defined in, History. Copy buttons on every fact. Never a guessed fact.
- **Status chips**: capsule, 13pt, count semibold tabular, label regular,
  hairline border. Only recorded facts; no sync or drift claims.
- **Timeline strip**: 142pt tall. Header `Changes` + `N applied since <date>`,
  trailing hint, `All changes` link. Cards 92–150pt wide, radius 10, 14pt
  title, 13pt counts colored by change semantics or the recorded status.
  Every card carries its day label (repeats dimmed to 0.7).
- **Tables** (Inputs, Variables, List): pinned 12pt uppercase header row,
  13pt mono keys with a 12pt description beneath, single-line middle
  truncated values, chips for provenance/category, trailing borderless
  actions, 44pt minimum rows, alternate rows at primary 0.025, hairlines.
- **Run detail**: 15pt headline, status line, consequences row (title2
  tabular numbers over 12pt labels, colored by change semantics), planned
  changes with action capsules, apply activity, diagnostics as tinted
  callouts, raw logs collapsed. Data-source reads collapse when a plan has
  no real changes.
- **Secondary pages** (Overview, About, Source files, Outputs, Environment,
  Workspace settings) open in place with a bordered **Map** back control and
  a 13pt page title; they keep their own content layout.
- **Buttons**: bordered for in-content actions, borderless for row and copy
  actions, `.borderedProminent` only for the one primary verb in a window
  (Preview Changes, Save, Connect).
- **Masked values** always render the same placeholder with a lock glyph
  and never prefill an editor; presentation masking does not change a
  server-side sensitivity flag.

## 6. Layout

8pt grid, 4pt half steps. Panes 16pt horizontal padding; headers 8pt
vertical. Minimum window 900×560 (settings 660×560); default cloud window
1400×880. Everything must survive the minimum width with the inventory and
Inspector open: the canvas scrolls, text truncates in the middle, nothing
shrinks below the type floor to fit.

## 7. Behavior — the Mac formula

The system is law, the menu is the index, the keyboard is complete, undo
beats confirm, objects are direct, state survives.

- Every command in the toolbar also lives in the menu bar with its shortcut
  (⌘⇧P Preview Changes, ⌘⇧I Initialize, ⌘⇧V Validate, ⌘, Settings, ⌘[ back
  to Map, ⌃⌘S inventory, ⌘= ⌘- ⌘0 zoom).
- Terraform commands are scoped to the focused local window and disabled
  elsewhere.
- Replace and destroy need an explicit hold-to-apply; additive previews
  apply on a click. Automatic apply is unmistakable wherever a plan starts.
- Right-click an object for its actions; copy anything shown.
- Window sizes, pane visibility, zoom and selection restore on relaunch.

## 8. Truthfulness

State is authoritative. The app never infers health, drift, capacity from an
instance class, runtime relationships, remote source file and line, or
per-resource history from data it does not have. A misplaced tile is a
classifier bug, not something for the user to drag into place. Fixtures are
for tests; product flows use the user's real infrastructure.

## 9. Do and don't

Do: use system materials and semantic colors; keep 12pt as the floor; show
status as dot + word; put one primary verb per window; compare the running
app to the mock before calling a page done.

Don't: glass capsules in toolbars; text under 12pt or tertiary text for
information; tonal fills to separate regions; decorative color; a second
title for the subject the window already names; a sidebar of Terraform
internals; invented numbers or states.

# Information architecture

An outline of every place a person can be in Habitable today, what is confusing about it, and a proposal to make it "don't make me think" clear. Companion to DESIGN.md and DECISIONS.md.

## Where you can be today

**1. Library** (a workspace window with no folder). One window, ⌘⇧L.
- Sidebar: All infrastructure, Recent, Needs attention, This Mac, then one row per HCP Terraform organization.
- Content: cloud workspaces and local folders as cards, filter, sort.
- Footer: New… (⌘⇧N), Open Folder… (⌘O).
- New Infrastructure chooser (sheet): Open (folder, HCP workspace), templates by category, modules from the Registry.

**2. Folder window** (a workspace window with a folder open). One window per folder.
- Title: folder name · "Local state · This Mac", or "From <workspace>" for a checkout.
- Title bar: Map | List, Preview Changes, Inputs, Changes, Quick Help, info menu, Library, HCP Terraform, Settings.
- Map, with the inspector on the right (Inspector | Inputs) and the Changes strip below.
- States: Declared not built (welcome), reading, no state, map, preview review (Everything | Changes), error.
- Checkouts route Preview Changes to the cloud Proposal.
- Inputs, Outputs, Configuration, README, Terraform settings live behind the info menu and inspector.

**3. HCP Terraform window.** One window for all organizations and workspaces.
- Left: organization picker, workspace list with status, project, tags, filter.
- Workspace header: name, status, repository, project, Terraform version, run mode, tags; links to Map, Variables, Settings, Make a change.
- Sections: Map | List | Runs | Variables.
- Faces in the inspector: Proposal (make a change: edit, PR, plan, checks, merge, confirm apply), Settings (workspace settings), run detail.
- Title bar: Local Folder, Connections, Quick Help.

**4. Settings window.** General, Connections, Agents, Terraform, About.

**5. Flows that cross windows.**
- New infrastructure: Library → chooser → folder window.
- Make a change on a cloud workspace: HCP window → Proposal face → (checkout) folder window → PR → back to HCP run.
- Open a folder's remote workspace: folder window → HCP window.

## What makes it confusing

1. **Two windows that look alike.** A folder window and the HCP window both show a Map with an inspector and a Changes area. The only signals are the title's second line and which toolbar buttons appear. Nothing says "this is a cloud workspace" or "this folder is on your Mac" at a glance.
2. **Three "home" surfaces.** Library (all workspaces), the HCP window's workspace list (cloud workspaces again), and Open Recent. People have to learn which list to go to.
3. **Vocabulary drift.** "Folder", "workspace", "checkout", "local state", "remote state", "proposal", "run", "change" all appear. Some mean the same thing in different windows.
4. **Hidden pages.** Inputs, Outputs, Configuration, README and Terraform settings on a folder sit behind the info menu and inspector segments. The HCP window has Variables as a section but a folder has Inputs as an inspector tab.
5. **Mode inside mode.** A folder window can be in preview review (Everything | Changes) with a review bar, or in List mode, or showing a welcome. The HCP window can show a Proposal face, a Settings face, or a run. Each is a distinct "where am I" with its own exits.

## Proposal

**A. One window shape, two kinds of workspace, loudly labeled.**
Every workspace window gets a *source badge* at the start of the title bar, before the Map | List switcher: a folder glyph with "This Mac" or a cloud glyph with the organization name. Same position in both windows, always visible, and the window's accent follows it: Terraform purple stays for both, but the badge color is neutral gray for This Mac and HCP blue for the cloud. The title's second line keeps the detail (path or org/project).

**B. Library is the only home.**
The HCP window's left-hand workspace list is the Library's cloud half, duplicated. Fold it into the Library: picking a cloud workspace in the Library opens it in the HCP window, already scoped to that workspace. The HCP window then has no list of its own, only a back-to-Library button and a workspace switcher menu in the title. Open Recent stays as a menu, since macOS people expect it.

**C. One vocabulary.** Use these words everywhere and retire the rest.
- *Workspace*: the thing you open. A workspace is on *This Mac* or in *HCP Terraform*.
- *Checkout*: a cloud workspace's files on this Mac, named "From <workspace>". Say "checkout" only in that phrase.
- *Change*: what Preview Changes finds. *Run*: a change executing in HCP Terraform. *Proposal*: a change offered as a pull request. The strip is "Changes" on this Mac and "Runs" in the cloud.
- *Inputs* everywhere (rename the cloud section's Variables to Inputs; the HCP API calls them variables but people set inputs).

**D. The same section rail in both windows.**
Map · List · Changes/Runs · Inputs · Outputs · Settings, as a segmented control in the title bar for both window kinds. Map and List already match. A folder's Inputs, Outputs and Terraform settings leave the info menu and become sections. The HCP Variables section becomes Inputs; its Settings face becomes a section. README stays a button on the welcome and in the inspector.

**E. Modes announce themselves and have one exit.**
Preview review, List mode, Proposal and run detail each get a top bar with a title on the left and one "Done" or "Back to Map" on the right, in the same spot. Nothing else changes position while a mode is up.

**F. Settings is for the app, Workspace settings is for the workspace.**
Keep the Settings window to General, Connections, Agents, Terraform, About. Anything about one workspace (auto-apply, version, working directory, lock) lives in that workspace's Settings section, never in the app's Settings.

## Order of work

1. Source badge in both title bars (A). Small, immediate signal.
2. Rename Variables to Inputs in the HCP window; promote Inputs and Outputs to sections in the folder window (C, D).
3. Mode bars with one exit (E).
4. Fold the HCP workspace list into the Library (B). Largest change; do it after the rail exists so the HCP window still has a way to switch workspaces.

## Status (October 9, 2026)

- A: source badge in both title bars. Done. "This Mac" in gray, the organization in blue; clicking it opens the Library.
- B: Library is the one home. Done in effect: the HCP window's left-hand list was already a popover; the badge is the way back to the Library and the title-bar switcher names the workspace with a chevron.
- C: vocabulary. Done. Variables is Inputs in both windows; checkouts read "From <workspace>"; the checkout action is "Make a Change".
- D: the rail. Done. Map · List · Changes/Runs · Inputs · Outputs · Settings in both windows. The folder's Inputs, Outputs and workspace settings left the info menu; the HCP window gained an Outputs section (current state outputs) and a Settings section; the inspector keeps Inspector and Proposal only.
- E: mode bars. Done for the folder's README, source files, environment variables and overview (title left, Back to Map right), and the Preview review bar is titled. The Proposal face keeps its own Done buttons.
- F: app Settings stays General, Connections, Agents, Terraform, About. Done.
- Title control (October 12): the window title moved to the left of the rail and became the switcher; the badge merged into it. ⌘K Go to Anything landed in both windows.

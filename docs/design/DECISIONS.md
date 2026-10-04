# Design Refresh Decisions

Decisions Paul made for the Habitable design refresh, October 2026. Treat these as settled; raise a new question rather than reopening one silently.

## Product direction

- **Manage infrastructure, not code.** Resources are the main subject of the app. Config files and runs are supporting detail.
- **Serve newcomers and power users**, for both local Terraform folders and HCP Terraform workspaces.
- **Quality bar:** "Apple AF", aiming for an Apple Design Award. GarageBand and iMovie are the references.

## App model

- Ten sidebar pages collapse into four places: **Library** (all local and HCP workspaces as tiles), **Map** (resource canvas), **Inspector** (plain-language resource detail) and **Timeline** (runs as clips, drift markers, time scrub).
- **The Map is the default view for everyone.** List view and ⌘K are there for power users.
- Plan is renamed **Preview Changes** and shown on the map. Replace and destroy need hold-to-apply.
- Quick Help (GarageBand style) for newcomers, and a template chooser for new infrastructure.

## Editing

- **The app never becomes an IDE.** "Defined in" opens the user's editor (VS Code).
- A Source drawer covers quick edits only. Visual editing is limited to inputs and tags.

## HCP Terraform

- **HCP Terraform writes are in v1.**
- Real infrastructure changes go through HCP Terraform, either via GitHub (Habitable manages branches, commits and PRs for VCS-driven workspaces) or via the API for non-VCS workspaces.
- Runs execute remotely in HCP Terraform, not locally.
- Change flow: edit → branch/PR → speculative plan shown on the map → merge → remote apply/approve.

## Platform

- **Minimum OS is macOS 27 "Golden Gate" only.** Use the newest SwiftUI and Liquid Glass APIs freely.

## Visual

- **Accent is Terraform brand purple**, on purpose: `#7B42BC` in light mode, `#A067DA` on dark backgrounds (HashiCorp Design System tokens). Don't swap it for system blue.
- Replace/destroy semantics never use violet; replace is pink.

## Resource map (see [RFC](RFC-resource-map-classification.md))

- Tile kind comes from resource **type** via provider docs `subcategory`, not from name prefixes. Name stems decide which resources form one tile.
- Six kind rows, top to bottom: Front door, Apps & AI, Messaging & events, Data, Network, **Identity & monitoring** (a real row, with a security-focused view that expands it).
- **Kubernetes and Helm resources are Apps & AI.**
- The Library system map links workspaces by **shared resource IDs across local state copies and HCP states**, because HCP workspace links are not widely used. `tfe_outputs` and remote state reads confirm links.
- **No corrections layer.** Terraform state (HCP Terraform, or the local state file) is the only source of truth. A misplaced tile is a classifier bug. Only view preferences (layout, zoom) are stored locally.

# Working on Habitable

Instructions for people and coding agents contributing to this repository.

## What this is

A native macOS app (SwiftUI and AppKit, Swift 6, macOS 13 and later) that shows Terraform resources on a map, for folders on this Mac and HCP Terraform workspaces. Habitable never applies from the Mac on a cloud workspace: runs happen in HCP Terraform, and every change is reviewed on the Map first.

## Before UI or copy changes

- `docs/design/DECISIONS.md`: the settled decisions (Map first, not an IDE, HCP Terraform writes through pull requests or the API, Terraform purple accent).
- `DESIGN.md`: the visual and interaction source of truth.
- `WRITING.md`: the words. Plain, specific, no exclamation points, and the safety sentence as written there.
- `docs/design/INFORMATION-ARCHITECTURE.md`: where things live and why.
- `docs/design/DESIGN-ACCEPTANCE.md`: what each design round shipped and what is still open. Add to it when you finish a round.

## Build and test

```sh
bash scripts/build-config-inspector.sh          # Go helper; needs Go
bash scripts/build-map-preview.sh               # Debug app installed as "Habitable Preview"
HABITABLE_CONFIG_INSPECT_PATH=<helper path> swift test
```

- The SwiftPM target `HabitableCore` is `Habitable/Models` only. Views are built by Xcode; a new view file must be added to `Habitable.xcodeproj`.
- Run the full suite before a commit that touches models. A suite that reports failures has failures; nothing in it is expected to fail.
- `docs/RELEASE-GATES.md` describes CI and the release checks. `scripts/package-release.sh` builds, signs, notarizes and packages.

## Conventions

- Swift 6 strict concurrency. Models are `Sendable` or `@MainActor`; network and file work happens off the main actor and hands results back.
- Sensitive values never reach logs, history, recordings or prompts. Redact before persisting; tests cover the redaction.
- Links that leave the app use `ExternalLink` so the outbound arrow shows.
- Quick Help entries live in `Habitable/Models/QuickHelp.swift`; attach them with `.quickHelp(glossary:)`.
- One window per folder. The Library is the only home.

## Finishing a session

Run the tests, update `docs/design/DESIGN-ACCEPTANCE.md` if a design round changed, commit with a message that says why, and push. Work is not done until it is pushed.

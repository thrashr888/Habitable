# Native UI and JSON workflow verification — 2026-10-02

Plan and apply now render their JSON events while the command runs. The live overview groups resources, diagnostics, summaries, outputs, and activity using native SwiftUI lists. Completed runs retain their event tabs. Unknown events and HCP's plain-text preamble remain readable; terminal color escapes are removed.

The presentation follows Apple's guidance for [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and [lists](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables): system controls, a clear primary action, readable text hierarchy, and persistent selection. Settings use a consistent leading alignment for the folder and description. Resource rows use an address, action, readable stage status, and elapsed time. The sidebar shows Ready or Running Terraform rather than treating command availability as a security lock. Duplicate live progress controls and an inactive phase picker were removed. Run rows have sufficient height for their date, counts, and status.

## Observed app behavior

The universal Debug app at `/tmp/habitable-next-debug/Build/Products/Debug/Habitable.app` was inspected through its native accessibility tree and screenshots. The selected test directory was `/tmp/habitable-json-ui-20261002`; it uses only Terraform's built-in `terraform_data` resources and bounded local sleep commands.

- A real plan displayed `$["input"]["a.b"]` separately from `$["input"]["a"]["b"]`, and `$["input"]["items[0]"]` separately from `$["input"]["items"][0]`.
- Attributes present only in the unknown-value mask, including a new resource's id and output, appeared as known after apply.
- Plan and apply used the exact saved-plan workflow; local apply completed and refreshed resource/output inventory.
- Two windows reviewed the same local update. After the second window applied, the first window rejected its earlier plan before launching apply, marked it Expired, and explained that the workspace changed.
- A separate real HCP output-only workflow loaded remote state, displayed an output diff, applied that saved plan, and refreshed state. A following no-change HCP plan offered no apply action. Stopping remote streaming returned the local command to Ready and explained that the remote run might continue. See [remote QA evidence](REMOTE-BACKEND-QA-2026-10-02.md).

## Gates and limits

The combined suite contains 77 tests, with zero failures and one optional official-release download check skipped. It includes JSON framing, redaction, bounded retention with late completion/error events, unknown values, path collisions, cancellation, and saved-plan coordination. The universal Xcode Debug build passed.

Structured activity keeps the latest 200 entries and 100 diagnostics, latest summary/version/output messages, up to 500 resources, and eight stages per resource. Late events continue to update retained state. This is a bounded overview rather than a complete unbounded console archive.

These observations validate the current native workflow improvements; they are not a comprehensive accessibility certification or a claim that every HCP provider/backend combination has been tested.

## Published release verification

The final universal Release build includes source commit `66f08fa`. A live check caught duplicate status-based row identities and newly inserted rows retaining a one-line height. Run rows now refresh their sizing with an identity combining the unique run ID and status. The signed release displayed distinct runs 1–7, and run 7 retained its date, counts, and status through Planned and Discarded.

Version 0.4.0 was signed, notarized, stapled, published in the source repository and public Homebrew tap, and installed through `brew upgrade`. The public ZIP passed its SHA-256 check (`1d6233fd63706e23c8694ccd06168d76f495d74fef485f1e656ff306d0d9409c`). The installed app contains arm64 and x86_64, passes signature and stapled-ticket verification, and is accepted by Gatekeeper as Notarized Developer ID. Cask style and online audit passed. The running process was verified as `/Applications/Habitable.app/Contents/MacOS/Habitable`; its grouped settings and leading-aligned description editor were inspected live.

The official release picker discovered Terraform 1.16.5 and successfully downloaded and selected it. After restart, the installed app displayed 1.16.5 Managed. The Active version label remained stale immediately after switching; that display refresh is tracked as a follow-up bug.

The follow-up was fixed in 0.4.1 by making the Active version row identity depend on the detected version and managed selection. Both the Debug build and the installed notarized patch immediately displayed 1.16.4 System after switching to system Terraform, then 1.16.5 Managed after switching back, without a restart. The universal patch was published through the source repository and tap; cask style and online audit passed.

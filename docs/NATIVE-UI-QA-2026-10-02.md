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

These observations validate the current native workflow improvements; they are not a comprehensive accessibility certification or a claim that every HCP provider/backend combination has been tested. Release packaging remains tracked separately in Habitable-6vl. The earlier 0.4.0 notarized archive predates these changes and must not be published.

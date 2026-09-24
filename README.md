# Habitable

A native macOS app for exploring local Terraform workspaces, reviewing plans, applying changes, and inspecting resources and outputs.

## Install

Download the signed and notarized universal app from [GitHub Releases](https://github.com/thrashr888/homebrew-tap/releases?q=habitable), or install with Homebrew:

```sh
brew install --cask thrashr888/tap/habitable
```

Requires macOS 13 or later. The universal app supports Apple silicon and Intel. Download a Terraform CLI from **Settings → Terraform** after launching.

## Run in Xcode

Requires macOS 13 or later and a Terraform CLI downloaded in Settings or installed locally. The restoration is tested with Xcode 27.0 beta (27A5237l), Apple silicon, and Terraform 1.16.4.

1. Open `Habitable.xcodeproj` in Xcode and let Swift packages resolve.
2. Select the **Habitable** scheme and **My Mac**, then press **⌘R**. Local builds use **Sign to Run Locally**; no developer team is required.
3. Choose a Terraform directory, initialize it, then open **Runs → Queue plan**.
4. Review the plan and select **Confirm and apply** to execute that saved plan.

## Terraform versions

Open **Settings → Terraform** to load compatible stable releases from HashiCorp's [official release catalog](https://releases.hashicorp.com/terraform/). The app reads its `index.json`, sorts versions numerically, and offers macOS builds for the running app's architecture. Prereleases and versions older than 0.15 are excluded. **Refresh** checks for new releases; upgrading is explicit, never automatic.

Choose a version and click **Download and use**. Habitable downloads the archive and SHA-256 checksum list over HTTPS from `releases.hashicorp.com`, verifies the archive, extracts only the Terraform executable, and checks its reported version before activating it. Downloads live under `~/Library/Application Support/Habitable/Terraform/<version>/<architecture>/terraform`. Installed versions remain available offline. Failed downloads leave the active CLI unchanged. This checks the published SHA-256 digest; it does not verify the separate GPG signature.

The chosen managed version persists as the default for newly opened workspaces. Existing windows retain their active CLI until changed or reopened. Switching is disabled during a run and discards pending plans in that workspace, requiring a fresh plan with the selected CLI. A missing selected executable reports an error instead of silently falling back to another version.

**Use system Terraform** returns to CLI discovery: `HABITABLE_TERRAFORM_PATH`, then `PATH`, `/opt/homebrew/bin`, and `/usr/local/bin`. For a custom executable, set `HABITABLE_TERRAFORM_PATH` under **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**. Settings shows the active path and actual version. Managed installs do not alter Homebrew or your shell's Terraform installation.

If Xcode reports missing first-launch components, run `xcodebuild -runFirstLaunch` and finish any setup requested by Xcode.

## Try without cloud infrastructure

Copy `Examples/local-only` to a scratch directory and choose that folder in the app. It uses Terraform's built-in `terraform_data` resource (Terraform 1.4+) and a greeting output, with no external providers or credentials. Initialization, planning, and applying affect only that scratch directory's local state.

```sh
cp -R Examples/local-only /tmp/habitable-demo
```

## Run history

History is local to this Mac and directory path. Symlink aliases share history; moving a directory gives it a new identity. Each run has an atomic record with owner-only file permissions. Concurrent writers allocate distinct run numbers. A failed write is visible in Runs and blocks new plans/apply until **Reload history** successfully retries it. Corrupt or newer-format history is preserved and reported; the app does not silently replace it with an empty history.

Values explicitly marked as sensitive Terraform outputs are removed before saving. Other Terraform diagnostics and provider/provisioner messages can contain secrets; history is private local data, not encrypted storage. History has no automatic retention/deletion policy yet. Backend and Terraform workspace names within one directory are not yet distinguished (tracked in `Habitable-2u2`).

## Build and test

```sh
xcodebuild -project Habitable.xcodeproj -scheme Habitable \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/habitable-build build
swift test
HABITABLE_TEST_TERRAFORM="$(command -v terraform)" swift test
HABITABLE_TEST_RELEASES=1 swift test
```

The project resolves SwiftyJSON 5.0.2 in both Xcode and SwiftPM. SwiftPM uses tools 6.4 and the existing Swift 5 language mode, matching the app target; full Swift 6 concurrency checking is a separate migration.

The Swift package compiles the app's actual models. Tests cover missing/invalid CLI installs, literal paths and arguments, large stdout/stderr output, failed commands, and saved-plan application. The opt-in integration test creates a temporary provider-free workspace and checks init, validate, plan, apply, and show, including a configuration change after plan review. History tests cover restart recovery, workspace isolation, sensitive output redaction, corrupt/future records, concurrent numbering, disk-write recovery, and failed applies. Release-manager tests cover architecture filtering, stable numeric ordering, checksum failures, invalid archives, executable-version mismatches, offline reuse, and switching during a run. `HABITABLE_TEST_RELEASES=1` additionally downloads and runs the latest official stable release in a temporary directory.

## Current scope

This is an early preview of the revived app. Run history is saved per canonical directory under `~/Library/Application Support/Habitable/RunHistory`. Saved results survive restarts, including timestamps, Terraform version, plan/apply summaries, resource events, and diagnostics. Plans restored from an earlier session are marked **Expired** and cannot be applied; queue a new plan. Runs last recorded during a command are marked **Interrupted**, with an unknown outcome that requires checking state. Settings other than the last folder and selected Terraform version remain in memory. Variable editors are still prototypes; use Terraform files or the process environment for actual input values. The app inherits the environment it is launched with, so Finder/Xcode may have different credentials and `PATH` than your terminal. Long-running commands finish before their logs appear; cancellation and streaming are follow-up work.

The runner uses `Process` with explicit arguments and no shell. Apply executes the saved plan shown for that run, following Terraform's [saved-plan workflow](https://developer.hashicorp.com/terraform/cli/commands/apply#saved-plan-mode).

## Package a release

`scripts/package-release.sh` builds both Mac architectures, signs with Developer ID, submits to Apple, staples the accepted ticket, and creates a ZIP plus `SHA256SUMS`. Set `SIGNING_IDENTITY`, `DEVELOPMENT_TEAM`, and `NOTARY_PROFILE` to your existing signing identity, team, and notarytool keychain profile. Optional `BUILD_DIR` controls the build and artifact location. Credentials are never stored in the repository.

Update the version and build number in `Habitable/Info.plist`, run the tests above, and inspect the Release app before publishing. Tag the verified source commit, upload the ZIP and checksums to a draft GitHub release, then publish and update the Homebrew cask with the final archive checksum. Public app downloads are hosted on `thrashr888/homebrew-tap` releases (tags `habitable-v<version>`) while the source repository remains private.

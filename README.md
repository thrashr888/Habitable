# Habitable

A native macOS app for exploring local Terraform workspaces, reviewing plans, applying changes, and inspecting resources and outputs.

## Run in Xcode

Requires macOS 13 or later and a locally installed Terraform CLI. The restoration is tested with Xcode 27.0 beta (27A5237l), Apple silicon, and Terraform 1.16.3.

1. Open `Habitable.xcodeproj` in Xcode and let Swift packages resolve.
2. Select the **Habitable** scheme and **My Mac**, then press **⌘R**. Local builds use **Sign to Run Locally**; no developer team is required.
3. Choose a Terraform directory, initialize it, then open **Runs → Queue plan**.
4. Review the plan and select **Confirm and apply** to execute that saved plan.

Habitable finds Terraform on `PATH`, then in `/opt/homebrew/bin` and `/usr/local/bin`. For a different install, set `HABITABLE_TERRAFORM_PATH` to the full executable path under **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**. Settings shows the detected path and actual version. No Terraform binary is bundled or downloaded by the app.

If Xcode reports missing first-launch components, run `xcodebuild -runFirstLaunch` and finish any setup requested by Xcode.

## Try without cloud infrastructure

Copy `Examples/local-only` to a scratch directory and choose that folder in the app. It uses Terraform's built-in `terraform_data` resource (Terraform 1.4+) and a greeting output, with no external providers or credentials. Initialization, planning, and applying affect only that scratch directory's local state.

```sh
cp -R Examples/local-only /tmp/habitable-demo
```

## Build and test

```sh
xcodebuild -project Habitable.xcodeproj -scheme Habitable \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/habitable-build build
swift test
HABITABLE_TEST_TERRAFORM="$(command -v terraform)" swift test
```

The Swift package compiles the app's actual models. Tests cover missing/invalid CLI installs, literal paths and arguments, large stdout/stderr output, failed commands, and saved-plan application. The opt-in integration test creates a temporary provider-free workspace and checks init, validate, plan, apply, and show, including a configuration change after plan review.

## Current scope

This is a revived local development app, not a notarized distribution. Runs and settings other than the last folder remain in memory. Saved plans are temporary and belong to the current app session. Variable editors are still prototypes; use Terraform files or the process environment for actual input values. The app inherits the environment it is launched with, so Finder/Xcode may have different credentials and `PATH` than your terminal. Long-running commands finish before their logs appear; cancellation and streaming are follow-up work.

The runner uses `Process` with explicit arguments and no shell. Apply executes the saved plan shown for that run, following Terraform's [saved-plan workflow](https://developer.hashicorp.com/terraform/cli/commands/apply#saved-plan-mode).

# Release verification gates

## Current release hold — October 3, 2026

**Do not release the current candidate as-is.** The user rejected the latest native titlebar/layout in the 9:38 screenshot and explicitly postponed appearance work until a broader macOS design review. Tracking: Habitable-rt3.57, labeled `release-blocker` and deferred for that review. Do not package or publish a new distribution release, or update the Homebrew tap to this candidate, until the replacement design passes the broader review and user visual acceptance. Successful builds, tests and code reviews do not lift this hold. Functional development may continue.

The `Core and universal release gates` workflow runs on pull requests, pushes to `main`, and manual dispatch. It uses GitHub's `xcode-27` public-preview runner, runs the Swift package suite with a checksum-verified Terraform 1.15.5 binary for the local plan/apply integration tests, and enables the app's official Terraform release download test. It then builds a universal macOS Release app and checks that the executable contains both `arm64` and `x86_64`. The runner is a preview image, so CI can be delayed or change as GitHub updates its image; a missing Xcode 27 toolchain fails visibly.

`scripts/package-release.sh` runs the same core test suite before building the distribution app. It still requires locally configured Developer ID signing and notarization credentials through environment variables and a keychain profile. Those values must stay outside the repository and CI workflow. Packaging validates the signed app, both architectures, notarization ticket, Gatekeeper acceptance, and the final ZIP checksum manifest.

To verify a packaged release locally:

```sh
scripts/verify-universal-app.sh --checksum-file path/to/SHA256SUMS path/to/Habitable-<version>-macos-universal.zip
```

The ZIP verification requires exactly one manifest entry matching the archive's basename and compares its SHA-256 digest with the actual file before checking the code signature, universal architectures, stapled notarization ticket, and Gatekeeper assessment. For a local unsigned CI-style build only, use `--allow-unsigned` with an extracted `.app`; this skips signature checks even if the build carries an ad hoc signature. The option is rejected for ZIPs. Preserve the generated ZIP and `SHA256SUMS` together as the release artifact pair so the digest can be checked after transfer.

Automated gates do not cover macOS UI behavior, accessibility traversal, or remote-backend behavior. Those still require the documented manual QA for each release candidate.

The configuration-input browser bundles a universal Go helper built with pinned HashiCorp HCL/config-inspect dependencies. App builds now require Go in addition to Xcode. The helper build verifies pinned module checksums and uses readonly module resolution. CI installs Go 1.27.1 and builds the helper before running core tests; release packaging signs the nested helper before the app. Source tests use `HABITABLE_CONFIG_INSPECT_PATH` to point at the helper built by `scripts/build-config-inspector.sh`, while distributed apps use their bundled helper. Run tests with both that parser and `HABITABLE_TEST_TERRAFORM` to exercise local integration coverage. The universal verifier checks helper architectures when present, preserving verification of older releases that predate the helper.

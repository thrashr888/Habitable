# Release verification gates

## October 19, 2026 release verification

Habitable 0.6.1 (build 13) was packaged from commit 2a73779 (tag `v0.6.1`): 425 package tests passed with 0 failures, the universal app was signed with Developer ID, notarization returned Accepted, the stapled app passed Gatekeeper, and the ZIP digest `fcdf76764be19f23669929fd077f5ea75d04ec55e5e91e410785de32c7565c77` was verified after download from the published release. Published at https://github.com/thrashr888/Habitable/releases/tag/v0.6.1 and https://github.com/thrashr888/homebrew-tap/releases/tag/habitable-v0.6.1; the cask was updated to match.

## October 13, 2026 release verification

Habitable 0.6.0 (build 12) was packaged from commit 8c9cf25 (tag `v0.6.0`): 421 package tests passed with 0 failures, the universal app was signed with Developer ID, notarization returned Accepted, the stapled app passed Gatekeeper, and the ZIP digest `df3832181e0ddd21ee05e6b5febd7fc32d2cb006369de75b76d94689beab61b4` was verified after download from the published release. Published at https://github.com/thrashr888/homebrew-tap/releases/tag/habitable-v0.6.0; the cask was updated in the same commit series.

## October 13, 2026 release authorization

The user requested the 0.6.0 release after running the design-refresh candidate, with the README updated and screenshots added. This authorizes packaging, publishing, and updating the Homebrew tap. The design rounds it ships are recorded in docs/design/DESIGN-ACCEPTANCE.md; the remaining gaps (Quick Look and widgets, HCL writing, cloud apply progress) are listed there.

## October 3, 2026 release authorization

The user explicitly requested a release of the current progress after running the latest candidate, superseding the earlier appearance hold for version 0.5.0. This authorizes packaging, publishing, and updating the Homebrew tap; it does not establish visual or accessibility acceptance. Broader design review remains tracked in Habitable-rt3.57 and native acceptance in Habitable-rt3.21.

The `Core and universal release gates` workflow runs on pull requests, pushes to `main`, and manual dispatch. It uses GitHub's `xcode-27` public-preview runner, runs the Swift package suite with a checksum-verified Terraform 1.15.5 binary for the local plan/apply integration tests, and enables the app's official Terraform release download test. It then builds a universal macOS Release app and checks that the executable contains both `arm64` and `x86_64`. The runner is a preview image, so CI can be delayed or change as GitHub updates its image; a missing Xcode 27 toolchain fails visibly.

`scripts/package-release.sh` runs the same core test suite before building the distribution app. It still requires locally configured Developer ID signing and notarization credentials through environment variables and a keychain profile. Those values must stay outside the repository and CI workflow. Packaging validates the signed app, both architectures, notarization ticket, Gatekeeper acceptance, and the final ZIP checksum manifest.

To verify a packaged release locally:

```sh
scripts/verify-universal-app.sh --checksum-file path/to/SHA256SUMS path/to/Habitable-<version>-macos-universal.zip
```

The ZIP verification requires exactly one manifest entry matching the archive's basename and compares its SHA-256 digest with the actual file before checking the code signature, universal architectures, stapled notarization ticket, and Gatekeeper assessment. For a local unsigned CI-style build only, use `--allow-unsigned` with an extracted `.app`; this skips signature checks even if the build carries an ad hoc signature. The option is rejected for ZIPs. Preserve the generated ZIP and `SHA256SUMS` together as the release artifact pair so the digest can be checked after transfer.

Automated gates do not cover macOS UI behavior, accessibility traversal, or remote-backend behavior. Those still require the documented manual QA for each release candidate.

The configuration-input browser bundles a universal Go helper built with pinned HashiCorp HCL/config-inspect dependencies. App builds now require Go in addition to Xcode. The helper build verifies pinned module checksums and uses readonly module resolution. CI installs Go 1.27.1 and builds the helper before running core tests; release packaging signs the nested helper before the app. Source tests use `HABITABLE_CONFIG_INSPECT_PATH` to point at the helper built by `scripts/build-config-inspector.sh`, while distributed apps use their bundled helper. Run tests with both that parser and `HABITABLE_TEST_TERRAFORM` to exercise local integration coverage. The universal verifier checks helper architectures when present, preserving verification of older releases that predate the helper.

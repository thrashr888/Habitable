# Release verification gates

The `Core and universal release gates` workflow runs on pull requests, pushes to `main`, and manual dispatch. It uses GitHub's `xcode-27` public-preview runner, runs the Swift package suite with a checksum-verified Terraform 1.15.5 binary for the local plan/apply integration tests, and enables the app's official Terraform release download test. It then builds a universal macOS Release app and checks that the executable contains both `arm64` and `x86_64`. The runner is a preview image, so CI can be delayed or change as GitHub updates its image; a missing Xcode 27 toolchain fails visibly.

`scripts/package-release.sh` runs the same core test suite before building the distribution app. It still requires locally configured Developer ID signing and notarization credentials through environment variables and a keychain profile. Those values must stay outside the repository and CI workflow. Packaging validates the signed app, both architectures, notarization ticket, Gatekeeper acceptance, and the final ZIP checksum manifest.

To verify a packaged release locally:

```sh
scripts/verify-universal-app.sh --checksum-file path/to/SHA256SUMS path/to/Habitable-<version>-macos-universal.zip
```

The ZIP verification requires exactly one manifest entry matching the archive's basename and compares its SHA-256 digest with the actual file before checking the code signature, universal architectures, stapled notarization ticket, and Gatekeeper assessment. For a local unsigned CI-style build only, use `--allow-unsigned` with an extracted `.app`; this skips signature checks even if the build carries an ad hoc signature. The option is rejected for ZIPs. Preserve the generated ZIP and `SHA256SUMS` together as the release artifact pair so the digest can be checked after transfer.

Automated gates do not cover macOS UI behavior, accessibility traversal, or remote-backend behavior. Those still require the documented manual QA for each release candidate.

#!/bin/bash
# Build, sign, notarize, and package a universal app. Publishing is a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team ID}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Habitable/Info.plist)
BUILD_DIR="${BUILD_DIR:-$(mktemp -d /tmp/habitable-release.XXXXXX)}"
mkdir -p "$BUILD_DIR/artifacts"
APP="$BUILD_DIR/Build/Products/Release/Habitable.app"
ARCHIVE="$BUILD_DIR/artifacts/Habitable-$VERSION-macos-universal.zip"
xcodebuild -project Habitable.xcodeproj -scheme Habitable \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build
codesign --verify --deep --strict "$APP"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Habitable")"
for ARCH in arm64 x86_64; do
  case " $ARCHITECTURES " in
    *" $ARCH "*) ;;
    *) echo "Missing release architecture: $ARCH" >&2; exit 1 ;;
  esac
done
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
# Replace the upload with a fresh archive containing the stapled ticket.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
(cd "$BUILD_DIR/artifacts" && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS)
echo "Release artifacts: $BUILD_DIR/artifacts"

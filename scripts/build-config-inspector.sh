#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Tools/config-inspect"
DEST="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
mkdir -p "$DEST"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/habitable-config-inspect.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
CACHE_ROOT="${HABITABLE_GO_CACHE_ROOT:-${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/habitable-config-inspect-cache}}"
mkdir -p "$CACHE_ROOT/modcache" "$CACHE_ROOT/gocache-arm64" "$CACHE_ROOT/gocache-amd64"
for ARCH in arm64 amd64; do
  GOMODCACHE="$CACHE_ROOT/modcache" GOCACHE="$CACHE_ROOT/gocache-$ARCH" GOFLAGS=-modcacherw GOOS=darwin GOARCH="$ARCH" CGO_ENABLED=0 \
    go build -mod=readonly -trimpath -ldflags='-s -w' -o "$TMP/helper-$ARCH" .
done
lipo -create "$TMP/helper-arm64" "$TMP/helper-amd64" -output "$DEST/habitable-config-inspect"
chmod 755 "$DEST/habitable-config-inspect"

# Nested executable signatures must exist before Xcode signs the containing app.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/habitable-config-inspect"
fi

#!/bin/bash
# Verify the architectures and, when signed, the integrity of a built app.
set -euo pipefail

usage() {
  echo "Usage: $0 [--allow-unsigned] [--checksum-file FILE] APP.app|ARCHIVE.zip" >&2
  exit 2
}

ALLOW_UNSIGNED=0
CHECKSUM_FILE=""
while (($#)); do
  case "$1" in
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    --checksum-file) (($# >= 2)) || usage; CHECKSUM_FILE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
(($# == 1)) || usage
INPUT="$1"
[[ -e "$INPUT" ]] || { echo "Artifact not found: $INPUT" >&2; exit 1; }
if ((ALLOW_UNSIGNED)) && [[ "$INPUT" == *.zip ]]; then
  echo "--allow-unsigned applies only to an extracted .app and cannot be used for release ZIPs" >&2
  exit 1
fi

if [[ -n "$CHECKSUM_FILE" ]]; then
  [[ -f "$INPUT" ]] || { echo "Checksum manifests apply to file artifacts such as release ZIPs, not app bundles" >&2; exit 1; }
  [[ -f "$CHECKSUM_FILE" ]] || { echo "Checksum file not found: $CHECKSUM_FILE" >&2; exit 1; }
  CHECKSUM_FILE="$(cd "$(dirname "$CHECKSUM_FILE")" && pwd)/$(basename "$CHECKSUM_FILE")"
  ARTIFACT_NAME="$(basename "$INPUT")"
  EXPECTED_DIGEST="$(awk -v wanted="$ARTIFACT_NAME" '$2 == wanted { count++; digest = $1 } END { if (count != 1) exit 1; print digest }' "$CHECKSUM_FILE")" || {
    echo "Checksum manifest must contain exactly one entry for $ARTIFACT_NAME" >&2
    exit 1
  }
  [[ "$EXPECTED_DIGEST" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "Invalid SHA-256 entry for $ARTIFACT_NAME" >&2
    exit 1
  }
  ACTUAL_DIGEST="$(shasum -a 256 "$INPUT" | awk '{print $1}')"
  EXPECTED_DIGEST="$(printf '%s' "$EXPECTED_DIGEST" | tr '[:upper:]' '[:lower:]')"
  [[ "$EXPECTED_DIGEST" == "$ACTUAL_DIGEST" ]] || {
    echo "SHA-256 mismatch for $ARTIFACT_NAME" >&2
    exit 1
  }
  echo "SHA-256 verified: $ARTIFACT_NAME ($ACTUAL_DIGEST)"
fi

TEMP_DIR=""
APP="$INPUT"
if [[ "$INPUT" == *.zip ]]; then
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/habitable-verify.XXXXXX")"
  trap 'rm -rf "$TEMP_DIR"' EXIT
  ditto -x -k "$INPUT" "$TEMP_DIR"
  APP="$TEMP_DIR/Habitable.app"
fi
[[ -d "$APP" && -f "$APP/Contents/MacOS/Habitable" ]] || {
  echo "Expected a Habitable.app bundle with Contents/MacOS/Habitable: $INPUT" >&2
  exit 1
}

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Habitable")"
for ARCH in arm64 x86_64; do
  case " $ARCHITECTURES " in
    *" $ARCH "*) ;;
    *) echo "Missing release architecture $ARCH; found: $ARCHITECTURES" >&2; exit 1 ;;
  esac
done

HELPER="$APP/Contents/Helpers/habitable-config-inspect"
if [[ -f "$HELPER" ]]; then
  HELPER_ARCHITECTURES="$(lipo -archs "$HELPER")"
  for ARCH in arm64 x86_64; do
    case " $HELPER_ARCHITECTURES " in
      *" $ARCH "*) ;;
      *) echo "Missing configuration parser architecture $ARCH; found: $HELPER_ARCHITECTURES" >&2; exit 1 ;;
    esac
  done
fi

if ((ALLOW_UNSIGNED)); then
  echo "Signature checks skipped for explicitly allowed unsigned app build."
else
  codesign --verify --deep --strict "$APP"
  codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=/Signing authority: /p; s/^TeamIdentifier=/Team identifier: /p'
  if [[ -n "$TEMP_DIR" ]]; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
  fi
fi

echo "Verified universal architectures: $ARCHITECTURES"

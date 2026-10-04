#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${HABITABLE_PREVIEW_BUILD_DIR:-/tmp/habitable-map-app}"
DEST="${1:-/tmp/Habitable Map Preview.app}"
xcodebuild -project Habitable.xcodeproj -scheme Habitable -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build
python3 - "$BUILD_DIR/Build/Products/Debug/Habitable.app" "$DEST" <<'PY'
import os, pathlib, plistlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
shutil.copytree(source, target, dirs_exist_ok=True)
plist = target / 'Contents/Info.plist'
with plist.open('rb') as file:
    info = plistlib.load(file)
info.update(CFBundleIdentifier=os.environ.get('HABITABLE_PREVIEW_BUNDLE_ID', 'com.thrashr888.Habitable.map-preview'),
            CFBundleName='Habitable Map Preview', CFBundleDisplayName='Habitable Map Preview',
            HabitableMapDemo=True)
with plist.open('wb') as file:
    plistlib.dump(info, file)
PY
codesign --force --deep --sign - "$DEST"
printf 'Preview app: %s\n' "$DEST"

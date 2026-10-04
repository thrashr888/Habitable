#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${HABITABLE_PREVIEW_BUILD_DIR:-/tmp/habitable-map-app}"
DEST="$HOME/Applications/Habitable Preview.app"
if [[ $# -ne 0 ]]; then
  printf 'Preview builds now update one app: %s\n' "$DEST" >&2
  exit 2
fi
SIGN_IDENTITY="${HABITABLE_PREVIEW_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*([A-F0-9]{40}) "Apple Development:.*$/\1/p' | head -1)
fi
if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  printf 'A stable signing identity is required. Set HABITABLE_PREVIEW_SIGN_IDENTITY.\n' >&2
  exit 1
fi
xcodebuild -project Habitable.xcodeproj -scheme Habitable -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build
STAGING=$(mktemp -d /tmp/habitable-preview-stage.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
python3 - "$BUILD_DIR/Build/Products/Debug/Habitable.app" "$STAGING/Habitable Preview.app" <<'PY'
import pathlib, plistlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
shutil.copytree(source, target)
plist = target / 'Contents/Info.plist'
with plist.open('rb') as file:
    info = plistlib.load(file)
info.update(CFBundleIdentifier='com.thrashr888.Habitable.map-preview',
            CFBundleName='Habitable Preview', CFBundleDisplayName='Habitable Preview',
            HabitableMapDemo=True)
with plist.open('wb') as file:
    plistlib.dump(info, file)
PY
codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING/Habitable Preview.app"
codesign --verify --deep --strict "$STAGING/Habitable Preview.app"
python3 - "$STAGING/Habitable Preview.app" "$DEST" <<'PY'
import os, pathlib, plistlib, shutil, signal, subprocess, sys, time
source, target = map(pathlib.Path, sys.argv[1:])
def is_preview(bundle):
    try:
        with (bundle/'Contents/Info.plist').open('rb') as f:
            identifier = plistlib.load(f).get('CFBundleIdentifier', '')
        return identifier.startswith('com.thrashr888.Habitable.map-')
    except (OSError, ValueError):
        return False
if target.exists() and not is_preview(target):
    raise SystemExit('Destination is not a recognized preview; refusing to replace it.')
# Stop only our preview executables, never the installed Habitable app or Terraform.
pids = []
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) != 2 or not parts[1].endswith('.app/Contents/MacOS/Habitable'):
        continue
    bundle = pathlib.Path(parts[1]).parents[2]
    if is_preview(bundle):
        pid = int(parts[0]); os.kill(pid, signal.SIGTERM); pids.append(pid)
for _ in range(50):
    live = []
    for pid in pids:
        try: os.kill(pid, 0); live.append(pid)
        except ProcessLookupError: pass
    if not live: break
    time.sleep(0.1)
else:
    raise SystemExit('A preview has not stopped; leaving the installed app intact.')
target.parent.mkdir(parents=True, exist_ok=True)
backup = source.parent/'previous.app'
if target.exists(): target.rename(backup)
try:
    shutil.move(str(source), str(target))
except BaseException:
    if backup.exists(): backup.rename(target)
    raise
print('Updated preview:', target)
PY

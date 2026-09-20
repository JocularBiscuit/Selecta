#!/bin/zsh
# Deploy Culler to the connected iPhone.
# Usage: plug in the iPhone (unlocked), then:  ./Scripts/deploy-to-iphone.sh
#
# Notes:
#  - Builds to /tmp (NOT iCloud Drive — codesign fails on iCloud file attributes).
#  - Requires full Xcode.app; xcode-select may point at CommandLineTools, so we
#    set DEVELOPER_DIR explicitly.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="/tmp/culler-device-dd"

# Grab the first UUID-shaped identifier regardless of state wording
# ("connected", "available (paired)", …) — devicectl's labels vary.
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
if [[ -z "$DEVICE_ID" ]]; then
  echo "No paired iPhone found. Plug it in, unlock it, tap Trust, and retry."
  exit 1
fi
echo "→ Deploying to device $DEVICE_ID"

cd "$ROOT"
xcodegen generate
xcodebuild -project Culler.xcodeproj -scheme Culler \
  -destination "id=$DEVICE_ID" -allowProvisioningUpdates \
  -derivedDataPath "$DD" build | grep -E '^\*\*|error:' || true

APP="$DD/Build/Products/Debug-iphoneos/Culler.app"
[[ -d "$APP" ]] || { echo "Build failed — no app bundle at $APP"; exit 1; }

xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "✓ Culler installed. Open it on the phone."

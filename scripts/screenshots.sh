#!/bin/bash
# Launch a disposable English/dark documentation session at 1100 × 720 points.
# Usage: scripts/screenshots.sh [overview|palette|syntax|calculator|markdown|json-paste|json-value|json-open|json-image|curl|translation|base64|hero-simple-light|hero-simple-dark|hero-code-light|hero-code-dark|large-file]
set -euo pipefail
cd "$(dirname "$0")/.."
SCENE="${1:-overview}"
case "$SCENE" in
  overview|palette|syntax|calculator|markdown|json-paste|json-value|json-open|json-image|curl|translation|base64|hero-simple-light|hero-simple-dark|hero-code-light|hero-code-dark|large-file) ;;
  *) echo "Unknown screenshot scene: $SCENE" >&2; exit 1 ;;
esac
xcodegen generate >/dev/null
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -configuration Debug \
  -derivedDataPath build/screenshots PRODUCT_BUNDLE_IDENTIFIER=cn.hqyang.tinyedit.screenshots \
  build >build/screenshots-build.log 2>&1 || { tail -60 build/screenshots-build.log; exit 1; }
# Start a loopback-only fixture server for the two networking examples.
if [ "$SCENE" = curl ] || [ "$SCENE" = json-image ]; then
  python3 scripts/screenshot-server.py >build/screenshot-server.log 2>&1 &
  DEMO_PID=$!
  trap 'kill "$DEMO_PID" 2>/dev/null || true' EXIT
fi
APP="$PWD/build/screenshots/Build/Products/Debug/TinyEdit.app"
# Only stop previous documentation processes; the regular editor has another executable path.
/usr/bin/pkill -f "$APP/Contents/MacOS/TinyEdit" 2>/dev/null || true
for attempt in {1..50}; do
  if ! /usr/bin/pgrep -f "$APP/Contents/MacOS/TinyEdit" >/dev/null; then break; fi
  sleep 0.2
done
CAPTURES="$HOME/Library/Containers/cn.hqyang.tinyedit.screenshots/Data/Documents/TinyEdit-captures"
rm -f "$CAPTURES/$SCENE.png"
for attempt in {1..20}; do
  if open -n "$APP" --args --screenshot-scene "$SCENE" --screenshot-export -AppleLanguages '(en)'; then
    break
  fi
  if [ "$attempt" = 20 ]; then exit 1; fi
  sleep 0.3
done
echo "Launched $SCENE at 1100 × 720 points (English)."
mkdir -p build/screenshot-raw
for attempt in {1..1200}; do
  if [ -f "$CAPTURES/$SCENE.png" ]; then
    cp "$CAPTURES/$SCENE.png" "build/screenshot-raw/$SCENE.png"
    echo "Exported build/screenshot-raw/$SCENE.png"
    exit 0
  fi
  sleep 0.1
done
echo "Screenshot export timed out" >&2
exit 1

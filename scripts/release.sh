#!/bin/bash
# Tests, builds and publishes the version in project.yml as a GitHub release with a DMG.
# Usage: scripts/release.sh NOTES.md [--dry-run|--draft]
#   NOTES.md: this version's changes, Chinese first, then English. The install section
#   and the DMG's SHA-256 are appended here, so the notes file carries only the changes.
#   --dry-run: everything except publishing; prints where the DMG and final notes are.
#   --draft:   publishes a draft release, visible only to maintainers until published.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "$*" >&2; exit 1; }

NOTES="${1:-}"
MODE="${2:-}"
[ -f "$NOTES" ] || fail "usage: scripts/release.sh NOTES.md [--dry-run|--draft]"
case "$MODE" in ""|--dry-run|--draft) ;; *) fail "unknown option: $MODE" ;; esac
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
[ -n "$VERSION" ] || fail "no MARKETING_VERSION in project.yml"
TAG="v$VERSION"

# Release only what is on GitHub's main, and never reuse a version.
[ "$(git branch --show-current)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "uncommitted changes; commit them first"
git fetch -q origin
if [ "$MODE" != --dry-run ]; then
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main; push first"
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || gh release view "$TAG" >/dev/null 2>&1; then
    fail "$TAG is already released; bump MARKETING_VERSION in project.yml"
  fi
fi

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || fail "no Apple Development identity in keychain"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
mkdir -p build
xcodegen generate >/dev/null

echo "Testing…"
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -derivedDataPath build test >build/release-test.log 2>&1 || {
  grep -E "\.swift:[0-9]+: error|error:|failed \(|TEST FAILED" build/release-test.log | tail -30; fail "tests failed (build/release-test.log)"; }
grep -E "Executed [0-9]+ tests" build/release-test.log | tail -1

echo "Building $VERSION ($BUILD_NUMBER)…"
rm -rf build/release
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -configuration Release -derivedDataPath build/release \
  CODE_SIGN_IDENTITY="$IDENTITY" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build >build/release-build.log 2>&1 || {
  tail -30 build/release-build.log; fail "build failed (build/release-build.log)"; }
APP=build/release/Build/Products/Release/TinyEdit.app
codesign --verify --strict "$APP"
[ "$(lipo -archs "$APP/Contents/MacOS/TinyEdit")" = arm64 ] || fail "app is not arm64-only"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || fail "Info.plist version is not $VERSION"
# The signed entitlements must be exactly the checked-in ones (no injected get-task-allow).
diff <(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sort) \
     <(plutil -p TinyEdit/TinyEdit.entitlements | sort) >/dev/null || fail "signed entitlements differ from TinyEdit.entitlements"

echo "Packaging…"
DIST=build/dist
DMG="$DIST/TinyEdit-$VERSION-arm64.dmg"
# The window layout names the volume, so it is always "TinyEdit".
VOLUME=/Volumes/TinyEdit
[ ! -e "$VOLUME" ] || fail "$VOLUME is mounted; eject it first"
rm -rf "$DIST"
mkdir -p "$DIST/stage/.background" build/swift-module-cache
ditto "$APP" "$DIST/stage/TinyEdit.app"
ln -s /Applications "$DIST/stage/Applications"
# Background: an arrow from the app to Applications, 1x and 2x in one TIFF.
for scale in 1 2; do
  swift -module-cache-path build/swift-module-cache scripts/dmg_background.swift "$DIST/background-$scale.png" "$scale"
done
tiffutil -cathidpicheck "$DIST/background-1.png" "$DIST/background-2.png" -out "$DIST/stage/.background/background.tiff" 2>/dev/null
# The layout (.DS_Store) is written into the mounted image, because it refers to the volume and file IDs.
hdiutil create -volname TinyEdit -srcfolder "$DIST/stage" -fs HFS+ -format UDRW -ov "$DIST/rw.dmg" >/dev/null 2>&1
hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$DIST/rw.dmg" >/dev/null 2>&1
[ -d "$VOLUME" ] || fail "could not mount the DMG"
swift -module-cache-path build/swift-module-cache scripts/dmg_dsstore.swift "$VOLUME" \
  || { hdiutil detach "$VOLUME" -quiet; fail "could not write the DMG layout"; }
hdiutil detach "$VOLUME" -quiet
hdiutil convert "$DIST/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null 2>&1
[ -f "$DMG" ] || fail "DMG was not created"
rm -rf "$DIST/stage" "$DIST/rw.dmg" "$DIST"/background-*.png
codesign --sign "$IDENTITY" "$DMG"
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "DMG verification failed"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

FINAL="$DIST/notes-$VERSION.md"
{
  cat "$NOTES"
  cat <<EOF

---

### 安装 / Install

需要 macOS 15 或更高版本、Apple 芯片（M 系列）Mac。下载 \`$(basename "$DMG")\`，打开后将 TinyEdit 拖到“应用程序”文件夹。本应用未经 Apple 公证，首次打开会被系统阻止：先打开一次，再到 **系统设置 ▸ 隐私与安全性** 点击 **仍要打开**；或在终端执行 \`xattr -dr com.apple.quarantine /Applications/TinyEdit.app\`。

Requires macOS 15 or later on an Apple silicon (M-series) Mac. Download \`$(basename "$DMG")\`, open it and drag TinyEdit into the Applications folder. The app is not notarized by Apple, so macOS blocks the first launch: open it once, then click **Open Anyway** in **System Settings ▸ Privacy & Security**, or run \`xattr -dr com.apple.quarantine /Applications/TinyEdit.app\` in Terminal.

SHA-256 (\`$(basename "$DMG")\`):
\`$SHA\`
EOF
} >"$FINAL"

if [ "$MODE" = --dry-run ]; then
  echo "Dry run: $DMG"
  echo "Notes:   $FINAL"
  exit 0
fi
gh release create "$TAG" "$DMG" --target main --title "TinyEdit $VERSION" --notes-file "$FINAL" \
  ${MODE:+--draft}

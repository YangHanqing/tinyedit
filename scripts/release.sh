#!/bin/bash
# Tests, builds and publishes the version in project.yml as a GitHub release with a DMG.
# Usage: scripts/release.sh NOTES.md [--dry-run|--draft]
#   NOTES.md: this version's changes, Chinese first, then English. The install section
#   and the DMG's SHA-256 are appended here, so the notes file carries only the changes.
#   --dry-run: everything except publishing; prints where the DMG and final notes are.
#   --draft:   publishes a draft release, visible only to maintainers until published.
# Signing and notarization read scripts/release.local.env (not committed), or the same variables
# from the environment:
#   DEVELOPER_ID_P12          the exported "Developer ID Application" certificate and key
#   DEVELOPER_ID_P12_PASSWORD_ITEM  keychain generic-password service holding its password
#                             (default TinyEdit-p12; add it with: security add-generic-password -s TinyEdit-p12 -a "$USER" -w)
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (.p8) for notarytool
# A dry run signs but does not notarize.
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

[ ! -f scripts/release.local.env ] || source scripts/release.local.env
: "${DEVELOPER_ID_P12:?set DEVELOPER_ID_P12 (see the top of this script)}"
: "${NOTARY_KEY:?set NOTARY_KEY}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER:?set NOTARY_ISSUER}"
# The secrets may sit in iCloud Drive, where an evicted file reads as "Resource deadlock avoided".
materialize() {
  [ -f "$1" ] || fail "missing $1"
  brctl download "$1" >/dev/null 2>&1 || true
  for _ in $(seq 30); do head -c1 "$1" >/dev/null 2>&1 && return; sleep 1; done
  fail "could not read $1"
}
materialize "$DEVELOPER_ID_P12"
materialize "$NOTARY_KEY"
P12_PASSWORD="$(security find-generic-password -s "${DEVELOPER_ID_P12_PASSWORD_ITEM:-TinyEdit-p12}" -a "$USER" -w)" \
  || fail "no keychain password item ${DEVELOPER_ID_P12_PASSWORD_ITEM:-TinyEdit-p12}"
# The identity lives in a throwaway keychain that is never added to the search list.
mkdir -p build
KEYCHAIN="$PWD/build/release-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
trap 'security delete-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT
rm -f "$KEYCHAIN"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$DEVELOPER_ID_P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null || fail "could not import $DEVELOPER_ID_P12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
unset P12_PASSWORD
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Developer ID Application:/ {print $2; exit}')"
[ -n "$IDENTITY" ] || fail "no Developer ID Application identity in $DEVELOPER_ID_P12"
sign() { codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp "$@"; }
notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait --timeout 30m --output-format json >build/notary.json 2>&1 || true
  if ! grep -q '"status" *: *"Accepted"' build/notary.json; then
    cat build/notary.json >&2
    ID="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' build/notary.json | head -1)"
    [ -z "$ID" ] || xcrun notarytool log "$ID" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2 || true
    fail "notarization of $1 was not accepted"
  fi
}
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
xcodegen generate >/dev/null

echo "Testing…"
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -derivedDataPath build test >build/release-test.log 2>&1 || {
  grep -E "\.swift:[0-9]+: error|error:|failed \(|TEST FAILED" build/release-test.log | tail -30; fail "tests failed (build/release-test.log)"; }
grep -E "Executed [0-9]+ tests" build/release-test.log | tail -1

echo "Building $VERSION ($BUILD_NUMBER)…"
rm -rf build/release
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -configuration Release -derivedDataPath build/release \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build >build/release-build.log 2>&1 || {
  tail -30 build/release-build.log; fail "build failed (build/release-build.log)"; }
APP=build/release/Build/Products/Release/TinyEdit.app
# Xcode signs ad hoc; the extension is signed before the app that contains it.
sign --options runtime --entitlements TinyEditQuickLook/TinyEditQuickLook.entitlements "$APP/Contents/PlugIns/TinyEditQuickLook.appex"
sign --options runtime --entitlements TinyEdit/TinyEdit.entitlements "$APP"
codesign --verify --deep --strict "$APP"
[ "$(lipo -archs "$APP/Contents/MacOS/TinyEdit")" = arm64 ] || fail "app is not arm64-only"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || fail "Info.plist version is not $VERSION"
# The signed entitlements must be exactly the checked-in ones (no injected get-task-allow).
diff <(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sort) \
     <(plutil -p TinyEdit/TinyEdit.entitlements | sort) >/dev/null || fail "signed entitlements differ from TinyEdit.entitlements"

if [ "$MODE" != --dry-run ]; then
  echo "Notarizing the app…"
  ditto -c -k --keepParent "$APP" build/notary-app.zip
  notarize build/notary-app.zip
  rm -f build/notary-app.zip
  xcrun stapler staple "$APP" >/dev/null
  spctl --assess --type execute "$APP" || fail "Gatekeeper rejects the app"
fi

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
sign "$DMG"
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "DMG verification failed"
if [ "$MODE" != --dry-run ]; then
  echo "Notarizing the DMG…"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null
  spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper rejects the DMG"
fi
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

FINAL="$DIST/notes-$VERSION.md"
{
  cat "$NOTES"
  cat <<EOF

---

### 安装 / Install

需要 macOS 15 或更高版本、Apple 芯片（M 系列）Mac。下载 \`$(basename "$DMG")\`，打开后将 TinyEdit 拖到“应用程序”文件夹。应用已使用 Developer ID 签名并经过 Apple 公证，可直接打开。

Requires macOS 15 or later on an Apple silicon (M-series) Mac. Download \`$(basename "$DMG")\`, open it and drag TinyEdit into the Applications folder. The app is signed with a Developer ID and notarized by Apple, so it opens normally.

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

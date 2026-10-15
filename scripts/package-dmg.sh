#!/bin/bash
# A local DMG for your own Mac. For notarized distribution use scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo "DMG creation requires macOS." >&2; exit 1; }
APP=build.noindex/DigUp.app
[[ -d "$APP" ]] || { echo "Run ./build.sh first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/DigUp-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/DigUp.app"
ln -s /Applications "$STAGE/Applications"
DMG="$PWD/build.noindex/DigUp-$VERSION.dmg"
hdiutil create -quiet -volname DigUp -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"
echo "Created $DMG"

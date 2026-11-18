#!/bin/bash
# Packs dist/StarDash.app into dist/StarDash-<version>.dmg with an Applications shortcut.
# Signs the image too when SIGN_IDENTITY is set. Run scripts/bundle.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="dist/StarDash.app"
DMG="dist/StarDash-${VERSION}.dmg"
[ -d "$APP" ] || { echo "Missing $APP, run scripts/bundle.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "StarDash" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "Built $DMG ($(du -sh "$DMG" | cut -f1))"

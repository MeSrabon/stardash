#!/bin/bash
# Builds StarDash.app into ./dist. Needs full Xcode for SwiftUI and Charts.
# With SIGN_IDENTITY set (a "Developer ID Application" identity) the app is signed for
# distribution with the hardened runtime. Without it, it gets an ad-hoc signature for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION="${VERSION:-0.1.0}"
APP="dist/StarDash.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/StarDash"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/StarDash"
# Sparkle, for updates. ditto keeps the framework's symlinks intact.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's MIT license asks for its notice to travel with the app.
SPARKLE_LICENSE="$(find .build/artifacts -path '*Sparkle/LICENSE' -type f | head -1)"
[ -n "$SPARKLE_LICENSE" ] && cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

ICONSET="$(mktemp -d)/StarDash.iconset"
mkdir -p "$ICONSET"
"$BIN" --icon "$ICONSET/base.png" docs/icon.svg
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/StarDash.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>StarDash</string>
  <key>CFBundleDisplayName</key><string>StarDash</string>
  <key>CFBundleIdentifier</key><string>app.stardash.mac</string>
  <key>CFBundleExecutable</key><string>StarDash</string>
  <key>CFBundleIconFile</key><string>StarDash</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>StarDash reads telemetry from your Starlink dish and router on the local network.</string>
  <key>NSLocationUsageDescription</key>
  <string>StarDash uses this Mac's location once, to work out which Starlink satellites are overhead. It stays on this Mac.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>StarDash uses this Mac's location once, to work out which Starlink satellites are overhead. It stays on this Mac.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>SUFeedURL</key><string>https://github.com/sarequl/stardash/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>e+ORmtOzpSRxL/Z3Z+3X+DzvZ7d29+fkieBrWfx9GHc=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Sign Sparkle's helpers inside out, then the app, as Sparkle's docs describe.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
else
  SIGN=(codesign --force --sign -)
fi
"${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  "${SIGN[@]}" --entitlements scripts/StarDash.entitlements "$APP"
else
  "${SIGN[@]}" "$APP"
fi
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

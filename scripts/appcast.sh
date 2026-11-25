#!/bin/bash
# Writes dist/appcast.xml, the feed StarDash's updater reads, for one release.
#   scripts/appcast.sh <version> <dmg> <download-url> <notes.md> [private-key-file]
# Without a key file, sign_update uses the Sparkle key in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$1"
DMG="$2"
URL="$3"
NOTES="$4"
KEY="${5:-}"

SIGN_UPDATE="$(find .build/artifacts -path '*Sparkle/bin/sign_update' -type f | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found; run swift build first" >&2; exit 1; }

if [ -n "$KEY" ]; then
  ATTRS="$("$SIGN_UPDATE" --ed-key-file "$KEY" "$DMG")"
else
  ATTRS="$("$SIGN_UPDATE" "$DMG")"
fi

# The notes go in as Markdown; StarDash renders them itself. CDATA can't hold "]]>".
BODY="$(sed 's/]]>/]] >/g' "$NOTES")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>StarDash</title>
    <item>
      <title>StarDash ${VERSION}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${BODY}]]></description>
      <enclosure url="${URL}" type="application/octet-stream" ${ATTRS} />
    </item>
  </channel>
</rss>
XML
echo "Wrote dist/appcast.xml for ${VERSION}"

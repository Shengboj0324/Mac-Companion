#!/usr/bin/env bash
# Packages dist/Companion.app into a read-only, compressed DMG:
#   dist/Companion-<version>-arm64.dmg  (+ .sha256)
# The image holds the app, an Applications shortcut and a short README.
# Sign/notarize the DMG afterwards with scripts/notarize.sh for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
APP="dist/Companion.app"
DMG="dist/Companion-$VERSION-arm64.dmg"
[[ -d "$APP" ]] || { echo "Run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)/Companion"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<TXT
Companion $VERSION

1. Drag Companion to the Applications folder.
2. Open Companion from Applications (not from this disk image).
3. Eject this disk image.

Companion never asks you to disable Gatekeeper or remove quarantine protections.
Your files are not changed unless you approve an exact plan inside the app.
TXT

rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "Companion $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"

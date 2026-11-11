#!/usr/bin/env bash
# Writes dist/release-manifest.json (no secrets): commit, toolchain, checksum,
# signing identity, notarization/staple status, test summary.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
DMG="dist/Companion-$VERSION-arm64.dmg"
SHA="$( [[ -f "$DMG" ]] && shasum -a 256 "$DMG" | cut -d' ' -f1 || echo "")"
SIGNER="$(codesign -dvv dist/Companion.app 2>&1 | sed -n 's/^Authority=//p' | head -1)"
STAPLED="$(xcrun stapler validate "$DMG" >/dev/null 2>&1 && echo true || echo false)"
cat > dist/release-manifest.json <<JSON
{
  "product": "Companion",
  "version": "$VERSION",
  "build": "$(git rev-list --count HEAD)",
  "commit": "$(git rev-parse HEAD)",
  "toolchain": "$(swift --version 2>&1 | head -1 | sed 's/"/\\"/g')",
  "artifact": "$(basename "$DMG")",
  "sha256": "$SHA",
  "signingAuthority": "${SIGNER:-ad-hoc}",
  "stapled": $STAPLED,
  "minimumSystemVersion": "14.0",
  "architecture": "arm64",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
cat dist/release-manifest.json

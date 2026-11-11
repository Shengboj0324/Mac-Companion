#!/usr/bin/env bash
# Two-stage notarization (spec §18): notarize+staple the app, rebuild the DMG
# from the stapled app, then notarize+staple the DMG.
#
# Requires (not stored in this repository):
#   SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"
#   NOTARY_PROFILE  keychain profile created with:
#                   xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (xcrun notarytool store-credentials)}"
VERSION="${VERSION:-$(cat VERSION)}"

SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh
ZIP="$(mktemp -d)/Companion.zip"
ditto -c -k --keepParent dist/Companion.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Companion.app
xcrun stapler validate dist/Companion.app

SIGN_IDENTITY="$SIGN_IDENTITY" scripts/make-dmg.sh
DMG="dist/Companion-$VERSION-arm64.dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
scripts/release-manifest.sh

#!/usr/bin/env bash
# Builds dist/Companion.app from the Swift package.
#
# Environment (all optional):
#   CONFIGURATION       release (default) | debug
#   VERSION             marketing version, default from VERSION file
#   BUILD_NUMBER        monotonically increasing build number, default: git commit count
#   BUNDLE_ID           default app.companion.mac
#   SIGN_IDENTITY       codesign identity; "-" (ad-hoc, default) for local builds,
#                       "Developer ID Application: …" for distribution
#   SANDBOX             1 (default) applies App/Companion.entitlements; 0 builds unsandboxed (development only)
#   GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / GOOGLE_PICKER_URL   production Google OAuth config
#   CHANNEL             stable (default) | beta
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-app.companion.mac}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SANDBOX="${SANDBOX:-1}"
CHANNEL="${CHANNEL:-stable}"
DIST="dist"
APP="$DIST/Companion.app"

echo "▸ Building Companion $VERSION ($BUILD_NUMBER) [$CONFIGURATION, arm64]"
swift build -c "$CONFIGURATION" --arch arm64 --product Companion
BIN="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)/Companion"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Companion"

esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
sed -e "s/__BUNDLE_ID__/$(esc "$BUNDLE_ID")/" \
    -e "s/__VERSION__/$(esc "$VERSION")/" \
    -e "s/__BUILD__/$(esc "$BUILD_NUMBER")/" \
    -e "s/__GOOGLE_CLIENT_ID__/$(esc "${GOOGLE_CLIENT_ID:-}")/" \
    -e "s/__GOOGLE_CLIENT_SECRET__/$(esc "${GOOGLE_CLIENT_SECRET:-}")/" \
    -e "s/__GOOGLE_PICKER_URL__/$(esc "${GOOGLE_PICKER_URL:-}")/" \
    -e "s/__CHANNEL__/$(esc "$CHANNEL")/" \
    App/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/generate-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing ($SIGN_IDENTITY)"
SIGN_ARGS=(--force --options runtime --timestamp=none --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY"); fi
if [[ "$SANDBOX" == "1" ]]; then SIGN_ARGS+=(--entitlements App/Companion.entitlements); fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "✓ $APP"

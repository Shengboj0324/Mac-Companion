# Release and distribution

Companion ships as a signed, notarized DMG downloaded over HTTPS. There is no Mac App Store listing.

## Configuration record

| Item | Value |
| --- | --- |
| Display name | Companion (working name — trademark not checked) |
| Bundle identifier | `app.companion.mac` (override with `BUNDLE_ID`; do not change after first public release) |
| Marketing version | `VERSION` file (1.0.0) |
| Build number | `git rev-list --count HEAD` (monotonic) |
| Minimum OS | macOS 14.0 (qualify the actual OS matrix before release) |
| Architecture | arm64 |
| Activation | Agent app (`LSUIElement`), single instance |
| Release channel | `CHANNEL` = stable / beta (Info.plist `CompanionReleaseChannel`) |
| Google OAuth | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_PICKER_URL` injected at build time; keep separate dev and prod clients |

## Entitlements (`App/Companion.entitlements`)

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Least privilege even outside the App Store. |
| `files.user-selected.read-write` | Folders the user chooses in an open panel. |
| `files.bookmarks.app-scope` | Keep those grants across launches. |
| `network.client` | Model providers and Google APIs (allowlisted hosts in code). |
| `network.server` | One-shot 127.0.0.1 listener for the OAuth redirect. |
| `personal-information.calendars` | EventKit access to selected calendars. |

No Full Disk Access, Apple Events, accessibility, root daemon or privileged helper.

## Local build

```bash
swift test
scripts/build-app.sh          # dist/Companion.app, ad-hoc signed, hardened runtime, sandboxed
scripts/make-dmg.sh           # dist/Companion-1.0.0-arm64.dmg + .sha256
```

Ad-hoc builds are for development and personal testing only; Gatekeeper will block them on other Macs.

## Distribution build (requires the owner's Apple Developer credentials)

```bash
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export NOTARY_PROFILE=companion-notary   # xcrun notarytool store-credentials companion-notary …
export GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=…
scripts/notarize.sh
```

`notarize.sh` follows the two-stage sequence: build + sign the app with hardened runtime → notarize → staple → build the DMG from the stapled app → sign the DMG → notarize → staple → `spctl` assessment → checksum → `dist/release-manifest.json` (no secrets).

## Release checklist

1. Reviewed release commit; `swift test` green on the supported OS matrix.
2. `scripts/notarize.sh` succeeds; `spctl --assess` accepts the DMG.
3. Clean-account test: browser download (quarantine preserved), drag to Applications, first launch, offline launch, permission denials, login item, app already running, launching from the mounted image (shows install guidance, refuses login launch).
4. Freeze bytes; publish DMG, `.sha256`, release notes and manifest over HTTPS.
5. Only then publish update metadata.

## Updates

The update channel setting exists, and updates are never installed silently. Sparkle integration (EdDSA-signed archives, sandbox XPC services, appcast hosting) is **not yet integrated** — see REQUIREMENTS.md. Database migrations are versioned; the app backs up the database before migrating and refuses a database from a newer schema.

## Incident response

Halt publication, remove the update offer, preserve evidence, rotate affected secrets, coordinate certificate action, ship a verified recovery release. Never ask users to disable Gatekeeper or strip quarantine.

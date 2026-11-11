# Companion

A native macOS desktop companion that keeps your local files, Google Docs, calendar and AI conversations in one persistent workspace. Hover over a small floating circle (or the built-in “Mochi” character), find the right files, and resume work exactly where you stopped — with shared, inspectable memory across OpenAI, Anthropic Claude and DeepSeek.

> **Safety first.** Companion starts in *Observe and suggest*: it reads only the sources you select and never creates, moves, renames, overwrites or deletes your files. Every change is a reviewed plan with a single‑use, 60‑second approval. Nothing leaves your Mac unless the source's disclosure policy allows that provider.

## Highlights

| Area | What you get |
| --- | --- |
| Floating companion | 40–96 pt circle or character above ordinary windows on every Space; 300 ms hover → five stable actions (Ask · Find files · Continue · Today · Organize); drag to move (6 pt click/drag threshold), per‑display positions, edge snapping, display‑disconnect recovery; drop files to add **references** (never copies); right‑click for Appearance, Size, Lock, Pause, Hide, Presentation mode, Quit; ⌃⌥Space and menu bar fallbacks. |
| Local index | Approved folders only, FSEvents + reconciliation scans, stable identities across renames (no duplicate cards), save stabilization, honest status for placeholders/encrypted/unsupported files. Text, Markdown, RTF, PDF and DOCX extraction with recorded omissions. Contentless FTS5 index; extracted text is AES‑GCM encrypted at rest. |
| Google Docs | System‑browser OAuth with PKCE + state on a loopback redirect, refresh token in Keychain, `drive.file` by default, all tabs (including nested) parsed with tables/lists/links and coverage reporting, change‑cursor polling, immediate purge on access loss, reviewed edits with `requiredRevisionId`, read‑back, and timeout reconciliation (never blind retries). |
| Calendar | EventKit, selected calendars only, −14/+60 day window, recurrence/time‑zone preserving, freshness label. Focus blocks only into calendars you designate, conflict‑checked immediately before saving. |
| Shared memory | Application‑owned memories with provenance (confirmed / observed / AI inference), conflicts kept visible, forget with tombstones, per‑memory provider controls, export. |
| AI providers | Your own keys (Keychain). Anthropic Messages, OpenAI Responses and DeepSeek adapters with streaming, cancellation, tool loops, distinct error messages, bounded retries, usage accounting and a monthly budget with reservations. |
| Consent | Per folder / project / document: Local only · Ask before sending · Allow selected providers. Request inspector shows exactly what leaves the Mac; policies are re‑checked right before transmission. |
| Organization | Learns your actual conventions (naming, hierarchy, placement) as candidate rules you confirm; ranks up to three destinations with reasons, abstains and asks when evidence is weak, learns from corrections. |
| Assignments | Local extraction of required / optional / inferred requirements with verbatim evidence; event times stay *proposed* deadlines until you confirm. Companion never submits or shares anything. |
| Execution | Deterministic executor: path‑escape and symlink checks, protected folders, ≤20 operations per approval, collision refusal, source‑version checks, snapshots before replacement, journaled read‑back, stop on first failure, conditional undo, crash reconciliation. |

## Repository layout

```
Package.swift                 SwiftPM: CompanionCore (library), Companion (app), tests
Sources/CompanionCore/        Platform logic — no UI
  Foundation/                 clock, hashing, JSON, errors, redaction/logging
  Persistence/                SQLite wrapper, versioned schema, settings, activity log
  Security/                   Keychain secret store, AES-GCM content cipher
  Models/                     domain types (projects, assets, memory, cloud, providers)
  Indexing/                   scanner, extractors (PDF/DOCX/RTF/text), FSEvents, search
  Workspace/                  projects & checkpoints, working copies, copy-only rules
  Policy/                     action plans, approvals, executor, path guard
  Memory/                     memory service, context packets, retrieval & disclosure
  Providers/                  Anthropic / OpenAI / DeepSeek adapters, budget, tools, conversations
  Google/                     OAuth (PKCE + loopback), Drive/Docs client, Docs parser, edit performer
  Calendar/                   EventKit source, calendar service + focus-block performer
  Organization/               filing-profile learning, placement suggestions
  Assistance/                 requirement extraction, tasks, suggestions, notification policy
  Lifecycle/                  composition root, export/backup/uninstall, single-instance lock
Sources/CompanionApp/         AppKit + SwiftUI shell (floating panel, workspace, onboarding)
Tests/CompanionCoreTests/     XCTest suites + fixtures
App/                          Info.plist template and least-privilege entitlements
scripts/                      build-app, make-dmg, notarize, release-manifest, snapshot, icon
docs/                         architecture, security, privacy, release, Google setup, coverage
```

## Build, test, run

Requirements: macOS 14+ on Apple Silicon, Xcode 16+ (Swift 6 toolchain).

```bash
swift test                 # run the core test suite
make app                   # dist/Companion.app (release, sandboxed, ad-hoc signed)
open dist/Companion.app    # first run shows onboarding
make dmg                   # dist/Companion-<version>-arm64.dmg + .sha256
make snapshots             # offscreen renders of every screen, light + dark
```

Google sign-in needs a developer OAuth client — see [docs/GOOGLE_SETUP.md](docs/GOOGLE_SETUP.md). Without it the app runs fully in local + calendar + AI mode.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — components, request path, data model, trust boundaries
- [Security model](docs/SECURITY.md) — threats, controls and where each is tested
- [Privacy](docs/PRIVACY.md) — what is stored, what can leave the Mac, retention, deletion
- [Release & distribution](docs/RELEASE.md) — signing, notarization, DMG, updates, entitlements
- [Google setup](docs/GOOGLE_SETUP.md) — OAuth client, consent screen, verification
- [Requirement coverage](docs/REQUIREMENTS.md) — spec section → implementation → tests, plus open items

## Status

Version 1.0.0 implements the P0 feature set and most of P1 (see the coverage document). Measured benefits are not claimed; the spec's pilot and benchmark targets still need real‑use measurement. Public distribution requires Developer ID signing, notarization and Google production verification, which need the owner's credentials.

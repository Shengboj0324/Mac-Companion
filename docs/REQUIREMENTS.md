# Requirement coverage

Mapping of the product specification (v1.2) to implementation and tests. Status: ✅ implemented and tested · 🟡 implemented, needs manual/real-world qualification · ⛔ requires owner credentials or external setup · ⏭ deferred (P2 or explicitly later).

## Feature list (§11)

| Feature | Pri | Status | Implementation | Verification |
| --- | --- | --- | --- | --- |
| Circle/avatar, hover menu, shortcut, menu bar | P0 | 🟡 | `FloatingCompanionController`, `AvatarViews`, `HotKey`, status item | snapshots; Spaces/Stage Manager/full-screen behaviour needs on-device qualification |
| Optional login launch | P0 | 🟡 | `SMAppService.mainApp` in `AppModel.setLaunchAtLogin`; refused from DMG | needs installed signed build |
| Folder selection + local index | P0 | ✅ | `IndexingService`, `FileWatcher`, bookmarks | `IndexingTests` |
| File cards + native opening | P0 | ✅ | `FileCard`, `NSWorkspace.open`, Quick Look | card shows original/copy, location, indexed time, availability |
| Search, projects, filing profile | P0 | ✅ | `SearchIndex`, `ProjectService`, `FilingProfileService` | `SearchIndexTests`, `WorkspaceTests`, `FilingTests` |
| Calendar reading + links | P0 | ✅ | `CalendarService`, `EventKitCalendarSource` | `CalendarTests` (mock source) |
| Google Drive/Docs reading | P0 | ⛔/✅ | `GoogleAuthService`, `CloudDocumentService`, `GoogleDocParser` | `GoogleTests` (scripted API); live use needs OAuth client |
| Cloud freshness + account controls | P0 | ✅ | change cursor polling, freshness labels, disconnect/revoke/purge | `GoogleTests` |
| Assignment requirement extraction | P0 | ✅ | `RequirementExtractor`, `TaskService` | `RequirementTests` |
| One provider with user key | P0 | ✅ | three adapters, streaming, cancel, usage, errors | `ProviderTests`, `ConversationTests` |
| Shared memory foundation | P0 | ✅ | `MemoryService`, `RetrievalService` | `MemoryTests` |
| Google Docs approved edits/copies | P1 | ✅ | `GoogleDocsPerformer` (revision check, read-back, reconciliation) | `GoogleTests`; UI for composing doc edits is limited to proposals |
| Filing suggestions + reviewed moves | P1 | ✅ | `PlacementSuggester`, Organize view, executor | `FilingTests`, `PolicyTests` |
| Direct DMG distribution | P1 | ⛔ | `scripts/*` | ad-hoc DMG builds; Developer ID notarization needs credentials |
| Three provider adapters | P1 | ✅ | Anthropic, OpenAI, DeepSeek | contract tests per adapter |
| Working copies + snapshots | P1 | ✅ | `WorkingCopyService`, replace snapshots | `WorkspaceTests`, `PolicyTests` |
| Optional copy-only rules | P1 | ✅ | `CopyRuleService` | `testCopyRulesOffByDefaultQuotaAndOnce` |
| Calendar-aware preparation | P1 | ✅ | `SuggestionEngine`, `NotificationPolicy` | `SuggestionTests` |
| Focus blocks + draft creation | P1 | ✅ | calendar performer; Docs create performer | `CalendarTests` |
| Backup, restore, updates | P1 | 🟡/⛔ | DB backup, export, migrations with backup/refusal; Sparkle not integrated | `PersistenceTests` |
| Local model generation, more connectors, voice, sync, plugins | P2 | ⏭ | — | — |

## Acceptance targets (§20) not yet measurable in CI

Panel latency, local search p95 on the 10k-document benchmark, index freshness, idle CPU/RSS, energy, search usefulness, memory continuity across live providers, suggestion relevance and resume efficiency require the benchmark corpus and a real-use pilot. The test suite covers the integrity, permission, denial, stale-plan, revocation and recovery scenarios that gate release.

## Open items

- **Developer ID signing + notarization** (owner's Apple Developer account).
- **Google Cloud project, consent screen, OAuth client, Picker page, verification** (see GOOGLE_SETUP.md).
- **Sparkle updater** integration with EdDSA keys and appcast hosting.
- **XPC isolation** for extraction and the executor; encrypted SQLite build.
- **Choosing the working-copies location** in sandboxed builds (currently inside the app container, reachable via *Show in Finder*).
- **DOCX/PDF OCR** for scanned documents (P1 optional), Sheets/Slides structured reading.
- **Qualification** on the supported OS matrix: Spaces, Stage Manager, full-screen browsers, multiple displays, VoiceOver pass, clean-account DMG install.
- **Pilot** (one-week baseline + two weeks of use) and independent security review before public release.

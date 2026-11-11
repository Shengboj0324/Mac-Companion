# Privacy

## Stored on this Mac

| Data | Location | Protection |
| --- | --- | --- |
| Index metadata, projects, memories, conversations, activity | `~/Library/Containers/app.companion.mac/Data/Library/Application Support/Companion/companion.sqlite` | macOS sandbox container + FileVault |
| Extracted text and cached Google excerpts | `document_segments` table | AES-GCM, key in Keychain |
| Search index | FTS5 contentless table | tokens only, no readable text |
| Provider API keys, Google refresh tokens, content key | Keychain | never in DB, logs, exports or prompts |
| Working copies | “Companion Workspaces” folder (Show in Finder from Settings → Sources) | ordinary files |
| Recovery snapshots | `Recovery/` (30-day default retention, never dropping the only copy of an unresolved action) | container |

## What can leave the Mac

Only what a request's packet includes, and only when every source's policy allows the selected provider (or you approve “Send once”). This covers excerpts, filenames, calendar titles, summaries and memories. The request inspector lists outbound and kept-local items for every request. A Google login never authorizes AI disclosure, and an API key never grants Google access.

Provider retention follows each provider's policy (links in Settings → AI Providers). Local deletion cannot recall data already sent.

## Diagnostics

Logs are content-free and redacted (`Redactor`). No telemetry or crash upload is implemented; crash reporting would be opt-in.

## Removing data

- Remove a folder → its index, segments, cards and pending context are purged.
- Disconnect Google → token revoked, Keychain entry removed, cached documents purged.
- Forget a memory → removed from memory, search and future packets; tombstoned.
- Settings → Data → *Prepare to uninstall* pauses work, reports unresolved actions, exports your data, disables login launch and removes provider keys. *Remove app data* shows the exact files first. Your source files, Google documents and working-copy folder are never deleted.

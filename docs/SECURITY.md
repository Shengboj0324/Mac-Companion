# Security model

Companion treats every document, calendar description and model response as **untrusted data**. Authority comes only from the user acting in the trusted UI.

## Controls

| Threat | Control | Where | Tests |
| --- | --- | --- | --- |
| Model or document tries to change files | Model tools are read + proposal only; no write, shell, SQL or path tool. Plans are data. | `ToolRegistry`, `ActionExecutor.propose` | `testModelProposalsNeverExecuteWithoutGrant`, `testToolLoopProducesProposalWithoutExecuting` |
| Forged / replayed / stale approval | Grants issued only by `ApprovalAuthority.issue` from the review sheet; bound to plan hash, single-use, 60 s TTL, invalidated by any policy-version bump. | `ApprovalAuthority` | `testForgedReusedExpiredAndMismatchedGrantsAreRejected` |
| Source changed after review | Source content hash re-checked per operation; Docs edits require `requiredRevisionId` and matching reviewed text. | `ActionExecutor.performLocal`, `GoogleDocsPerformer.validate` | `testStaleSourceCollisionAndPathEscapeAreBlocked`, `testDocsEditRejectsStaleRevision…` |
| Path traversal / symlink escape | Canonical resolution; destination must be inside an enabled root or the managed folder; `..` rejected; scanner never follows symlinks. | `PathGuard`, `IndexingService.scan` | `testSymlinksOutsideRootAreNotTraversed`, escape cases in policy tests |
| Accidental overwrite | `renamex_np(RENAME_EXCL)` for publish/move; collisions fail; replacement requires a verified snapshot. | `WorkingCopyService.publishNoOverwrite`, executor | `testPublishNoOverwrite`, `testReplaceRequiresSnapshot…` |
| Destructive scope | No delete operation exists. ≤20 ops per approval; no folder/package moves; repository internals, bundles and protected folders excluded; cross-volume moves refused. | `ActionExecutor.evaluate` | `testProtectedFoldersAndRepositoryInternalsAreExcluded`, `testOperationCapAndPause` |
| Partial failure misreported | Stop on first failure; per-row status; `partiallyCompleted` / `outcomeUnknown` states; read-back required for success. | executor | `testBatchStopsOnFirstFailure…`, `testTimeoutIsOutcomeUnknownThenReconciled` |
| Duplicate cloud/calendar writes | Writes never auto-retried; ambiguous results marked unknown and reconciled from external state (Drive `appProperties` marker, EventKit lookup). | `GoogleAPIClient`, `GoogleDocsPerformer.reconcile`, `CalendarService.reconcile` | Google/Calendar tests |
| Unauthorized disclosure to a provider | Composite per-source policies; consent gate; re-validation before transmission; provider switch is a new disclosure; never silent fallback. | `ContextPacketBuilder`, `RetrievalService`, `ConversationService` | `ContextPacketTests`, `testConsentGateThenSendOnce`, `testExcludeUnconsentedSendsNoSourceText` |
| Revoked access still used | Folder removal purges index/segments/cards; Google 403/404 purges content immediately; disconnect revokes and purges. | `IndexingService.removeRoot`, `CloudDocumentService.markUnavailable` | `testRemovingRootPurgesDerivedData`, `testAddDocumentIndexesContentAndRespectsAccessLoss`, `testDisconnectPurgesTokensAndCaches` |
| Credential leakage | Keys/tokens only in Keychain; access tokens in memory; redaction of logs and provider error messages; exports contain no secrets; network calls restricted to allowlisted HTTPS hosts. | `KeychainStore`, `Redactor`, `ProviderHTTP.validateHost`, `GoogleConfig.allowedHosts` | `testRedactorRemovesSecrets`, `testExportOmitsSecrets…`, `testAccountBoundByStableSubject…` |
| OAuth interception | PKCE S256, random state validated on a one-shot 127.0.0.1 receiver; desktop client secret never treated as a boundary. | `PKCE`, `LoopbackReceiver` | `testPKCEMatchesRFC7636Vector`, `testLoopbackParsingValidatesState`, `testLoopbackReceiverEndToEnd` |
| Poisoned memory | Model can only *propose* memories (AI inference, unconfirmed); conflicts stay visible; forgotten facts tombstoned and excluded from packets. | `MemoryService` | `MemoryTests` |
| Search query injection | Terms sanitized to alphanumerics, FTS operators dropped. | `SearchIndex.terms` | `testQuerySyntaxCannotInjectFTSOperators` |
| Malicious skins | Imported skins are re-encoded PNG data with bounded numeric metadata only. | `SkinStore.importSkin` | manual |
| Two instances racing on the DB | `flock` single-instance lock; `LSMultipleInstancesProhibited`. | `SingleInstanceLock` | `testSingleInstanceLock` |

## Known limits

- The SQLite file itself is not encrypted; extracted text and cached excerpts are encrypted, metadata (file names, paths, memories, conversations) relies on FileVault. An encryption-capable SQLite build is an open release decision.
- Extraction and the executor run in the app process. The sandbox limits the blast radius, but separate XPC services with narrower grants are planned before public release.
- Audit records aid diagnosis; they are not tamper-proof against a compromised Mac.
- Independent security review of credential handling, extraction and authorization is a release gate that has not happened yet.

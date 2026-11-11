import Foundation

/// Authorized Google Docs as live sources: identity, current content, freshness,
/// coverage and access loss handling (spec §6).
public final class CloudDocumentService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let search: SearchIndex
    private let auth: GoogleAuthService
    private let drive: GoogleDrive
    private let activity: ActivityLog

    public init(db: SQLiteDatabase, clock: Clock, search: SearchIndex, auth: GoogleAuthService, drive: GoogleDrive, activity: ActivityLog) {
        self.db = db; self.clock = clock; self.search = search; self.auth = auth; self.drive = drive; self.activity = activity
    }

    // MARK: Assets

    public func assets(accountID: UUID? = nil) -> [CloudAsset] {
        let rows: [SQLRow]
        if let accountID { rows = (try? db.query("SELECT * FROM cloud_assets WHERE account_id=? ORDER BY name", [accountID])) ?? [] }
        else { rows = (try? db.query("SELECT * FROM cloud_assets ORDER BY name")) ?? [] }
        return rows.compactMap(Self.decode)
    }

    public func asset(_ id: UUID) -> CloudAsset? {
        (try? db.queryOne("SELECT * FROM cloud_assets WHERE id=?", [id])).flatMap(Self.decode)
    }

    public func asset(accountID: UUID, fileID: String) -> CloudAsset? {
        (try? db.queryOne("SELECT * FROM cloud_assets WHERE account_id=? AND provider_file_id=?", [accountID, fileID])).flatMap(Self.decode)
    }

    public func setDisclosure(_ id: UUID, _ policy: DisclosurePolicy) throws {
        try db.execute("UPDATE cloud_assets SET disclosure=?, allowed_providers=? WHERE id=?",
                       [policy.mode.rawValue, try JSON.encode(policy.allowedProviders.map(\.rawValue).sorted()), id])
    }

    /// Adds a selected document by ID or pasted link. A link is a locator only:
    /// without authorization the user is routed to file selection.
    @discardableResult
    public func addDocument(accountID: UUID, locator: String) async throws -> CloudAsset {
        guard let fileID = GoogleLink.fileID(from: locator) else { throw CompanionError.invalidArgument("Not a Google Docs link or ID") }
        let file: DriveFile
        do { file = try await drive.file(fileID, accountID: accountID) }
        catch GoogleAPIClient.APIError.notFound, GoogleAPIClient.APIError.accessLost {
            throw CompanionError.permissionDenied("Companion is not authorized for this document. Select it with “Choose from Google Drive” to grant access.")
        }
        let asset = try upsert(accountID: accountID, file: file)
        if asset.isGoogleDoc { _ = try await refreshContent(asset.id) }
        activity.record(kind: "google", summary: "Added Google document \(file.name)")
        return self.asset(asset.id) ?? asset
    }

    /// Refreshes content if the version changed. Returns the new freshness.
    @discardableResult
    public func refreshContent(_ id: UUID, force: Bool = false) async throws -> Freshness {
        guard var asset = asset(id) else { throw CompanionError.notFound("document") }
        do {
            let file = try await drive.file(asset.providerFileID, accountID: asset.accountID)
            if file.trashed { try markUnavailable(id, reason: "in trash"); return .unavailable }
            let changed = force || file.version != asset.version || asset.retrievedAt == nil
            asset = try upsert(accountID: asset.accountID, file: file)
            if asset.isGoogleDoc && changed {
                let doc = try await drive.document(asset.providerFileID, accountID: asset.accountID)
                let parsed = GoogleDocParser().parse(doc)
                let segments = parsed.segments(assetID: id, version: parsed.revisionID)
                try search.replace(itemID: id, kind: .googleDoc, title: asset.name, segments: segments)
                try db.execute("UPDATE cloud_assets SET revision_id=?, coverage=?, retrieved_at=?, freshness='current' WHERE id=?",
                               [parsed.revisionID, try JSON.encode(parsed.coverage), clock.now(), id])
            } else {
                try db.execute("UPDATE cloud_assets SET retrieved_at=?, freshness='current' WHERE id=?", [clock.now(), id])
            }
            return .current
        } catch GoogleAPIClient.APIError.notFound, GoogleAPIClient.APIError.accessLost {
            try markUnavailable(id, reason: "access lost")
            return .unavailable
        } catch let e as CompanionError {
            if case .provider(.network, _) = e { try? db.execute("UPDATE cloud_assets SET freshness='cached' WHERE id=?", [id]); return .cached }
            throw e
        }
    }

    /// Permission loss immediately excludes the document from retrieval and model packets.
    public func markUnavailable(_ id: UUID, reason: String) throws {
        try search.remove(itemID: id)
        try db.execute("UPDATE cloud_assets SET freshness='unavailable', coverage=NULL WHERE id=?", [id])
        activity.record(kind: "google", initiator: "system", summary: "A Google document became unavailable (\(reason)); cached content purged")
    }

    /// Marks cached content stale when the app cannot reach Google (offline/wake).
    public func markAllCachedIfStale(olderThan seconds: TimeInterval) {
        try? db.execute("UPDATE cloud_assets SET freshness='stale' WHERE freshness='current' AND retrieved_at < ?",
                        [clock.now().addingTimeInterval(-seconds)])
    }

    // MARK: Change tracking

    /// Incremental refresh via Drive changes with a per-account cursor and bounded reconciliation.
    @discardableResult
    public func pollChanges(accountID: UUID) async throws -> Int {
        let known = Set(assets(accountID: accountID).map(\.providerFileID))
        guard let cursorRow = try db.queryOne("SELECT cursor FROM sync_cursors WHERE account_id=?", [accountID]),
              var token = cursorRow.string("cursor") else {
            let start = try await drive.startPageToken(accountID: accountID)
            try saveCursor(accountID, start, status: "ok")
            return 0
        }
        var updated = 0
        var pages = 0
        do {
            while pages < 20 {
                pages += 1
                let page = try await drive.changes(pageToken: token, accountID: accountID)
                for change in page.changes where known.contains(change.fileID) {
                    guard let a = asset(accountID: accountID, fileID: change.fileID) else { continue }
                    if change.removed || change.file?.trashed == true { try markUnavailable(a.id, reason: "removed"); continue }
                    if change.file?.version != a.version { _ = try await refreshContent(a.id); updated += 1 }
                }
                if let next = page.next { token = next; continue }
                if let newStart = page.newStart { token = newStart }
                break
            }
            try saveCursor(accountID, token, status: "ok")
        } catch GoogleAPIClient.APIError.http(let code, _) where code == 400 || code == 410 {
            // Invalid cursor: bounded reconciliation of known files, then a fresh cursor.
            for a in assets(accountID: accountID) { _ = try? await refreshContent(a.id) }
            try saveCursor(accountID, try await drive.startPageToken(accountID: accountID), status: "reconciled")
        }
        return updated
    }

    private func saveCursor(_ accountID: UUID, _ cursor: String, status: String) throws {
        try db.execute("""
            INSERT INTO sync_cursors(account_id, cursor, last_success, status, failures) VALUES(?,?,?,?,0)
            ON CONFLICT(account_id) DO UPDATE SET cursor=excluded.cursor, last_success=excluded.last_success, status=excluded.status, failures=0
            """, [accountID, cursor, clock.now(), status])
    }

    /// Purges all derived data for an account (used by disconnect).
    public func purge(accountID: UUID) throws {
        for a in assets(accountID: accountID) {
            try search.remove(itemID: a.id)
            try db.execute("DELETE FROM project_items WHERE kind='cloudDoc' AND target_id=?", [a.id])
        }
        try db.execute("DELETE FROM cloud_assets WHERE account_id=?", [accountID])
    }

    // MARK: Internals

    @discardableResult
    func upsert(accountID: UUID, file: DriveFile) throws -> CloudAsset {
        let existing = asset(accountID: accountID, fileID: file.id)
        let id = existing?.id ?? UUID()
        try db.execute("""
            INSERT INTO cloud_assets(id, account_id, provider_file_id, name, mime_type, canonical_url, parents, capabilities, version, modified_time, freshness)
            VALUES(?,?,?,?,?,?,?,?,?,?, 'unknown')
            ON CONFLICT(account_id, provider_file_id) DO UPDATE SET name=excluded.name, mime_type=excluded.mime_type,
                canonical_url=excluded.canonical_url, parents=excluded.parents, capabilities=excluded.capabilities,
                version=excluded.version, modified_time=excluded.modified_time
            """, [id, accountID, file.id, file.name, file.mimeType, file.webViewLink, try JSON.encode(file.parents),
                  try JSON.encode(file.capabilities), file.version, file.modifiedTime])
        guard let a = asset(id) else { throw CompanionError.database("Cloud asset not saved") }
        return a
    }

    static func decode(_ r: SQLRow) -> CloudAsset? {
        guard let id = r.uuid("id"), let account = r.uuid("account_id") else { return nil }
        let providers = (r.json("allowed_providers", as: [String].self) ?? []).compactMap(ProviderID.init(rawValue:))
        return CloudAsset(id: id, accountID: account, providerFileID: r.string("provider_file_id") ?? "", name: r.string("name") ?? "",
                          mimeType: r.string("mime_type") ?? "", canonicalURL: r.string("canonical_url"),
                          parents: r.json("parents", as: [String].self) ?? [], capabilities: r.json("capabilities", as: [String: Bool].self) ?? [:],
                          version: r.string("version"), revisionID: r.string("revision_id"), modifiedTime: r.date("modified_time"),
                          retrievedAt: r.date("retrieved_at"), freshness: Freshness(rawValue: r.string("freshness") ?? "") ?? .unknown,
                          coverage: r.json("coverage", as: ExtractionCoverage.self),
                          disclosure: DisclosurePolicy(mode: DisclosureMode(rawValue: r.string("disclosure") ?? "") ?? .askBeforeSending,
                                                       allowedProviders: Set(providers)))
    }
}

import Foundation

public struct ScanReport: Equatable, Sendable {
    public var added = 0, updated = 0, renamed = 0, removed = 0, unchanged = 0, skipped = 0
    public init() {}
}

/// Observes approved roots, keeps file identities stable across renames, and
/// feeds a background extraction queue into the encrypted search index.
public final class IndexingService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let search: SearchIndex
    private let clock: Clock
    public var extractor: TextExtractor
    public var ignore: IgnoreRules
    /// Files modified more recently than this are left pending until saves settle.
    public var stabilizationSeconds: TimeInterval
    private let activity: ActivityLog?

    public init(db: SQLiteDatabase, search: SearchIndex, clock: Clock, extractor: TextExtractor = .init(),
                ignore: IgnoreRules = .init(), stabilizationSeconds: TimeInterval = 3, activity: ActivityLog? = nil) {
        self.db = db; self.search = search; self.clock = clock; self.extractor = extractor
        self.ignore = ignore; self.stabilizationSeconds = stabilizationSeconds; self.activity = activity
    }

    // MARK: Roots

    @discardableResult
    public func addRoot(_ url: URL, bookmark: Data? = nil, extractContent: Bool = true,
                        disclosure: DisclosurePolicy = .init(), isProtected: Bool = false) throws -> Root {
        let path = PathGuard.canonical(url).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw CompanionError.notFound("Folder \(url.lastPathComponent)")
        }
        if let existing = roots().first(where: { $0.path == path }) { return existing }
        let root = Root(id: UUID(), path: path, bookmark: bookmark, extractContent: extractContent,
                        disclosure: disclosure, isProtected: isProtected, enabled: true, addedAt: clock.now(), lastScanAt: nil)
        try db.execute("""
            INSERT INTO roots(id, path, bookmark, extract_content, disclosure, allowed_providers, protected, enabled, added_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [root.id, root.path, root.bookmark, root.extractContent, root.disclosure.mode.rawValue,
                  try JSON.encode(root.disclosure.allowedProviders.map(\.rawValue).sorted()), root.isProtected, true, root.addedAt])
        activity?.record(kind: "source", summary: "Added folder \(url.lastPathComponent) for observation")
        return root
    }

    public func roots() -> [Root] {
        let rows = (try? db.query("SELECT * FROM roots ORDER BY added_at")) ?? []
        return rows.compactMap(Self.decodeRoot)
    }

    public func root(_ id: UUID) -> Root? {
        (try? db.queryOne("SELECT * FROM roots WHERE id = ?", [id])).flatMap(Self.decodeRoot)
    }

    public func updateRoot(_ root: Root) throws {
        try db.execute("""
            UPDATE roots SET extract_content=?, disclosure=?, allowed_providers=?, protected=?, enabled=? WHERE id=?
            """, [root.extractContent, root.disclosure.mode.rawValue,
                  try JSON.encode(root.disclosure.allowedProviders.map(\.rawValue).sorted()), root.isProtected, root.enabled, root.id])
    }

    /// Revoking a folder purges its derived data: assets, segments, search rows,
    /// project cards and pending context (spec §16).
    public func removeRoot(_ id: UUID) throws {
        try db.transaction {
            let assets = try db.query("SELECT id FROM file_assets WHERE root_id = ?", [id]).compactMap { $0.uuid("id") }
            for a in assets { try purgeAsset(a) }
            try db.execute("DELETE FROM roots WHERE id = ?", [id])
        }
        activity?.record(kind: "source", summary: "Removed a folder and purged its indexed data")
    }

    // MARK: Assets

    public func asset(_ id: UUID) -> FileAsset? {
        (try? db.queryOne("SELECT * FROM file_assets WHERE id = ?", [id])).flatMap(Self.decodeAsset)
    }

    public func asset(atPath path: String) -> FileAsset? {
        (try? db.queryOne("SELECT * FROM file_assets WHERE path = ?", [path])).flatMap(Self.decodeAsset)
    }

    public func assets(rootID: UUID? = nil, limit: Int = 10_000) -> [FileAsset] {
        let rows: [SQLRow]
        if let rootID { rows = (try? db.query("SELECT * FROM file_assets WHERE root_id = ? ORDER BY path LIMIT ?", [rootID, limit])) ?? [] }
        else { rows = (try? db.query("SELECT * FROM file_assets ORDER BY path LIMIT ?", [limit])) ?? [] }
        return rows.compactMap(Self.decodeAsset)
    }

    public func recentAssets(limit: Int = 20) -> [FileAsset] {
        let rows = (try? db.query("SELECT * FROM file_assets WHERE availability = 'available' ORDER BY modified_at DESC LIMIT ?", [limit])) ?? []
        return rows.compactMap(Self.decodeAsset)
    }

    public var pendingCount: Int { (try? db.scalarInt("SELECT COUNT(*) FROM file_assets WHERE index_status = 'pending'")) ?? 0 }

    /// Adds a dropped document as a reference (no copy). It may live outside roots
    /// because the user explicitly handed it to the app.
    @discardableResult
    public func addReference(_ url: URL, isManagedCopy: Bool = false) throws -> FileAsset {
        let c = PathGuard.canonical(url)
        guard FileManager.default.fileExists(atPath: c.path) else { throw CompanionError.notFound(url.lastPathComponent) }
        let rootID = roots().first(where: { PathGuard.isDescendant(c, of: $0.url) })?.id
        var r = ScanReport()
        let id = try upsert(url: c, rootID: rootID, report: &r, isManagedCopy: isManagedCopy)
        processPending(limit: 1, onlyID: id, ignoreStabilization: true)
        guard let a = asset(id) else { throw CompanionError.notFound(url.lastPathComponent) }
        return a
    }

    // MARK: Scanning

    @discardableResult
    public func scanAll() -> ScanReport {
        var total = ScanReport()
        for root in roots() where root.enabled {
            let r = scan(root)
            total.added += r.added; total.updated += r.updated; total.renamed += r.renamed
            total.removed += r.removed; total.unchanged += r.unchanged; total.skipped += r.skipped
        }
        return total
    }

    /// Reconciliation scan: events are hints, rescans repair missed changes.
    @discardableResult
    public func scan(_ root: Root) -> ScanReport {
        var report = ScanReport()
        let scanStart = clock.now()
        let rootURL = root.url
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return report }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true }) else { return report }
        var seen = Set<String>()
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { report.skipped += 1; continue }   // never traverse symlinks
            if values?.isDirectory == true {
                if ignore.isPackageDocument(url) {
                    enumerator.skipDescendants()
                    if let id = try? upsert(url: url, rootID: root.id, report: &report) { seen.insert(id.uuidString) }
                    continue
                }
                if ignore.shouldSkipDirectory(url) || values?.isPackage == true { enumerator.skipDescendants(); report.skipped += 1 }
                continue
            }
            if ignore.shouldSkipFile(url) { report.skipped += 1; continue }
            if let id = try? upsert(url: url, rootID: root.id, report: &report) { seen.insert(id.uuidString) }
        }
        // Anything in this root not seen is gone (or moved out of scope).
        let known = (try? db.query("SELECT id FROM file_assets WHERE root_id = ?", [root.id])) ?? []
        for row in known {
            guard let id = row.uuid("id"), !seen.contains(id.uuidString) else { continue }
            handleDisappeared(id)
            report.removed += 1
        }
        try? db.execute("UPDATE roots SET last_scan_at = ? WHERE id = ?", [scanStart, root.id])
        return report
    }

    /// Handles a single FSEvents path hint.
    public func reconcile(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let root = roots().first(where: { $0.enabled && PathGuard.isDescendant(url, of: $0.url) }) else {
            var r = ScanReport()
            if let a = asset(atPath: path), a.rootID == nil, !FileManager.default.fileExists(atPath: path) { handleDisappeared(a.id) }
            else if let a = asset(atPath: path), a.rootID == nil { _ = try? upsert(url: url, rootID: nil, report: &r, isManagedCopy: a.isManagedCopy) }
            return
        }
        var r = ScanReport()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                if ignore.isPackageDocument(url) { _ = try? upsert(url: url, rootID: root.id, report: &r) }
                return
            }
            if ignore.shouldSkipFile(url) || PathGuard.isSymlink(url) { return }
            // Skip if any ancestor directory is excluded.
            var parent = url.deletingLastPathComponent()
            while PathGuard.isDescendant(parent, of: root.url) && parent.path != root.path {
                if ignore.shouldSkipDirectory(parent) { return }
                parent = parent.deletingLastPathComponent()
            }
            _ = try? upsert(url: url, rootID: root.id, report: &r)
        } else if let a = asset(atPath: path) {
            handleDisappeared(a.id)
        } else {
            // A directory may have been removed/renamed: rescan its root.
            scan(root)
        }
    }

    // MARK: Extraction queue

    /// Extracts text for pending assets. Large files do not block the queue:
    /// size limits move them to `tooLarge` and the queue continues.
    @discardableResult
    public func processPending(limit: Int = 50, onlyID: UUID? = nil, ignoreStabilization: Bool = false) -> Int {
        let rows: [SQLRow]
        if let onlyID { rows = (try? db.query("SELECT * FROM file_assets WHERE id = ?", [onlyID])) ?? [] }
        else { rows = (try? db.query("SELECT * FROM file_assets WHERE index_status = 'pending' ORDER BY size ASC LIMIT ?", [limit])) ?? [] }
        var processed = 0
        let now = clock.now()
        for row in rows {
            guard var asset = Self.decodeAsset(row) else { continue }
            let url = asset.url
            if !ignoreStabilization, stabilizationSeconds > 0, let m = asset.modifiedAt, now.timeIntervalSince(m) < stabilizationSeconds { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { handleDisappeared(asset.id); continue }
            if Self.isCloudPlaceholder(url) {
                asset.indexStatus = .placeholder
                asset.availability = .cloudOnly
                save(asset, detail: "Download the file to index its contents")
                continue
            }
            let extractEnabled = asset.rootID.flatMap(root)?.extractContent ?? true
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let hash = isDir.boolValue ? nil : (try? Hashing.sha256Hex(fileAt: url))
            let extraction: Extraction
            if isDir.boolValue { extraction = .status(.metadataOnly, "Package document — open in its app") }
            else if !extractEnabled { extraction = .status(.metadataOnly, "Content extraction is off for this folder") }
            else if !extractor.canExtract(url) { extraction = .status(.unsupported) }
            else { extraction = extractor.extract(url) }

            let segments = SearchIndex.segment(extraction.sections, assetID: asset.id, kind: .localFile, version: hash)
            try? search.replace(itemID: asset.id, kind: .localFile, title: asset.name, segments: segments)
            asset.contentHash = hash
            asset.indexStatus = extraction.status
            asset.lastIndexedAt = now
            let detail = [extraction.detail, extraction.omissions.isEmpty ? nil : "Not extracted: " + extraction.omissions.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: ". ")
            save(asset, detail: detail.isEmpty ? nil : detail)
            if let hash {
                let latest = try? db.queryOne("SELECT content_hash FROM file_versions WHERE asset_id = ? ORDER BY observed_at DESC LIMIT 1", [asset.id])
                if latest?.string("content_hash") != hash {
                    try? db.execute("INSERT INTO file_versions(id, asset_id, content_hash, observed_at, extraction_version) VALUES(?,?,?,?,?)",
                                    [UUID(), asset.id, hash, now, TextExtractor.version])
                }
            }
            processed += 1
        }
        return processed
    }

    // MARK: Internals

    @discardableResult
    private func upsert(url: URL, rootID: UUID?, report: inout ScanReport, isManagedCopy: Bool = false) throws -> UUID {
        let path = url.standardizedFileURL.path
        let meta = Self.metadata(url)
        let now = clock.now()
        if let existing = asset(atPath: path) {
            if existing.size != meta.size || existing.modifiedAt?.timeIntervalSince1970.rounded() != meta.modified?.timeIntervalSince1970.rounded()
                || existing.availability != .available {
                try db.execute("""
                    UPDATE file_assets SET size=?, modified_at=?, resource_identity=?, availability='available',
                        index_status='pending', last_seen_at=?, root_id=? WHERE id=?
                    """, [meta.size, meta.modified, meta.identity, now, rootID ?? existing.rootID, existing.id])
                report.updated += 1
            } else {
                try db.execute("UPDATE file_assets SET last_seen_at=? WHERE id=?", [now, existing.id])
                report.unchanged += 1
            }
            return existing.id
        }
        // Rename/move detection by stable resource identity.
        if let identity = meta.identity,
           let moved = try db.queryOne("SELECT * FROM file_assets WHERE resource_identity = ?", [identity]).flatMap(Self.decodeAsset),
           !FileManager.default.fileExists(atPath: moved.path) {
            try db.execute("""
                UPDATE file_assets SET path=?, name=?, ext=?, root_id=?, size=?, modified_at=?, availability='available',
                    last_seen_at=?, index_status = CASE WHEN modified_at = ? THEN index_status ELSE 'pending' END WHERE id=?
                """, [path, url.lastPathComponent, url.pathExtension.lowercased(), rootID, meta.size, meta.modified, now, meta.modified, moved.id])
            try search.replaceTitle(itemID: moved.id, title: url.lastPathComponent)
            report.renamed += 1
            return moved.id
        }
        let id = UUID()
        try db.execute("""
            INSERT INTO file_assets(id, root_id, path, name, ext, size, modified_at, resource_identity, availability,
                index_status, is_managed_copy, tags, first_seen_at, last_seen_at)
            VALUES(?,?,?,?,?,?,?,?,'available','pending',?,?,?,?)
            """, [id, rootID, path, url.lastPathComponent, url.pathExtension.lowercased(), meta.size, meta.modified,
                  meta.identity, isManagedCopy, try JSON.encode(meta.tags), now, now])
        report.added += 1
        return id
    }

    private func handleDisappeared(_ id: UUID) {
        let referenced = ((try? db.scalarInt("SELECT COUNT(*) FROM project_items WHERE kind='file' AND target_id=?", [id])) ?? 0) > 0
        if referenced {
            // Keep the card honest: it now points to a missing file.
            try? db.execute("UPDATE file_assets SET availability='missing' WHERE id=?", [id])
            try? search.remove(itemID: id)
        } else {
            try? purgeAsset(id)
        }
    }

    private func purgeAsset(_ id: UUID) throws {
        try search.remove(itemID: id)
        try db.execute("DELETE FROM project_items WHERE kind='file' AND target_id=?", [id])
        try db.execute("DELETE FROM file_assets WHERE id=?", [id])
    }

    private func save(_ a: FileAsset, detail: String?) {
        try? db.execute("""
            UPDATE file_assets SET content_hash=?, index_status=?, index_detail=?, availability=?, last_indexed_at=? WHERE id=?
            """, [a.contentHash, a.indexStatus.rawValue, detail, a.availability.rawValue, a.lastIndexedAt, a.id])
    }

    struct FileMeta { var size: Int; var modified: Date?; var identity: String?; var tags: [String] }

    static func metadata(_ url: URL) -> FileMeta {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .tagNamesKey])
        var st = stat()
        let identity = stat(url.path, &st) == 0 ? "\(st.st_dev):\(st.st_ino)" : nil
        return FileMeta(size: values?.fileSize ?? 0, modified: values?.contentModificationDate,
                        identity: identity, tags: values?.tagNames ?? [])
    }

    static func isCloudPlaceholder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true else { return false }
        return v.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    static func decodeRoot(_ r: SQLRow) -> Root? {
        guard let id = r.uuid("id"), let path = r.string("path"), let added = r.date("added_at") else { return nil }
        let providers = (r.json("allowed_providers", as: [String].self) ?? []).compactMap(ProviderID.init(rawValue:))
        return Root(id: id, path: path, bookmark: r.data("bookmark"), extractContent: r.bool("extract_content"),
                    disclosure: DisclosurePolicy(mode: DisclosureMode(rawValue: r.string("disclosure") ?? "") ?? .askBeforeSending,
                                                 allowedProviders: Set(providers)),
                    isProtected: r.bool("protected"), enabled: r.bool("enabled"), addedAt: added, lastScanAt: r.date("last_scan_at"))
    }

    static func decodeAsset(_ r: SQLRow) -> FileAsset? {
        guard let id = r.uuid("id"), let path = r.string("path") else { return nil }
        return FileAsset(id: id, rootID: r.uuid("root_id"), path: path, name: r.string("name") ?? "", ext: r.string("ext") ?? "",
                         size: r.int("size") ?? 0, modifiedAt: r.date("modified_at"), resourceIdentity: r.string("resource_identity"),
                         contentHash: r.string("content_hash"),
                         availability: Availability(rawValue: r.string("availability") ?? "") ?? .available,
                         indexStatus: IndexStatus(rawValue: r.string("index_status") ?? "") ?? .pending,
                         indexDetail: r.string("index_detail"), isManagedCopy: r.bool("is_managed_copy"),
                         tags: r.json("tags", as: [String].self) ?? [], lastSeenAt: r.date("last_seen_at") ?? Date(),
                         lastIndexedAt: r.date("last_indexed_at"))
    }
}

extension SearchIndex {
    func replaceTitle(itemID: UUID, title: String) throws {
        // Rebuild with existing segments so the new name is searchable.
        let segs = segments(for: itemID)
        try replace(itemID: itemID, kind: kind(of: itemID) ?? .localFile, title: title, segments: segs.map {
            DocumentSegment(id: UUID(), assetID: $0.assetID, sourceKind: $0.sourceKind, tabID: $0.tabID, sourceVersion: $0.sourceVersion,
                            heading: $0.heading, startIndex: $0.startIndex, endIndex: $0.endIndex, ordinal: $0.ordinal, text: $0.text)
        })
    }
}

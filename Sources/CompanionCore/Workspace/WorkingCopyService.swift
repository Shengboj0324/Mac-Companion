import Foundation

/// Working copies live in a user-visible managed folder. Copy → verify → atomic
/// publish, unique names, never an implicit overwrite (spec §5).
public final class WorkingCopyService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    public let managedRoot: URL
    private let indexing: IndexingService
    private let activity: ActivityLog

    public init(db: SQLiteDatabase, clock: Clock, managedRoot: URL, indexing: IndexingService, activity: ActivityLog) {
        self.db = db; self.clock = clock; self.managedRoot = managedRoot; self.indexing = indexing; self.activity = activity
        indexing.ignore.managedDirectories = [PathGuard.canonical(managedRoot).path]
    }

    public func folder(for project: Project?) -> URL {
        let name = project.map { Self.safeFolderName($0.name) } ?? "Unfiled"
        return managedRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Copies `source` into `destinationFolder` (inside the managed root or an
    /// approved destination). Returns the verified working copy record.
    @discardableResult
    public func createCopy(of source: URL, into destinationFolder: URL, projectID: UUID?, ruleID: UUID? = nil) throws -> WorkingCopy {
        let fm = FileManager.default
        let src = PathGuard.canonical(source)
        guard fm.fileExists(atPath: src.path) else { throw CompanionError.notFound(source.lastPathComponent) }
        try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let baseHash = try Hashing.sha256Hex(fileAt: src)
        let destination = Self.uniqueDestination(for: src.lastPathComponent, in: destinationFolder)

        // Copy to a temporary sibling, verify, then publish atomically without overwrite.
        let temp = destinationFolder.appendingPathComponent(".companion-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: src, to: temp)
        let copyHash = try Hashing.sha256Hex(fileAt: temp)
        guard copyHash == baseHash else { throw CompanionError.outcomeUnknown("Copy verification failed") }
        try Self.publishNoOverwrite(temp, to: destination)

        let wc = WorkingCopy(id: UUID(), projectID: projectID, sourceAssetID: indexing.asset(atPath: src.path)?.id,
                             sourcePath: src.path, baseHash: baseHash, copyPath: PathGuard.canonical(destination).path,
                             copyHash: copyHash, createdAt: clock.now(), state: .current, ruleID: ruleID)
        try db.execute("""
            INSERT INTO working_copies(id, project_id, source_asset_id, source_path, base_hash, copy_path, copy_hash, created_at, state, rule_id)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [wc.id, projectID, wc.sourceAssetID, wc.sourcePath, baseHash, wc.copyPath, copyHash, wc.createdAt, wc.state.rawValue, ruleID])
        _ = try? indexing.addReference(URL(fileURLWithPath: wc.copyPath), isManagedCopy: true)
        activity.record(kind: "copy", initiator: ruleID == nil ? "user" : "copy rule",
                        summary: "Created working copy \(destination.lastPathComponent)")
        return wc
    }

    public func all(projectID: UUID? = nil) -> [WorkingCopy] {
        let rows: [SQLRow]
        if let projectID { rows = (try? db.query("SELECT * FROM working_copies WHERE project_id=? ORDER BY created_at DESC", [projectID])) ?? [] }
        else { rows = (try? db.query("SELECT * FROM working_copies ORDER BY created_at DESC")) ?? [] }
        return rows.compactMap(Self.decode)
    }

    public func copy(_ id: UUID) -> WorkingCopy? {
        (try? db.queryOne("SELECT * FROM working_copies WHERE id=?", [id])).flatMap(Self.decode)
    }

    /// Detects divergence: changed source → stale badge; both changed → conflict.
    @discardableResult
    public func refreshState(_ id: UUID) -> WorkingCopyState? {
        guard var wc = copy(id) else { return nil }
        let fm = FileManager.default
        let state: WorkingCopyState
        if !fm.fileExists(atPath: wc.sourcePath) { state = .sourceMissing }
        else {
            let sourceHash = (try? Hashing.sha256Hex(fileAt: URL(fileURLWithPath: wc.sourcePath))) ?? wc.baseHash
            let copyHash = (try? Hashing.sha256Hex(fileAt: URL(fileURLWithPath: wc.copyPath))) ?? wc.copyHash
            let sourceChanged = sourceHash != wc.baseHash
            let copyChanged = copyHash != wc.baseHash
            switch (sourceChanged, copyChanged) {
            case (false, false): state = .current
            case (true, false): state = .sourceChanged
            case (false, true): state = .copyChanged
            case (true, true): state = .conflict
            }
        }
        wc.state = state
        try? db.execute("UPDATE working_copies SET state=? WHERE id=?", [state.rawValue, id])
        return state
    }

    /// "Keep both": refresh from the current source into a new, separate copy.
    @discardableResult
    public func keepBoth(_ id: UUID) throws -> WorkingCopy {
        guard let wc = copy(id) else { throw CompanionError.notFound("working copy") }
        return try createCopy(of: URL(fileURLWithPath: wc.sourcePath),
                              into: URL(fileURLWithPath: wc.copyPath).deletingLastPathComponent(), projectID: wc.projectID)
    }

    /// Stops tracking a copy record. The file in the managed folder stays on disk.
    public func forget(_ id: UUID) throws { try db.execute("DELETE FROM working_copies WHERE id=?", [id]) }

    // MARK: Helpers

    public static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    /// Atomic publish that fails instead of replacing an existing file.
    public static func publishNoOverwrite(_ temp: URL, to destination: URL) throws {
        let rc = temp.path.withCString { src in destination.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) } }
        if rc != 0 {
            if errno == EEXIST { throw CompanionError.collision(destination.lastPathComponent) }
            throw CompanionError.database("Publish failed (\(errno))")
        }
    }

    static func safeFolderName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Project" : cleaned
    }

    static func decode(_ r: SQLRow) -> WorkingCopy? {
        guard let id = r.uuid("id"), let created = r.date("created_at") else { return nil }
        return WorkingCopy(id: id, projectID: r.uuid("project_id"), sourceAssetID: r.uuid("source_asset_id"),
                           sourcePath: r.string("source_path") ?? "", baseHash: r.string("base_hash") ?? "",
                           copyPath: r.string("copy_path") ?? "", copyHash: r.string("copy_hash") ?? "", createdAt: created,
                           state: WorkingCopyState(rawValue: r.string("state") ?? "") ?? .current, ruleID: r.uuid("rule_id"))
    }
}

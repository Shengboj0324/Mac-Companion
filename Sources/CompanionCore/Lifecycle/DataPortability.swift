import Foundation

/// Export, encrypted-at-rest-friendly backups, single-instance guard and the
/// "Prepare to uninstall" flow (spec §16, §18).
public final class DataPortability: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let paths: AppPaths
    private let settings: SettingsStore
    private let memory: MemoryService
    private let projects: ProjectService
    private let filing: FilingProfileService
    private let providers: ProviderRegistry
    private let activity: ActivityLog

    init(db: SQLiteDatabase, clock: Clock, paths: AppPaths, settings: SettingsStore, memory: MemoryService, projects: ProjectService,
         filing: FilingProfileService, providers: ProviderRegistry, activity: ActivityLog) {
        self.db = db; self.clock = clock; self.paths = paths; self.settings = settings; self.memory = memory
        self.projects = projects; self.filing = filing; self.providers = providers; self.activity = activity
    }

    public struct ExportManifest: Codable, Sendable {
        public let formatVersion: Int
        public let schemaVersion: Int
        public let exportedAt: Date
        public let includesManagedFiles: Bool
        public let contents: [String]
    }

    /// Writes a versioned export folder: manifest, notes/checkpoints, memories with
    /// provenance, project memberships, canonical source references and the filing
    /// profile. Secrets are never included.
    @discardableResult
    public func export(to folder: URL? = nil, includeManagedFiles: Bool = false) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: clock.now()).replacingOccurrences(of: ":", with: "-")
        let dir = (folder ?? paths.exports).appendingPathComponent("Companion Export \(stamp)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        struct ProjectExport: Encodable {
            let project: Project
            let items: [ProjectItem]
            let checkpoints: [Checkpoint]
            let sources: [SourceRef]
        }
        let projectExports = projects.all(includeArchived: true).map { p -> ProjectExport in
            let items = projects.items(projectID: p.id)
            let sources: [SourceRef] = items.compactMap { item in
                switch item.kind {
                case .file:
                    guard let r = try? db.queryOne("SELECT path, name, content_hash FROM file_assets WHERE id=?", [item.targetID]) else { return nil }
                    return SourceRef(kind: .localFile, id: item.targetID.uuidString, title: r.string("name") ?? "", locator: r.string("path"), version: r.string("content_hash"))
                case .cloudDoc:
                    guard let r = try? db.queryOne("SELECT provider_file_id, name, canonical_url FROM cloud_assets WHERE id=?", [item.targetID]) else { return nil }
                    return SourceRef(kind: .googleDoc, id: r.string("provider_file_id") ?? "", title: r.string("name") ?? "", locator: r.string("canonical_url"))
                default: return nil
                }
            }
            return ProjectExport(project: p, items: items, checkpoints: projects.checkpoints(projectID: p.id, limit: 10_000), sources: sources)
        }
        try JSON.prettyEncoder.encode(projectExports).write(to: dir.appendingPathComponent("projects.json"))
        try memory.export().write(to: dir.appendingPathComponent("memories.json"))
        try filing.export().write(to: dir.appendingPathComponent("filing-profile.json"))
        var contents = ["projects.json", "memories.json", "filing-profile.json"]
        if includeManagedFiles, fm.fileExists(atPath: paths.managedWorkspaces.path) {
            try fm.copyItem(at: paths.managedWorkspaces, to: dir.appendingPathComponent("Companion Workspaces"))
            contents.append("Companion Workspaces/")
        }
        let manifest = ExportManifest(formatVersion: 1, schemaVersion: Schema.currentVersion, exportedAt: clock.now(),
                                      includesManagedFiles: includeManagedFiles, contents: contents)
        try JSON.prettyEncoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        activity.record(kind: "export", summary: "Exported projects, memories and filing profile")
        return dir
    }

    /// Consistent database backup (metadata + memory). Restore requires renewed grants and keys.
    @discardableResult
    public func backupDatabase() throws -> URL {
        let url = paths.backups.appendingPathComponent("companion-\(Int(clock.now().timeIntervalSince1970)).sqlite")
        try db.backup(to: url)
        return url
    }

    /// What "Remove app data" would delete — shown as an exact preview first.
    public func appDataRemovalPreview() -> [URL] {
        let fm = FileManager.default
        let db = paths.database.path
        return [URL(fileURLWithPath: db), URL(fileURLWithPath: db + "-wal"), URL(fileURLWithPath: db + "-shm"),
                paths.backups, paths.recovery, paths.exports]
            .filter { fm.fileExists(atPath: $0.path) }
    }

    public struct UninstallReport: Sendable {
        public var unresolvedActions: Int
        public var exportedTo: URL?
        public var removedProviderKeys: [ProviderID]
        public var notes: [String]
    }

    /// Prepare to uninstall: pause, report unresolved actions, export, unregister
    /// login launch (done by the app layer), remove provider keys if requested.
    /// Source files, Google documents and working folders are never deleted.
    public func prepareToUninstall(exportFirst: Bool, removeProviderKeys: Bool) throws -> UninstallReport {
        settings.set(Settings.paused, true)
        let unresolved = try db.scalarInt("SELECT COUNT(*) FROM action_runs WHERE state IN ('approved','validating','executing','verifying','outcomeUnknown')")
        var report = UninstallReport(unresolvedActions: unresolved, exportedTo: nil, removedProviderKeys: [], notes: [])
        if exportFirst { report.exportedTo = try export() }
        if removeProviderKeys {
            for p in ProviderID.allCases where providers.hasKey(p) { try providers.removeKey(p); report.removedProviderKeys.append(p) }
        }
        report.notes = [
            "Your files, Google documents and “Companion Workspaces” folder are not deleted.",
            "Disconnect Google in Settings to revoke Companion's access, or revoke it at myaccount.google.com/permissions.",
            "Keys already sent to providers and data at providers follow those providers' retention policies.",
        ]
        activity.record(kind: "app", summary: "Prepared to uninstall")
        return report
    }

    /// Deletes only app-owned data listed by `appDataRemovalPreview()`.
    public func removeAppData() throws {
        db.close()
        for url in appDataRemovalPreview() { try FileManager.default.removeItem(at: url) }
    }
}

/// Prevents two running instances from competing over one database.
public final class SingleInstanceLock: @unchecked Sendable {
    private var fd: Int32 = -1
    public init() {}

    public func acquire(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); fd = -1; return false }
        return true
    }

    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

import Foundation

/// Projects, workspace cards (references/copies/cloud docs/events) and resume checkpoints.
/// Removing a card never deletes the underlying file (spec §5).
public final class ProjectService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore
    private let search: SearchIndex
    private let activity: ActivityLog

    public init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore, search: SearchIndex, activity: ActivityLog) {
        self.db = db; self.clock = clock; self.settings = settings; self.search = search; self.activity = activity
    }

    // MARK: Projects

    @discardableResult
    public func create(name: String, disclosure: DisclosurePolicy = .init(), defaultProvider: ProviderID? = nil) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CompanionError.invalidArgument("Project name is empty") }
        let p = Project(name: trimmed, defaultProvider: defaultProvider, disclosure: disclosure, createdAt: clock.now())
        try db.execute("""
            INSERT INTO projects(id, name, active, default_provider, disclosure, allowed_providers, notes, created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [p.id, p.name, true, p.defaultProvider?.rawValue, p.disclosure.mode.rawValue,
                  try JSON.encode(p.disclosure.allowedProviders.map(\.rawValue).sorted()), p.notes, p.createdAt])
        activity.record(kind: "project", summary: "Created project \(p.name)")
        return p
    }

    public func update(_ p: Project) throws {
        try db.execute("""
            UPDATE projects SET name=?, active=?, default_provider=?, disclosure=?, allowed_providers=?, notes=?,
                last_opened_at=?, snoozed_until=? WHERE id=?
            """, [p.name, p.active, p.defaultProvider?.rawValue, p.disclosure.mode.rawValue,
                  try JSON.encode(p.disclosure.allowedProviders.map(\.rawValue).sorted()), p.notes,
                  p.lastOpenedAt, p.snoozedUntil, p.id])
    }

    public func delete(_ id: UUID) throws {
        // Removes the virtual project and its cards only; files are untouched.
        try db.execute("DELETE FROM projects WHERE id=?", [id])
        try db.execute("DELETE FROM memories WHERE project_id=?", [id])
        if settings.get(Settings.lastActiveProject) == id.uuidString { settings.set(Settings.lastActiveProject, nil) }
        activity.record(kind: "project", summary: "Deleted a project (files were not changed)")
    }

    public func all(includeArchived: Bool = false) -> [Project] {
        let sql = includeArchived ? "SELECT * FROM projects ORDER BY COALESCE(last_opened_at, created_at) DESC"
                                  : "SELECT * FROM projects WHERE active = 1 ORDER BY COALESCE(last_opened_at, created_at) DESC"
        return ((try? db.query(sql)) ?? []).compactMap(Self.decode)
    }

    public func project(_ id: UUID) -> Project? {
        (try? db.queryOne("SELECT * FROM projects WHERE id=?", [id])).flatMap(Self.decode)
    }

    public func markOpened(_ id: UUID) {
        try? db.execute("UPDATE projects SET last_opened_at=? WHERE id=?", [clock.now(), id])
        settings.set(Settings.lastActiveProject, id.uuidString)
    }

    public var lastActive: Project? {
        if let s = settings.get(Settings.lastActiveProject), let id = UUID(uuidString: s), let p = project(id) { return p }
        return all().first
    }

    // MARK: Cards

    @discardableResult
    public func addItem(projectID: UUID, kind: ItemKind, targetID: UUID, mode: FileMode = .reference,
                        reason: String? = nil, confirmed: Bool = true) throws -> ProjectItem {
        if let existing = items(projectID: projectID).first(where: { $0.kind == kind && $0.targetID == targetID }) { return existing }
        let item = ProjectItem(id: UUID(), projectID: projectID, kind: kind, targetID: targetID, mode: mode,
                               reason: reason, confirmed: confirmed, addedAt: clock.now())
        try db.execute("""
            INSERT INTO project_items(id, project_id, kind, target_id, mode, reason, confirmed, added_at) VALUES(?,?,?,?,?,?,?,?)
            """, [item.id, projectID, kind.rawValue, targetID, mode.rawValue, reason, confirmed, item.addedAt])
        return item
    }

    public func confirmItem(_ id: UUID) throws { try db.execute("UPDATE project_items SET confirmed=1 WHERE id=?", [id]) }

    /// Removes the card only. The underlying file or document is never deleted.
    public func removeItem(_ id: UUID) throws { try db.execute("DELETE FROM project_items WHERE id=?", [id]) }

    public func items(projectID: UUID) -> [ProjectItem] {
        ((try? db.query("SELECT * FROM project_items WHERE project_id=? ORDER BY added_at DESC", [projectID])) ?? []).compactMap(Self.decodeItem)
    }

    public func projects(containing targetID: UUID) -> [Project] {
        ((try? db.query("SELECT p.* FROM projects p JOIN project_items i ON i.project_id = p.id WHERE i.target_id = ?", [targetID])) ?? [])
            .compactMap(Self.decode)
    }

    // MARK: Checkpoints

    @discardableResult
    public func saveCheckpoint(projectID: UUID, note: String, nextStep: String? = nil, sources: [SourceRef] = []) throws -> Checkpoint {
        let cp = Checkpoint(id: UUID(), projectID: projectID, note: note, nextStep: nextStep, sourceRefs: sources, createdAt: clock.now())
        try db.execute("INSERT INTO checkpoints(id, project_id, note, next_step, source_refs, created_at) VALUES(?,?,?,?,?,?)",
                       [cp.id, projectID, note, nextStep, try JSON.encode(sources), cp.createdAt])
        let seg = DocumentSegment(id: UUID(), assetID: cp.id, sourceKind: .user, tabID: nil, sourceVersion: nil, heading: nil,
                                  startIndex: nil, endIndex: nil, ordinal: 0, text: [note, nextStep].compactMap { $0 }.joined(separator: "\n"))
        try search.replace(itemID: cp.id, kind: .checkpoint, title: "Checkpoint", segments: [seg])
        markOpened(projectID)
        activity.record(kind: "checkpoint", summary: "Saved a resume checkpoint")
        return cp
    }

    public func checkpoints(projectID: UUID, limit: Int = 20) -> [Checkpoint] {
        let rows = (try? db.query("SELECT * FROM checkpoints WHERE project_id=? ORDER BY created_at DESC LIMIT ?", [projectID, limit])) ?? []
        return rows.compactMap { r in
            guard let id = r.uuid("id"), let date = r.date("created_at") else { return nil }
            return Checkpoint(id: id, projectID: projectID, note: r.string("note") ?? "", nextStep: r.string("next_step"),
                              sourceRefs: r.json("source_refs", as: [SourceRef].self) ?? [], createdAt: date)
        }
    }

    public func latestCheckpoint(projectID: UUID) -> Checkpoint? { checkpoints(projectID: projectID, limit: 1).first }

    // MARK: Decoding

    static func decode(_ r: SQLRow) -> Project? {
        guard let id = r.uuid("id"), let created = r.date("created_at") else { return nil }
        let providers = (r.json("allowed_providers", as: [String].self) ?? []).compactMap(ProviderID.init(rawValue:))
        return Project(id: id, name: r.string("name") ?? "", active: r.bool("active"),
                       defaultProvider: r.string("default_provider").flatMap(ProviderID.init(rawValue:)),
                       disclosure: DisclosurePolicy(mode: DisclosureMode(rawValue: r.string("disclosure") ?? "") ?? .askBeforeSending,
                                                    allowedProviders: Set(providers)),
                       notes: r.string("notes") ?? "", createdAt: created, lastOpenedAt: r.date("last_opened_at"),
                       snoozedUntil: r.date("snoozed_until"))
    }

    static func decodeItem(_ r: SQLRow) -> ProjectItem? {
        guard let id = r.uuid("id"), let pid = r.uuid("project_id"), let target = r.uuid("target_id"),
              let kind = ItemKind(rawValue: r.string("kind") ?? ""), let added = r.date("added_at") else { return nil }
        return ProjectItem(id: id, projectID: pid, kind: kind, targetID: target,
                           mode: FileMode(rawValue: r.string("mode") ?? "") ?? .reference, reason: r.string("reason"),
                           confirmed: r.bool("confirmed"), addedAt: added)
    }
}

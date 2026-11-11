import Foundation

/// Application-owned, inspectable, source-backed memory shared by every provider (spec §10).
public final class MemoryService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let search: SearchIndex
    private let activity: ActivityLog

    public init(db: SQLiteDatabase, clock: Clock, search: SearchIndex, activity: ActivityLog) {
        self.db = db; self.clock = clock; self.search = search; self.activity = activity
    }

    // MARK: Create / update

    /// Adds a memory. Returns nil when a tombstone blocks an automatic re-creation
    /// of a forgotten fact. User-confirmed additions clear the tombstone.
    @discardableResult
    public func add(_ record: MemoryRecord) throws -> MemoryRecord? {
        let fp = Self.fingerprint(record.statement, projectID: record.projectID)
        if record.provenance != .userConfirmed,
           (try db.scalarInt("SELECT COUNT(*) FROM memory_tombstones WHERE fingerprint=?", [fp])) > 0 {
            return nil
        }
        if record.provenance == .userConfirmed { try db.execute("DELETE FROM memory_tombstones WHERE fingerprint=?", [fp]) }
        var r = record
        // Exact duplicate → return existing.
        if let dup = all(projectID: record.projectID, includeGlobal: false).first(where: {
            Self.normalize($0.statement) == Self.normalize(record.statement) && $0.kind == record.kind }) {
            return dup
        }
        // Conflicting statements stay visible until resolved; the newest never silently wins.
        if r.provenance != .userConfirmed, r.supersedes == nil, r.status == .active {
            let conflicts = all(projectID: record.projectID, includeGlobal: false).filter {
                $0.kind == r.kind && $0.status == .active && Self.likelyConflict($0.statement, r.statement)
            }
            if !conflicts.isEmpty {
                r.status = .conflicted
                for c in conflicts { try db.execute("UPDATE memories SET status='conflicted' WHERE id=?", [c.id]) }
            }
        }
        try insert(r)
        if let s = r.supersedes { try db.execute("UPDATE memories SET status='superseded' WHERE id=?", [s]) }
        activity.record(kind: "memory", initiator: r.provenance == .aiInference ? "model proposal" : "user",
                        summary: "Remembered (\(r.kind.label)): \(r.statement.prefix(80))")
        return r
    }

    public func edit(_ id: UUID, statement: String) throws {
        guard var r = memory(id) else { throw CompanionError.notFound("memory") }
        r.statement = statement
        r.provenance = .userConfirmed
        r.status = .active
        r.observedAt = clock.now()
        try save(r)
    }

    /// Confirming promotes a proposal/inference to a user-confirmed fact. Any
    /// active statement it contradicts is marked conflicted for the user to resolve.
    public func confirm(_ id: UUID) throws {
        guard let r = memory(id) else { throw CompanionError.notFound("memory") }
        try db.execute("UPDATE memories SET provenance='userConfirmed', status='active' WHERE id=?", [id])
        let rivals = all(projectID: r.projectID, includeGlobal: false).filter {
            $0.id != id && $0.kind == r.kind && $0.status == .active && Self.likelyConflict($0.statement, r.statement)
        }
        for c in rivals { try db.execute("UPDATE memories SET status='conflicted' WHERE id IN (?, ?)", [c.id, id]) }
    }

    public func setProviders(_ id: UUID, _ providers: Set<ProviderID>, sensitivity: Sensitivity) throws {
        try db.execute("UPDATE memories SET allowed_providers=?, sensitivity=? WHERE id=?",
                       [try JSON.encode(providers.map(\.rawValue).sorted()), sensitivity.rawValue, id])
    }

    /// Keeps `keep`, supersedes the others in its conflict set.
    public func resolveConflict(keep: UUID, supersede others: [UUID]) throws {
        try db.transaction {
            try db.execute("UPDATE memories SET status='active' WHERE id=?", [keep])
            for o in others where o != keep { try db.execute("UPDATE memories SET status='superseded' WHERE id=?", [o]) }
        }
    }

    /// Forget removes the record and its search entries and leaves a tombstone so
    /// routine reindexing does not immediately recreate it.
    public func forget(_ id: UUID) throws {
        guard let r = memory(id) else { return }
        try db.transaction {
            try db.execute("DELETE FROM memories WHERE id=?", [id])
            try db.execute("INSERT OR REPLACE INTO memory_tombstones(fingerprint, forgotten_at) VALUES(?,?)",
                           [Self.fingerprint(r.statement, projectID: r.projectID), clock.now()])
            try search.remove(itemID: id)
        }
        activity.record(kind: "memory", summary: "Forgot a memory (already-sent copies at providers are not recalled)")
    }

    // MARK: Read

    public func memory(_ id: UUID) -> MemoryRecord? {
        (try? db.queryOne("SELECT * FROM memories WHERE id=?", [id])).flatMap(Self.decode)
    }

    public func all(projectID: UUID? = nil, includeGlobal: Bool = true, includeSuperseded: Bool = false) -> [MemoryRecord] {
        var sql = "SELECT * FROM memories WHERE 1=1"
        var params: [SQLConvertible] = []
        if let projectID {
            sql += includeGlobal ? " AND (project_id = ? OR project_id IS NULL)" : " AND project_id = ?"
            params.append(projectID)
        } else if !includeGlobal {
            sql += " AND project_id IS NULL"
        }
        if !includeSuperseded { sql += " AND status != 'superseded'" }
        sql += " ORDER BY observed_at DESC"
        let now = clock.now()
        return ((try? db.query(sql, params)) ?? []).compactMap(Self.decode).filter { ($0.expiresAt ?? .distantFuture) > now }
    }

    public var conflicts: [MemoryRecord] {
        ((try? db.query("SELECT * FROM memories WHERE status='conflicted' ORDER BY observed_at DESC")) ?? []).compactMap(Self.decode)
    }

    public func expireSessionContext() {
        try? db.execute("DELETE FROM memories WHERE expires_at IS NOT NULL AND expires_at < ?", [clock.now()])
    }

    /// Exports memories with provenance (no secrets).
    public func export() throws -> Data {
        struct Export: Encodable { let version: Int; let exportedAt: Date; let memories: [MemoryRecord] }
        return try JSON.prettyEncoder.encode(Export(version: 1, exportedAt: clock.now(), memories: all(includeSuperseded: true)))
    }

    // MARK: Internals

    private func insert(_ r: MemoryRecord) throws {
        try db.execute("""
            INSERT INTO memories(id, project_id, kind, statement, provenance, source_ref, observed_at, status, sensitivity,
                allowed_providers, supersedes, expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [r.id, r.projectID, r.kind.rawValue, r.statement, r.provenance.rawValue,
                  try r.sourceRef.map { try JSON.encode($0) }, r.observedAt, r.status.rawValue, r.sensitivity.rawValue,
                  try JSON.encode(r.allowedProviders.map(\.rawValue).sorted()), r.supersedes, r.expiresAt])
        try index(r)
    }

    private func save(_ r: MemoryRecord) throws {
        try db.execute("""
            UPDATE memories SET statement=?, provenance=?, status=?, observed_at=?, sensitivity=?, allowed_providers=? WHERE id=?
            """, [r.statement, r.provenance.rawValue, r.status.rawValue, r.observedAt, r.sensitivity.rawValue,
                  try JSON.encode(r.allowedProviders.map(\.rawValue).sorted()), r.id])
        try index(r)
    }

    private func index(_ r: MemoryRecord) throws {
        let seg = DocumentSegment(id: UUID(), assetID: r.id, sourceKind: .user, tabID: nil, sourceVersion: nil, heading: r.kind.label,
                                  startIndex: nil, endIndex: nil, ordinal: 0, text: r.statement)
        try search.replace(itemID: r.id, kind: .memory, title: r.kind.label, segments: [seg])
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func fingerprint(_ statement: String, projectID: UUID?) -> String {
        Hashing.sha256Hex((projectID?.uuidString ?? "global") + "|" + normalize(statement))
    }

    /// Heuristic: same subject (high word overlap) but different content, or an explicit negation.
    static func likelyConflict(_ a: String, _ b: String) -> Bool {
        let stop: Set<String> = ["the", "a", "an", "is", "are", "to", "of", "and", "in", "for", "on", "this", "that", "it", "be"]
        let wa = Set(normalize(a).split(separator: " ").map(String.init)).subtracting(stop)
        let wb = Set(normalize(b).split(separator: " ").map(String.init)).subtracting(stop)
        guard !wa.isEmpty, !wb.isEmpty, wa != wb else { return false }
        let jaccard = Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
        let negA = wa.contains("not") || wa.contains("never") || wa.contains("no")
        let negB = wb.contains("not") || wb.contains("never") || wb.contains("no")
        return jaccard >= 0.5 || (jaccard >= 0.3 && negA != negB)
    }

    static func decode(_ r: SQLRow) -> MemoryRecord? {
        guard let id = r.uuid("id"), let kind = MemoryKind(rawValue: r.string("kind") ?? ""),
              let prov = Provenance(rawValue: r.string("provenance") ?? ""), let observed = r.date("observed_at") else { return nil }
        let providers = (r.json("allowed_providers", as: [String].self) ?? []).compactMap(ProviderID.init(rawValue:))
        return MemoryRecord(id: id, projectID: r.uuid("project_id"), kind: kind, statement: r.string("statement") ?? "",
                            provenance: prov, sourceRef: r.json("source_ref", as: SourceRef.self), observedAt: observed,
                            status: MemoryStatus(rawValue: r.string("status") ?? "") ?? .active,
                            sensitivity: Sensitivity(rawValue: r.string("sensitivity") ?? "") ?? .normal,
                            allowedProviders: Set(providers), supersedes: r.uuid("supersedes"), expiresAt: r.date("expires_at"))
    }
}

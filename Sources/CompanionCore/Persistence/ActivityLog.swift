import Foundation

public struct ActivityEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: String
    public let initiator: String
    public let summary: String
    public let detail: String?
    public let actionID: UUID?
    public let createdAt: Date
}

/// Content-free activity journal shown in "Memory and activity".
public final class ActivityLog: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    public init(db: SQLiteDatabase, clock: Clock) { self.db = db; self.clock = clock }

    public func record(kind: String, initiator: String = "user", summary: String, detail: String? = nil, actionID: UUID? = nil) {
        try? db.execute("""
            INSERT INTO activity(id, kind, initiator, summary, detail, action_id, created_at)
            VALUES(?,?,?,?,?,?,?)
            """, [UUID(), kind, initiator, Redactor.redact(summary), detail.map(Redactor.redact), actionID, clock.now()])
    }

    public func recent(limit: Int = 200) -> [ActivityEntry] {
        let rows = (try? db.query("SELECT * FROM activity ORDER BY created_at DESC LIMIT ?", [limit])) ?? []
        return rows.compactMap { r in
            guard let id = r.uuid("id"), let date = r.date("created_at") else { return nil }
            return ActivityEntry(id: id, kind: r.string("kind") ?? "", initiator: r.string("initiator") ?? "",
                                 summary: r.string("summary") ?? "", detail: r.string("detail"),
                                 actionID: r.uuid("action_id"), createdAt: date)
        }
    }

    public func prune(olderThan days: Int) {
        let cutoff = clock.now().addingTimeInterval(-Double(days) * 86_400)
        try? db.execute("DELETE FROM activity WHERE created_at < ?", [cutoff])
    }
}

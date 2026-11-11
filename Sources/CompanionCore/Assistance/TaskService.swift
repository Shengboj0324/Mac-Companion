import Foundation

/// Tasks with confirmed-or-proposed deadlines and requirement checklists.
/// An event start is never silently a deadline; "ready" and "submitted" stay separate.
public final class TaskService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let extractor = RequirementExtractor()

    public init(db: SQLiteDatabase, clock: Clock) { self.db = db; self.clock = clock }

    @discardableResult
    public func create(title: String, projectID: UUID?, eventID: UUID? = nil, proposedDeadline: Date? = nil, evidence: String? = nil) throws -> TaskItem {
        let t = TaskItem(id: UUID(), projectID: projectID, title: title, state: .open, deadline: proposedDeadline,
                         deadlineConfirmed: false, deadlineEvidence: evidence, eventID: eventID, createdAt: clock.now())
        try db.execute("""
            INSERT INTO tasks(id, project_id, title, state, deadline, deadline_confirmed, deadline_evidence, event_id, created_at)
            VALUES(?,?,?,?,?,0,?,?,?)
            """, [t.id, projectID, title, t.state.rawValue, proposedDeadline, evidence, eventID, t.createdAt])
        return t
    }

    public func tasks(projectID: UUID? = nil) -> [TaskItem] {
        let rows: [SQLRow]
        if let projectID { rows = (try? db.query("SELECT * FROM tasks WHERE project_id=? ORDER BY COALESCE(deadline, created_at)", [projectID])) ?? [] }
        else { rows = (try? db.query("SELECT * FROM tasks ORDER BY COALESCE(deadline, created_at)")) ?? [] }
        return rows.compactMap(Self.decodeTask)
    }

    public func task(_ id: UUID) -> TaskItem? { (try? db.queryOne("SELECT * FROM tasks WHERE id=?", [id])).flatMap(Self.decodeTask) }

    public func confirmDeadline(_ id: UUID, date: Date) throws {
        try db.execute("UPDATE tasks SET deadline=?, deadline_confirmed=1 WHERE id=?", [date, id])
    }

    public func setState(_ id: UUID, _ state: TaskState) throws {
        try db.execute("UPDATE tasks SET state=? WHERE id=?", [state.rawValue, id])
    }

    public func delete(_ id: UUID) throws { try db.execute("DELETE FROM tasks WHERE id=?", [id]) }

    /// Extracts requirements from description text; all start unconfirmed.
    @discardableResult
    public func extractRequirements(taskID: UUID, from description: String, locator: String? = nil) throws -> [Requirement] {
        let (items, deadlines) = extractor.extract(description)
        let base = (try db.scalarInt("SELECT COALESCE(MAX(ordinal), -1) FROM requirements WHERE task_id=?", [taskID])) + 1
        var out: [Requirement] = []
        try db.transaction {
            for (i, item) in items.enumerated() {
                let r = Requirement(id: UUID(), taskID: taskID, text: item.text + (item.note.map { " — \($0)" } ?? ""), status: item.status,
                                    evidence: item.evidence, evidenceLocator: locator, confirmation: .unconfirmed, done: false, ordinal: base + i)
                try db.execute("""
                    INSERT INTO requirements(id, task_id, text, status, evidence, evidence_locator, confirmation, done, ordinal)
                    VALUES(?,?,?,?,?,?,?,0,?)
                    """, [r.id, taskID, r.text, r.status.rawValue, r.evidence, locator, r.confirmation.rawValue, r.ordinal])
                out.append(r)
            }
            if let d = deadlines.first, task(taskID)?.deadlineConfirmed == false {
                try db.execute("UPDATE tasks SET deadline=?, deadline_evidence=? WHERE id=?", [d.date, d.evidence, taskID])
            }
        }
        return out
    }

    public func requirements(taskID: UUID) -> [Requirement] {
        ((try? db.query("SELECT * FROM requirements WHERE task_id=? ORDER BY ordinal", [taskID])) ?? []).compactMap(Self.decodeRequirement)
    }

    public func setConfirmation(_ id: UUID, _ c: ConfirmationState, status: RequirementStatus? = nil) throws {
        if let status { try db.execute("UPDATE requirements SET confirmation=?, status=? WHERE id=?", [c.rawValue, status.rawValue, id]) }
        else { try db.execute("UPDATE requirements SET confirmation=? WHERE id=?", [c.rawValue, id]) }
    }

    /// Completion is a user statement — never inferred from a document being opened.
    public func setDone(_ id: UUID, _ done: Bool) throws { try db.execute("UPDATE requirements SET done=? WHERE id=?", [done, id]) }

    public func nextUnfinished(taskID: UUID) -> Requirement? {
        requirements(taskID: taskID).first { !$0.done && $0.status == .required && $0.confirmation != .rejected }
    }

    public func progress(taskID: UUID) -> (done: Int, required: Int) {
        let reqs = requirements(taskID: taskID).filter { $0.status == .required && $0.confirmation != .rejected }
        return (reqs.filter(\.done).count, reqs.count)
    }

    static func decodeTask(_ r: SQLRow) -> TaskItem? {
        guard let id = r.uuid("id"), let created = r.date("created_at") else { return nil }
        return TaskItem(id: id, projectID: r.uuid("project_id"), title: r.string("title") ?? "",
                        state: TaskState(rawValue: r.string("state") ?? "") ?? .open, deadline: r.date("deadline"),
                        deadlineConfirmed: r.bool("deadline_confirmed"), deadlineEvidence: r.string("deadline_evidence"),
                        eventID: r.uuid("event_id"), createdAt: created)
    }

    static func decodeRequirement(_ r: SQLRow) -> Requirement? {
        guard let id = r.uuid("id"), let task = r.uuid("task_id") else { return nil }
        return Requirement(id: id, taskID: task, text: r.string("text") ?? "",
                           status: RequirementStatus(rawValue: r.string("status") ?? "") ?? .inferred, evidence: r.string("evidence") ?? "",
                           evidenceLocator: r.string("evidence_locator"),
                           confirmation: ConfirmationState(rawValue: r.string("confirmation") ?? "") ?? .unconfirmed,
                           done: r.bool("done"), ordinal: r.int("ordinal") ?? 0)
    }
}

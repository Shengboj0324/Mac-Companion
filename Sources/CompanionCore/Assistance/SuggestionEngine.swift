import Foundation

public struct Suggestion: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case materialsReady, linkEvent, confirmDeadline, reviewProposal, staleCopy, resume }
    public let id: String
    public let kind: Kind
    public let title: String
    /// Visible explanation for why this appeared.
    public let reason: String
    public let projectID: UUID?
    public let eventID: UUID?
    public let priority: Int
}

/// Builds at most three explained suggestions from local state only — no model
/// call, no file action. Suggestions lead to explicit actions (spec §9).
public final class SuggestionEngine: @unchecked Sendable {
    private let clock: Clock
    private let projects: ProjectService
    private let calendar: CalendarService
    private let tasks: TaskService
    private let executor: ActionExecutor
    private let copies: WorkingCopyService

    public init(clock: Clock, projects: ProjectService, calendar: CalendarService, tasks: TaskService, executor: ActionExecutor, copies: WorkingCopyService) {
        self.clock = clock; self.projects = projects; self.calendar = calendar; self.tasks = tasks; self.executor = executor; self.copies = copies
    }

    public func today(limit: Int = 3) -> [Suggestion] {
        let now = clock.now()
        var out: [Suggestion] = []
        let allProjects = projects.all()
        let active = allProjects.filter { ($0.snoozedUntil ?? .distantPast) < now }

        for event in calendar.upcoming(hours: 24) {
            let linked = active.first { p in projects.items(projectID: p.id).contains { $0.kind == .event && $0.targetID == event.id } }
            if let p = linked {
                let cp = projects.latestCheckpoint(projectID: p.id)
                let soon = event.startAt.timeIntervalSince(now) < 3 * 3_600
                out.append(Suggestion(id: "ready-\(event.id)", kind: .materialsReady,
                                      title: soon ? "Your \(p.name) materials are ready" : "Prepare for \(event.title)",
                                      reason: "Linked to “\(event.title)” at \(Self.time(event.startAt))" + (cp.map { ". Last note: \($0.note.prefix(60))" } ?? ""),
                                      projectID: p.id, eventID: event.id, priority: soon ? 100 : 60))
            } else if let match = Self.bestProjectMatch(eventTitle: event.title, projects: active) {
                out.append(Suggestion(id: "link-\(event.id)-\(match.id)", kind: .linkEvent, title: "Link “\(event.title)” to \(match.name)?",
                                      reason: "The event title resembles this project's name — confirm before linking",
                                      projectID: match.id, eventID: event.id, priority: 40))
            }
        }
        for t in tasks.tasks() where t.state == .open && !t.deadlineConfirmed && t.deadline != nil {
            out.append(Suggestion(id: "deadline-\(t.id)", kind: .confirmDeadline, title: "Confirm the deadline for \(t.title)",
                                  reason: "Proposed from: “\((t.deadlineEvidence ?? "calendar time").prefix(80))”", projectID: t.projectID, eventID: t.eventID, priority: 50))
        }
        let pending = executor.pendingProposals()
        if !pending.isEmpty {
            out.append(Suggestion(id: "proposals", kind: .reviewProposal, title: "\(pending.count) proposed change(s) await your review",
                                  reason: "Nothing is applied until you approve it", projectID: nil, eventID: nil, priority: 30))
        }
        for wc in copies.all() where wc.state == .sourceChanged || wc.state == .conflict {
            out.append(Suggestion(id: "copy-\(wc.id)", kind: .staleCopy, title: "\((wc.copyPath as NSString).lastPathComponent): \(wc.state.label)",
                                  reason: "The original changed after this working copy was made", projectID: wc.projectID, eventID: nil, priority: 20))
        }
        if out.isEmpty, let p = projects.lastActive, let cp = projects.latestCheckpoint(projectID: p.id) {
            out.append(Suggestion(id: "resume-\(p.id)", kind: .resume, title: "Continue \(p.name)",
                                  reason: "Last checkpoint: \(cp.note.prefix(80))", projectID: p.id, eventID: nil, priority: 10))
        }
        return Array(out.sorted { $0.priority > $1.priority }.prefix(limit))
    }

    static func bestProjectMatch(eventTitle: String, projects: [Project]) -> Project? {
        let et = PlacementSuggester.tokens(eventTitle)
        guard !et.isEmpty else { return nil }
        let scored = projects.map { p -> (Project, Double) in
            let pt = PlacementSuggester.tokens(p.name)
            guard !pt.isEmpty else { return (p, 0) }
            return (p, Double(pt.intersection(et).count) / Double(pt.count))
        }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }
        // Ambiguity (two equally good matches) → no automatic suggestion; ask instead.
        if scored.count >= 2, scored[0].1 == scored[1].1 { return nil }
        return scored.first?.0
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: d)
    }
}

/// Interruption rules: at most N proactive notifications/day, quiet hours, per-project snooze,
/// suppressed in presentation mode (spec §3, §9).
public final class NotificationPolicy: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore

    public init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore) { self.db = db; self.clock = clock; self.settings = settings }

    public func mayNotify(projectSnoozedUntil: Date? = nil, calendar: Calendar = .current) -> Bool {
        let now = clock.now()
        guard settings.get(Settings.notificationsEnabled), !settings.get(Settings.presentationMode), !settings.get(Settings.paused) else { return false }
        if let s = projectSnoozedUntil, s > now { return false }
        let hour = calendar.component(.hour, from: now)
        let qs = settings.get(Settings.quietHoursStart), qe = settings.get(Settings.quietHoursEnd)
        let quiet = qs > qe ? (hour >= qs || hour < qe) : (hour >= qs && hour < qe)
        if quiet { return false }
        let startOfDay = calendar.startOfDay(for: now)
        let sent = (try? db.scalarInt("SELECT COUNT(*) FROM notifications_log WHERE sent_at >= ?", [startOfDay])) ?? 0
        return sent < settings.get(Settings.maxNotificationsPerDay)
    }

    public func record(kind: String, projectID: UUID?) {
        try? db.execute("INSERT INTO notifications_log(id, project_id, kind, sent_at) VALUES(?,?,?,?)", [UUID(), projectID, kind, clock.now()])
    }
}

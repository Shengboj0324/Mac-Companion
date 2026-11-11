import Foundation

/// Mirrors selected calendars into the local store with freshness, and executes
/// approved focus blocks with a conflict check immediately before saving (spec §9).
public final class CalendarService: ExternalOperationPerformer, @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore
    public let source: CalendarSource
    public private(set) var lastRefresh: Date?

    public init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore, source: CalendarSource) {
        self.db = db; self.clock = clock; self.settings = settings; self.source = source
    }

    public var isAuthorized: Bool { source.authorization == .fullAccess }

    // MARK: Refresh

    /// Loads the previous 14 and next 60 days (configurable) for selected calendars,
    /// preserving recurrence identity, all-day status and time zone.
    @discardableResult
    public func refresh() -> Int {
        guard isAuthorized else { return 0 }
        let selected = settings.get(Settings.selectedCalendars)
        let now = clock.now()
        let start = now.addingTimeInterval(-Double(settings.get(Settings.calendarPastDays)) * 86_400)
        let end = now.addingTimeInterval(Double(settings.get(Settings.calendarFutureDays)) * 86_400)
        let fetched = source.events(from: start, to: end, calendarIDs: selected)
        var keep = Set<UUID>()
        try? db.transaction {
            for e in fetched {
                let existing = try db.queryOne("""
                    SELECT id FROM calendar_items WHERE (event_identifier = ? AND COALESCE(occurrence_date, start_at) = ?)
                        OR (external_identifier = ? AND calendar_id = ? AND COALESCE(occurrence_date, start_at) = ?) LIMIT 1
                    """, [e.eventIdentifier, e.occurrenceDate ?? e.startAt, e.externalIdentifier, e.calendarID, e.occurrenceDate ?? e.startAt])
                let id = existing?.uuid("id") ?? e.id
                keep.insert(id)
                try db.execute("""
                    INSERT INTO calendar_items(id, event_identifier, external_identifier, calendar_id, calendar_title, title, notes, location,
                        start_at, end_at, is_all_day, time_zone, is_recurring, occurrence_date, last_modified, refreshed_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET event_identifier=excluded.event_identifier, external_identifier=excluded.external_identifier,
                        calendar_title=excluded.calendar_title, title=excluded.title, notes=excluded.notes, location=excluded.location,
                        start_at=excluded.start_at, end_at=excluded.end_at, is_all_day=excluded.is_all_day, time_zone=excluded.time_zone,
                        is_recurring=excluded.is_recurring, occurrence_date=excluded.occurrence_date, last_modified=excluded.last_modified,
                        refreshed_at=excluded.refreshed_at
                    """, [id, e.eventIdentifier, e.externalIdentifier, e.calendarID, e.calendarTitle, e.title, e.notes, e.location,
                          e.startAt, e.endAt, e.isAllDay, e.timeZone, e.isRecurring, e.occurrenceDate, e.lastModified, now])
            }
            // Deleted events (or deselected calendars) inside the window disappear.
            let stored = try db.query("SELECT id, calendar_id FROM calendar_items WHERE start_at >= ? AND start_at <= ?", [start, end])
            for r in stored {
                guard let id = r.uuid("id"), !keep.contains(id) else { continue }
                try db.execute("DELETE FROM calendar_items WHERE id=?", [id])
            }
        }
        lastRefresh = now
        return fetched.count
    }

    public func items(from: Date, to: Date) -> [CalendarItem] {
        ((try? db.query("SELECT * FROM calendar_items WHERE end_at >= ? AND start_at <= ? ORDER BY start_at", [from, to])) ?? []).compactMap(Self.decode)
    }

    public func upcoming(hours: Double = 48) -> [CalendarItem] {
        let now = clock.now()
        return items(from: now, to: now.addingTimeInterval(hours * 3_600))
    }

    public func item(_ id: UUID) -> CalendarItem? {
        (try? db.queryOne("SELECT * FROM calendar_items WHERE id=?", [id])).flatMap(Self.decode)
    }

    public func conflicts(start: Date, end: Date, calendarIDs: [String]? = nil) -> [CalendarItem] {
        let ids = calendarIDs ?? settings.get(Settings.selectedCalendars)
        return source.events(from: start, to: end, calendarIDs: ids).filter { !$0.isAllDay && $0.startAt < end && $0.endAt > start }
    }

    /// Freshness reflects what the local calendar store has synchronized.
    public var freshnessLabel: String {
        guard let lastRefresh else { return "Not refreshed yet" }
        let f = RelativeDateTimeFormatter()
        return "Checked " + f.localizedString(for: lastRefresh, relativeTo: clock.now())
    }

    // MARK: ExternalOperationPerformer

    public func handles(_ kind: OperationKind) -> Bool { kind == .createCalendarEvent }

    public func validate(_ op: PlannedOperation) async throws {
        guard isAuthorized else { throw CompanionError.permissionDenied("Calendar access") }
        guard let spec = op.calendar else { throw CompanionError.invalidArgument("Missing event") }
        guard settings.get(Settings.writableCalendars).contains(spec.calendarID) else {
            throw CompanionError.policyViolation("\(spec.calendarTitle) is not designated to receive changes")
        }
        let c = conflicts(start: spec.start, end: spec.end)
        if !c.isEmpty { throw CompanionError.staleSource("Conflicts with “\(c[0].title)” — choose another time") }
    }

    public func perform(_ op: PlannedOperation, actionID: UUID, index: Int) async throws -> OperationResult {
        guard let spec = op.calendar else { throw CompanionError.invalidArgument("Missing event") }
        let id: String
        do { id = try source.createEvent(spec) }
        catch let e as CompanionError { throw e }
        catch { throw CompanionError.outcomeUnknown("Calendar save did not confirm; will reconcile") }
        guard let readBack = source.event(identifier: id) else {
            throw CompanionError.outcomeUnknown("Saved event not found on read-back")
        }
        let verified = readBack.title == spec.title && abs(readBack.startAt.timeIntervalSince(spec.start)) < 1
            && abs(readBack.endAt.timeIntervalSince(spec.end)) < 1
        refresh()
        try? db.execute("UPDATE calendar_items SET created_by_app=1 WHERE event_identifier=?", [id])
        return OperationResult(index: index, status: .succeeded, verified: verified, detail: verified ? nil : "Event differs from preview",
                               externalID: id)
    }

    public func reconcile(_ op: PlannedOperation, actionID: UUID, index: Int) async -> OperationResult? {
        guard let spec = op.calendar else { return nil }
        let matches = source.events(from: spec.start.addingTimeInterval(-60), to: spec.end.addingTimeInterval(60), calendarIDs: [spec.calendarID])
            .filter { $0.title == spec.title && abs($0.startAt.timeIntervalSince(spec.start)) < 1 }
        if let m = matches.first {
            return OperationResult(index: index, status: .succeeded, verified: true, detail: "Found after reconciliation", externalID: m.eventIdentifier)
        }
        return OperationResult(index: index, status: .failed, verified: false, detail: "Event was not created")
    }

    static func decode(_ r: SQLRow) -> CalendarItem? {
        guard let id = r.uuid("id"), let start = r.date("start_at"), let end = r.date("end_at") else { return nil }
        return CalendarItem(id: id, eventIdentifier: r.string("event_identifier"), externalIdentifier: r.string("external_identifier"),
                            calendarID: r.string("calendar_id") ?? "", calendarTitle: r.string("calendar_title") ?? "",
                            title: r.string("title") ?? "", notes: r.string("notes"), location: r.string("location"),
                            startAt: start, endAt: end, isAllDay: r.bool("is_all_day"), timeZone: r.string("time_zone"),
                            isRecurring: r.bool("is_recurring"), occurrenceDate: r.date("occurrence_date"),
                            lastModified: r.date("last_modified"), refreshedAt: r.date("refreshed_at") ?? start,
                            createdByApp: r.bool("created_by_app"))
    }
}

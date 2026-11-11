import XCTest
@testable import CompanionCore

final class CalendarTests: XCTestCase {
    private func setup() -> TestEnv {
        let t = TestEnv()
        t.calendar.infos = [CalendarInfo(id: "school", title: "School", sourceTitle: "iCloud", allowsModifications: true, isSubscribed: false),
                            CalendarInfo(id: "subs", title: "Holidays", sourceTitle: "Subscribed", allowsModifications: false, isSubscribed: true)]
        t.env.settings.set(Settings.selectedCalendars, ["school", "subs"])
        return t
    }

    func testRefreshMirrorsDedupesAndRemovesDeleted() {
        let t = setup()
        let now = t.clock.now()
        t.calendar.items = [
            CalendarItem(eventIdentifier: "e1", externalIdentifier: "x1", calendarID: "school", calendarTitle: "School", title: "HW#40",
                         startAt: now + 3_600, endAt: now + 7_200, timeZone: "America/Los_Angeles", isRecurring: false, refreshedAt: now),
            CalendarItem(eventIdentifier: "e2", externalIdentifier: "x2", calendarID: "school", calendarTitle: "School", title: "Study session",
                         startAt: now + 86_400, endAt: now + 90_000, isRecurring: true, occurrenceDate: now + 86_400, refreshedAt: now),
            CalendarItem(eventIdentifier: "e3", externalIdentifier: "x3", calendarID: "other", calendarTitle: "Other", title: "Unselected",
                         startAt: now + 100, endAt: now + 200, refreshedAt: now),
        ]
        XCTAssertEqual(t.env.calendar.refresh(), 2)
        XCTAssertEqual(t.env.calendar.refresh(), 2)
        let items = t.env.calendar.items(from: now - 86_400, to: now + 30 * 86_400)
        XCTAssertEqual(items.count, 2, "no duplicates on refresh; unselected calendars excluded")
        XCTAssertEqual(items.first?.timeZone, "America/Los_Angeles")
        XCTAssertTrue(items.contains { $0.isRecurring })
        t.calendar.items.removeFirst()
        t.env.calendar.refresh()
        XCTAssertEqual(t.env.calendar.items(from: now - 86_400, to: now + 30 * 86_400).map(\.title), ["Study session"])
    }

    func testFocusBlockRequiresWritableCalendarAndChecksConflicts() async throws {
        let t = setup()
        t.env.settings.set(Settings.safetyMode, .reviewedChanges)
        let now = t.clock.now()
        t.calendar.items = [CalendarItem(eventIdentifier: "busy", externalIdentifier: "busy", calendarID: "school", calendarTitle: "School",
                                         title: "Class", startAt: now + 3_600, endAt: now + 7_200, refreshedAt: now)]
        let spec = FocusBlockSpec(calendarID: "school", calendarTitle: "School", title: "Focus: lit review", start: now + 4_000, end: now + 5_000, timeZone: "UTC")
        let plan = ActionPlan(title: "Focus", operations: [PlannedOperation(kind: .createCalendarEvent, calendar: spec)], createdAt: now)
        XCTAssertFalse(t.env.executor.evaluate(plan).isEmpty, "calendar must be designated writable")
        t.env.settings.set(Settings.writableCalendars, ["school"])
        try t.env.executor.propose(plan)
        var run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: now))
        XCTAssertEqual(run.state, .failed, "conflict detected immediately before saving")
        XCTAssertTrue(run.error?.contains("Conflicts") == true)

        let free = FocusBlockSpec(calendarID: "school", calendarTitle: "School", title: "Focus: lit review", start: now + 10_000, end: now + 12_000, timeZone: "UTC")
        let plan2 = ActionPlan(title: "Focus", operations: [PlannedOperation(kind: .createCalendarEvent, calendar: free)], createdAt: now)
        try t.env.executor.propose(plan2)
        run = await t.env.executor.execute(plan2.id, grant: t.env.approvals.issue(for: plan2, userConfirmedAt: now))
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(run.results[0].verified)
        XCTAssertEqual(t.calendar.items.filter { $0.title == "Focus: lit review" }.count, 1)
    }

    func testTimeoutIsOutcomeUnknownThenReconciled() async throws {
        let t = setup()
        t.env.settings.set(Settings.safetyMode, .reviewedChanges)
        t.env.settings.set(Settings.writableCalendars, ["school"])
        let now = t.clock.now()
        t.calendar.failNextSave = true
        let spec = FocusBlockSpec(calendarID: "school", calendarTitle: "School", title: "Focus", start: now + 10_000, end: now + 12_000, timeZone: "UTC")
        let plan = ActionPlan(title: "Focus", operations: [PlannedOperation(kind: .createCalendarEvent, calendar: spec)], createdAt: now)
        try t.env.executor.propose(plan)
        let run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: now))
        XCTAssertEqual(run.state, .outcomeUnknown)
        await t.env.executor.reconcileUnfinished()
        XCTAssertEqual(t.env.executor.run(plan.id)?.state, .failed, "reconciliation finds no event; nothing blindly retried")
        XCTAssertTrue(t.calendar.items.isEmpty)
    }
}

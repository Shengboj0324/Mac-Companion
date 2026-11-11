import Foundation
import EventKit

public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let sourceTitle: String
    public let allowsModifications: Bool
    public let isSubscribed: Bool
}

public enum CalendarAuthorization: String, Sendable { case notDetermined, denied, restricted, fullAccess, writeOnly }

/// Abstraction over EventKit so calendar logic is testable without system access.
public protocol CalendarSource: AnyObject, Sendable {
    var authorization: CalendarAuthorization { get }
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    func events(from start: Date, to end: Date, calendarIDs: [String]) -> [CalendarItem]
    func createEvent(_ spec: FocusBlockSpec) throws -> String
    func event(identifier: String) -> CalendarItem?
}

/// EventKit-backed source. Reading requires macOS full calendar access; "read only
/// in Companion" is an application policy, not an OS entitlement (TN3152).
public final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public var authorization: CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "",
                         allowsModifications: $0.allowsContentModifications, isSubscribed: $0.isSubscribed)
        }
    }

    public func events(from start: Date, to end: Date, calendarIDs: [String]) -> [CalendarItem] {
        let cals = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        let now = Date()
        return store.events(matching: predicate).map { Self.item($0, refreshedAt: now) }
    }

    public func createEvent(_ spec: FocusBlockSpec) throws -> String {
        guard let cal = store.calendar(withIdentifier: spec.calendarID) else { throw CompanionError.notFound("Calendar") }
        guard cal.allowsContentModifications else { throw CompanionError.permissionDenied("\(cal.title) is read-only") }
        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = spec.title
        event.startDate = spec.start
        event.endDate = spec.end
        event.timeZone = TimeZone(identifier: spec.timeZone)
        event.notes = "Created by Companion after your approval."
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw CompanionError.outcomeUnknown("Event saved without identifier") }
        return id
    }

    public func event(identifier: String) -> CalendarItem? {
        store.event(withIdentifier: identifier).map { Self.item($0, refreshedAt: Date()) }
    }

    static func item(_ e: EKEvent, refreshedAt: Date) -> CalendarItem {
        CalendarItem(eventIdentifier: e.eventIdentifier, externalIdentifier: e.calendarItemExternalIdentifier,
                     calendarID: e.calendar.calendarIdentifier, calendarTitle: e.calendar.title, title: e.title ?? "(No title)",
                     notes: e.notes, location: e.location, startAt: e.startDate, endAt: e.endDate, isAllDay: e.isAllDay,
                     timeZone: e.timeZone?.identifier, isRecurring: e.hasRecurrenceRules, occurrenceDate: e.occurrenceDate,
                     lastModified: e.lastModifiedDate, refreshedAt: refreshedAt)
    }
}

/// In-memory source for tests and previews.
public final class MockCalendarSource: CalendarSource, @unchecked Sendable {
    public var authorization: CalendarAuthorization = .fullAccess
    public var infos: [CalendarInfo] = []
    public var items: [CalendarItem] = []
    public var failNextSave = false
    public init() {}
    public func requestAccess() async -> Bool { authorization == .fullAccess }
    public func calendars() -> [CalendarInfo] { infos }
    public func events(from start: Date, to end: Date, calendarIDs: [String]) -> [CalendarItem] {
        items.filter { calendarIDs.contains($0.calendarID) && $0.endAt >= start && $0.startAt <= end }
    }
    public func createEvent(_ spec: FocusBlockSpec) throws -> String {
        if failNextSave { failNextSave = false; throw CompanionError.outcomeUnknown("Simulated timeout") }
        let id = "mock-\(UUID().uuidString)"
        items.append(CalendarItem(eventIdentifier: id, externalIdentifier: id, calendarID: spec.calendarID, calendarTitle: spec.calendarTitle,
                                  title: spec.title, startAt: spec.start, endAt: spec.end, timeZone: spec.timeZone, refreshedAt: Date()))
        return id
    }
    public func event(identifier: String) -> CalendarItem? { items.first { $0.eventIdentifier == identifier } }
}

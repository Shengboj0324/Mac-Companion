import Foundation

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case preference, projectFact, taskState, sessionContext
    public var label: String {
        switch self {
        case .preference: return "Preference"
        case .projectFact: return "Project fact"
        case .taskState: return "Task state"
        case .sessionContext: return "Session context"
        }
    }
}

/// Distinguish user-confirmed facts, sourced observations and AI inferences (spec §10).
public enum Provenance: String, Codable, CaseIterable, Sendable {
    case userConfirmed, sourcedObservation, aiInference
    public var label: String {
        switch self {
        case .userConfirmed: return "Confirmed by you"
        case .sourcedObservation: return "Observed in a source"
        case .aiInference: return "AI inference (unconfirmed)"
        }
    }
}

public enum MemoryStatus: String, Codable, Sendable { case active, conflicted, superseded, proposed }
public enum Sensitivity: String, Codable, CaseIterable, Sendable { case normal, sensitive, neverSend }

public struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var kind: MemoryKind
    public var statement: String
    public var provenance: Provenance
    public var sourceRef: SourceRef?
    public var observedAt: Date
    public var status: MemoryStatus
    public var sensitivity: Sensitivity
    /// Empty = inherit project/source disclosure policy.
    public var allowedProviders: Set<ProviderID>
    public var supersedes: UUID?
    public var expiresAt: Date?

    public init(id: UUID = UUID(), projectID: UUID?, kind: MemoryKind, statement: String, provenance: Provenance,
                sourceRef: SourceRef? = nil, observedAt: Date, status: MemoryStatus = .active,
                sensitivity: Sensitivity = .normal, allowedProviders: Set<ProviderID> = [],
                supersedes: UUID? = nil, expiresAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.kind = kind; self.statement = statement
        self.provenance = provenance; self.sourceRef = sourceRef; self.observedAt = observedAt
        self.status = status; self.sensitivity = sensitivity; self.allowedProviders = allowedProviders
        self.supersedes = supersedes; self.expiresAt = expiresAt
    }
}

public struct CalendarItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var eventIdentifier: String?
    public var externalIdentifier: String?
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var notes: String?
    public var location: String?
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool
    public var timeZone: String?
    public var isRecurring: Bool
    public var occurrenceDate: Date?
    public var lastModified: Date?
    public var refreshedAt: Date
    public var createdByApp: Bool

    public init(id: UUID = UUID(), eventIdentifier: String?, externalIdentifier: String?, calendarID: String,
                calendarTitle: String, title: String, notes: String? = nil, location: String? = nil,
                startAt: Date, endAt: Date, isAllDay: Bool = false, timeZone: String? = nil,
                isRecurring: Bool = false, occurrenceDate: Date? = nil, lastModified: Date? = nil,
                refreshedAt: Date, createdByApp: Bool = false) {
        self.id = id; self.eventIdentifier = eventIdentifier; self.externalIdentifier = externalIdentifier
        self.calendarID = calendarID; self.calendarTitle = calendarTitle; self.title = title
        self.notes = notes; self.location = location; self.startAt = startAt; self.endAt = endAt
        self.isAllDay = isAllDay; self.timeZone = timeZone; self.isRecurring = isRecurring
        self.occurrenceDate = occurrenceDate; self.lastModified = lastModified
        self.refreshedAt = refreshedAt; self.createdByApp = createdByApp
    }
}

public enum TaskState: String, Codable, Sendable { case open, ready, submitted, done }

public struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var title: String
    public var state: TaskState
    /// A deadline is a proposal until confirmed; an event start is not a deadline (spec §9).
    public var deadline: Date?
    public var deadlineConfirmed: Bool
    public var deadlineEvidence: String?
    public var eventID: UUID?
    public let createdAt: Date
}

public enum RequirementStatus: String, Codable, Sendable { case required, optional, inferred }
public enum ConfirmationState: String, Codable, Sendable { case unconfirmed, confirmed, rejected }

public struct Requirement: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var taskID: UUID
    public var text: String
    public var status: RequirementStatus
    /// Verbatim source passage supporting the item.
    public var evidence: String
    public var evidenceLocator: String?
    public var confirmation: ConfirmationState
    public var done: Bool
    public var ordinal: Int
}

public enum ChatRole: String, Codable, Sendable { case system, user, assistant, tool }

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var conversationID: UUID
    public var role: ChatRole
    public var content: String
    public var provider: ProviderID?
    public var model: String?
    public var sourceRefs: [SourceRef]
    /// Opaque provider continuation state — only ever replayed to the same adapter.
    public var adapterState: String?
    public let createdAt: Date
}

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var summary: String?
}

public struct UsageEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let provider: ProviderID
    public let model: String
    public let requestID: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let priceVersion: String
    public let estimatedCost: Double
    public let isEstimate: Bool
    public let createdAt: Date
}

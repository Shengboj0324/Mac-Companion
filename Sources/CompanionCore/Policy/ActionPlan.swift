import Foundation

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case addReference, copyFile, createFolder, rename, move, replaceContents
    case createCalendarEvent
    case docsCreate, docsCopy, docsEdit

    /// Mutates something the user owns outside Companion's private storage.
    public var mutatesUserContent: Bool { self != .addReference }

    public var isLocalFileWrite: Bool { [.copyFile, .createFolder, .rename, .move, .replaceContents].contains(self) }
    public var isCloud: Bool { [.docsCreate, .docsCopy, .docsEdit].contains(self) }

    public var verb: String {
        switch self {
        case .addReference: return "reference"
        case .copyFile: return "copy"
        case .createFolder: return "folder"
        case .rename: return "rename"
        case .move: return "move"
        case .replaceContents: return "replacement"
        case .createCalendarEvent: return "calendar event"
        case .docsCreate: return "new Google Doc"
        case .docsCopy: return "Google Doc copy"
        case .docsEdit: return "Google Doc edit"
        }
    }
}

public struct FocusBlockSpec: Codable, Hashable, Sendable {
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZone: String
    public init(calendarID: String, calendarTitle: String, title: String, start: Date, end: Date, timeZone: String) {
        self.calendarID = calendarID; self.calendarTitle = calendarTitle; self.title = title
        self.start = start; self.end = end; self.timeZone = timeZone
    }
}

public struct DocsTextEdit: Codable, Hashable, Sendable {
    public var tabID: String?
    public var startIndex: Int
    public var endIndex: Int
    public var before: String
    public var after: String
    public init(tabID: String?, startIndex: Int, endIndex: Int, before: String, after: String) {
        self.tabID = tabID; self.startIndex = startIndex; self.endIndex = endIndex; self.before = before; self.after = after
    }
}

public struct DocsOperationSpec: Codable, Hashable, Sendable {
    public var accountID: UUID
    public var accountIdentity: String
    public var documentID: String?
    public var documentTitle: String
    public var requiredRevisionID: String?
    public var destinationFolderID: String?
    public var destinationVisibility: String?
    public var edits: [DocsTextEdit]
    public init(accountID: UUID, accountIdentity: String, documentID: String?, documentTitle: String,
                requiredRevisionID: String?, destinationFolderID: String? = nil, destinationVisibility: String? = nil,
                edits: [DocsTextEdit] = []) {
        self.accountID = accountID; self.accountIdentity = accountIdentity; self.documentID = documentID
        self.documentTitle = documentTitle; self.requiredRevisionID = requiredRevisionID
        self.destinationFolderID = destinationFolderID; self.destinationVisibility = destinationVisibility; self.edits = edits
    }
}

/// One reviewed operation. Every field the executor acts on is part of the plan hash.
public struct PlannedOperation: Codable, Hashable, Sendable {
    public var kind: OperationKind
    public var sourcePath: String?
    /// Content hash the source must still have at execution time.
    public var sourceHash: String?
    public var destinationPath: String?
    public var replacementPath: String?
    public var calendar: FocusBlockSpec?
    public var docs: DocsOperationSpec?
    public var reason: String?

    public init(kind: OperationKind, sourcePath: String? = nil, sourceHash: String? = nil, destinationPath: String? = nil,
                replacementPath: String? = nil, calendar: FocusBlockSpec? = nil, docs: DocsOperationSpec? = nil, reason: String? = nil) {
        self.kind = kind; self.sourcePath = sourcePath; self.sourceHash = sourceHash; self.destinationPath = destinationPath
        self.replacementPath = replacementPath; self.calendar = calendar; self.docs = docs; self.reason = reason
    }

    public var summary: String {
        let src = sourcePath.map { ($0 as NSString).lastPathComponent } ?? docs?.documentTitle ?? ""
        let dst = destinationPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        switch kind {
        case .addReference: return "Add reference to \(src)"
        case .copyFile: return "Copy \(src) → \(dst)"
        case .createFolder: return "Create folder \(dst)"
        case .rename: return "Rename \(src) → \((dst as NSString).lastPathComponent)"
        case .move: return "Move \(src) → \(dst)"
        case .replaceContents: return "Replace contents of \(src)"
        case .createCalendarEvent: return "Create event “\(calendar?.title ?? "")” in \(calendar?.calendarTitle ?? "")"
        case .docsCreate: return "Create Google Doc “\(docs?.documentTitle ?? "")” as \(docs?.accountIdentity ?? "")"
        case .docsCopy: return "Copy Google Doc “\(docs?.documentTitle ?? "")” as \(docs?.accountIdentity ?? "")"
        case .docsEdit: return "Edit \(docs?.edits.count ?? 0) passage(s) in “\(docs?.documentTitle ?? "")” as \(docs?.accountIdentity ?? "")"
        }
    }
}

/// Immutable operation list reviewed by the user. A model may *propose* a plan
/// (as data); it can never approve or extend one.
public struct ActionPlan: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var operations: [PlannedOperation]
    public var initiator: String
    public var projectID: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, operations: [PlannedOperation], initiator: String = "user",
                projectID: UUID? = nil, createdAt: Date) {
        self.id = id; self.title = title; self.operations = operations; self.initiator = initiator
        self.projectID = projectID; self.createdAt = createdAt
    }

    /// Hash over the plan identity and exact operations. Any change invalidates approval.
    public var hash: String {
        struct Hashable_: Encodable { let id: UUID; let operations: [PlannedOperation] }
        let data = (try? JSON.canonicalEncoder.encode(Hashable_(id: id, operations: operations))) ?? Data()
        return Hashing.sha256Hex(data)
    }

    /// Button label naming the exact action count, e.g. "Apply 3 moves".
    public var applyLabel: String {
        let kinds = Set(operations.map(\.kind))
        let n = operations.count
        if kinds.count == 1, let k = kinds.first {
            let noun: String
            switch k {
            case .move: noun = n == 1 ? "move" : "moves"
            case .rename: noun = n == 1 ? "rename" : "renames"
            case .copyFile: noun = n == 1 ? "copy" : "copies"
            case .createFolder: noun = n == 1 ? "folder" : "folders"
            default: noun = n == 1 ? "change" : "changes"
            }
            return "Apply \(n) \(noun)"
        }
        return "Apply \(n) changes"
    }
}

public enum ActionState: String, Codable, CaseIterable, Sendable {
    case proposed, reviewed, approved, validating, executing, verifying, succeeded
    case rejected, expired, cancelled, failed, partiallyCompleted, outcomeUnknown

    public var isTerminal: Bool {
        [.succeeded, .rejected, .expired, .cancelled, .failed, .partiallyCompleted, .outcomeUnknown].contains(self)
    }

    static let transitions: [ActionState: Set<ActionState>] = [
        .proposed: [.reviewed, .rejected, .expired, .cancelled],
        .reviewed: [.approved, .rejected, .expired, .cancelled],
        .approved: [.validating, .expired, .cancelled],
        .validating: [.executing, .failed, .cancelled, .expired],
        .executing: [.verifying, .failed, .partiallyCompleted, .outcomeUnknown, .cancelled],
        .verifying: [.executing, .succeeded, .failed, .partiallyCompleted, .outcomeUnknown],
        .outcomeUnknown: [.succeeded, .failed, .partiallyCompleted],
    ]

    public func canTransition(to next: ActionState) -> Bool { Self.transitions[self]?.contains(next) ?? false }
}

public enum OperationStatus: String, Codable, Sendable { case pending, succeeded, failed, skipped, outcomeUnknown }

public struct OperationResult: Codable, Hashable, Sendable {
    public var index: Int
    public var status: OperationStatus
    public var verified: Bool
    public var detail: String?
    public var resultPath: String?
    public var resultHash: String?
    public var externalID: String?
}

public struct ActionRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var plan: ActionPlan
    public var state: ActionState
    public var results: [OperationResult]
    public var error: String?
    public var policyDecision: String?
    public let createdAt: Date
    public var updatedAt: Date
}

import Foundation

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var active: Bool
    public var defaultProvider: ProviderID?
    public var disclosure: DisclosurePolicy
    public var notes: String
    public let createdAt: Date
    public var lastOpenedAt: Date?
    public var snoozedUntil: Date?

    public init(id: UUID = UUID(), name: String, active: Bool = true, defaultProvider: ProviderID? = nil,
                disclosure: DisclosurePolicy = .init(), notes: String = "", createdAt: Date,
                lastOpenedAt: Date? = nil, snoozedUntil: Date? = nil) {
        self.id = id; self.name = name; self.active = active; self.defaultProvider = defaultProvider
        self.disclosure = disclosure; self.notes = notes; self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt; self.snoozedUntil = snoozedUntil
    }
}

public struct Root: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var bookmark: Data?
    public var extractContent: Bool
    public var disclosure: DisclosurePolicy
    public var isProtected: Bool
    public var enabled: Bool
    public let addedAt: Date
    public var lastScanAt: Date?

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum IndexStatus: String, Codable, Sendable {
    case pending, indexed, partial, metadataOnly, unsupported, encrypted, failed, placeholder, tooLarge

    public var label: String {
        switch self {
        case .pending: return "Waiting to index"
        case .indexed: return "Indexed"
        case .partial: return "Partially indexed"
        case .metadataOnly: return "Metadata only"
        case .unsupported: return "Open only (no text extraction)"
        case .encrypted: return "Encrypted — not readable"
        case .failed: return "Could not read"
        case .placeholder: return "Cloud placeholder — not downloaded"
        case .tooLarge: return "Too large — metadata only"
        }
    }
}

public enum Availability: String, Codable, Sendable {
    case available, missing, cloudOnly, inaccessible
}

public struct FileAsset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var rootID: UUID?
    public var path: String
    public var name: String
    public var ext: String
    public var size: Int
    public var modifiedAt: Date?
    public var resourceIdentity: String?
    public var contentHash: String?
    public var availability: Availability
    public var indexStatus: IndexStatus
    public var indexDetail: String?
    public var isManagedCopy: Bool
    public var tags: [String]
    public var lastSeenAt: Date
    public var lastIndexedAt: Date?

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum ItemKind: String, Codable, Sendable { case file, cloudDoc, event, task }

/// Reference / working copy / snapshot — never hidden from the user (spec §5).
public enum FileMode: String, Codable, Sendable {
    case reference, workingCopy, snapshot
    public var label: String {
        switch self {
        case .reference: return "Original"
        case .workingCopy: return "Working copy"
        case .snapshot: return "Snapshot"
        }
    }
}

public struct ProjectItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let kind: ItemKind
    public let targetID: UUID
    public var mode: FileMode
    public var reason: String?
    public var confirmed: Bool
    public let addedAt: Date
}

public struct Checkpoint: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var note: String
    public var nextStep: String?
    public var sourceRefs: [SourceRef]
    public let createdAt: Date
}

public enum WorkingCopyState: String, Codable, Sendable {
    case current, sourceChanged, copyChanged, conflict, sourceMissing
    public var label: String {
        switch self {
        case .current: return "Up to date"
        case .sourceChanged: return "Original changed (stale copy)"
        case .copyChanged: return "Copy edited"
        case .conflict: return "Both changed — review needed"
        case .sourceMissing: return "Original missing"
        }
    }
}

public struct WorkingCopy: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var sourceAssetID: UUID?
    public var sourcePath: String
    public var baseHash: String
    public var copyPath: String
    public var copyHash: String
    public let createdAt: Date
    public var state: WorkingCopyState
    public var ruleID: UUID?
}

public struct CopyRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var rootID: UUID
    public var pattern: String
    public var destination: String
    public var maxFiles: Int
    public var maxBytes: Int
    public var copiedFiles: Int
    public var copiedBytes: Int
    public var enabled: Bool
    public var expiresAt: Date?
    public let createdAt: Date
}

/// Source reference attached to excerpts, memories and checkpoints.
public struct SourceRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case localFile, googleDoc, calendarEvent, conversation, user }
    public var kind: Kind
    public var id: String
    public var title: String
    public var locator: String?
    public var version: String?
    public var retrievedAt: Date?
    public var accountID: UUID?
    public var tabID: String?

    public init(kind: Kind, id: String, title: String, locator: String? = nil, version: String? = nil,
                retrievedAt: Date? = nil, accountID: UUID? = nil, tabID: String? = nil) {
        self.kind = kind; self.id = id; self.title = title; self.locator = locator
        self.version = version; self.retrievedAt = retrievedAt; self.accountID = accountID; self.tabID = tabID
    }
}

import Foundation

public enum ConnectorStatus: String, Codable, Sendable {
    case connected, expired, revoked, restricted, disconnected
}

public struct ConnectorAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var provider: String
    /// Stable provider identity (Google `sub`), never just the email (spec §6).
    public var subject: String
    public var displayIdentity: String
    public var scopes: [String]
    public var keychainRef: String
    public var status: ConnectorStatus
    public var lastRefresh: Date?
    public let createdAt: Date
}

public enum Freshness: String, Codable, Sendable {
    case current, cached, stale, unavailable, unknown
    public var label: String {
        switch self {
        case .current: return "Current"
        case .cached: return "Cached"
        case .stale: return "Stale — refresh needed"
        case .unavailable: return "Unavailable"
        case .unknown: return "Not checked"
        }
    }
}

public struct ExtractionCoverage: Codable, Hashable, Sendable {
    public var tabsTotal: Int = 0
    public var tabsRead: Int = 0
    public var paragraphs: Int = 0
    public var tables: Int = 0
    public var links: Int = 0
    /// Human-readable omissions: "2 drawings", "1 equation", "comments not read".
    public var omissions: [String] = []
    public var truncated: Bool = false
    public init() {}

    public var isComplete: Bool { omissions.isEmpty && !truncated && tabsRead == tabsTotal }
    public var summary: String {
        var parts = ["Read \(tabsRead) of \(tabsTotal) tab(s)"]
        if !omissions.isEmpty { parts.append("not read: " + omissions.joined(separator: ", ")) }
        if truncated { parts.append("truncated") }
        return parts.joined(separator: "; ")
    }
}

public struct CloudAsset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var accountID: UUID
    public var providerFileID: String
    public var name: String
    public var mimeType: String
    public var canonicalURL: String?
    public var parents: [String]
    public var capabilities: [String: Bool]
    public var version: String?
    public var revisionID: String?
    public var modifiedTime: Date?
    public var retrievedAt: Date?
    public var freshness: Freshness
    public var coverage: ExtractionCoverage?
    public var disclosure: DisclosurePolicy

    public var isGoogleDoc: Bool { mimeType == "application/vnd.google-apps.document" }
}

public struct DocumentSegment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var assetID: UUID
    public var sourceKind: SourceRef.Kind
    public var tabID: String?
    public var sourceVersion: String?
    public var heading: String?
    public var startIndex: Int?
    public var endIndex: Int?
    public var ordinal: Int
    public var text: String
}

public enum RuleStatus: String, Codable, Sendable { case candidate, explicit, rejected, superseded }

public enum ProfileField: String, Codable, CaseIterable, Sendable {
    case hierarchy, naming, placement, exceptions, lifecycle, protection
    public var label: String { rawValue.capitalized }
}

public struct OrganizationRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var scope: String
    public var field: ProfileField
    public var statement: String
    public var status: RuleStatus
    public var evidence: [String]
    public var observationCount: Int
    public var exceptions: [String]
    public var confirmedAt: Date?
    public var supersededBy: UUID?
    public let createdAt: Date
}

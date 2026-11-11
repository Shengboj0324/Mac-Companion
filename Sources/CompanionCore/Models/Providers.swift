import Foundation

public enum ProviderID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case openai, anthropic, deepseek
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .deepseek: return "DeepSeek"
        }
    }

    /// Model names are configuration, not permanent product assumptions (spec §14).
    public static let defaultModels: [String: String] = [
        ProviderID.openai.rawValue: "gpt-5.1",
        ProviderID.anthropic.rawValue: "claude-opus-5-5",
        ProviderID.deepseek.rawValue: "deepseek-chat",
    ]

    public var dataPolicyURL: URL {
        switch self {
        case .openai: return URL(string: "https://developers.openai.com/api/docs/guides/your-data")!
        case .anthropic: return URL(string: "https://privacy.anthropic.com")!
        case .deepseek: return URL(string: "https://api-docs.deepseek.com/")!
        }
    }

    /// The only network hosts this adapter may contact.
    public var allowedHost: String {
        switch self {
        case .openai: return "api.openai.com"
        case .anthropic: return "api.anthropic.com"
        case .deepseek: return "api.deepseek.com"
        }
    }
}

/// Per-root / per-project / per-document cloud disclosure rule (spec §16).
public enum DisclosureMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case askBeforeSending
    case allowSelected

    public var label: String {
        switch self {
        case .localOnly: return "Local only"
        case .askBeforeSending: return "Ask before sending"
        case .allowSelected: return "Allow selected providers"
        }
    }
}

public struct DisclosurePolicy: Codable, Hashable, Sendable {
    public var mode: DisclosureMode
    public var allowedProviders: Set<ProviderID>
    /// Further policies that must all permit disclosure (e.g. root ∧ project ∧ document).
    public var constraints: [DisclosurePolicy]

    public init(mode: DisclosureMode = .askBeforeSending, allowedProviders: Set<ProviderID> = [], constraints: [DisclosurePolicy] = []) {
        self.mode = mode; self.allowedProviders = allowedProviders; self.constraints = constraints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(DisclosureMode.self, forKey: .mode)
        allowedProviders = try c.decode(Set<ProviderID>.self, forKey: .allowedProviders)
        constraints = try c.decodeIfPresent([DisclosurePolicy].self, forKey: .constraints) ?? []
    }

    /// Ordered from most to least restrictive.
    public enum Decision: Int, Equatable, Comparable, Sendable {
        case deny = 0, ask = 1, allow = 2
        public static func < (a: Decision, b: Decision) -> Bool { a.rawValue < b.rawValue }
    }

    public func decision(for provider: ProviderID) -> Decision {
        let own: Decision
        switch mode {
        case .localOnly: own = .deny
        case .askBeforeSending: own = allowedProviders.contains(provider) ? .allow : .ask
        case .allowSelected: own = allowedProviders.contains(provider) ? .allow : .deny
        }
        return constraints.reduce(own) { min($0, $1.decision(for: provider)) }
    }

    /// Combining policies: a provider is allowed only if every source level allows it;
    /// the most restrictive decision wins.
    public func intersect(_ other: DisclosurePolicy) -> DisclosurePolicy {
        var r = self
        r.constraints.append(other)
        return r
    }
}

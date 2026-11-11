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
    public init(mode: DisclosureMode = .askBeforeSending, allowedProviders: Set<ProviderID> = []) {
        self.mode = mode; self.allowedProviders = allowedProviders
    }

    public enum Decision: Equatable, Sendable { case allow, ask, deny }

    public func decision(for provider: ProviderID) -> Decision {
        switch mode {
        case .localOnly: return .deny
        case .askBeforeSending: return allowedProviders.contains(provider) ? .allow : .ask
        case .allowSelected: return allowedProviders.contains(provider) ? .allow : .deny
        }
    }

    /// Combining policies for a packet: the most restrictive wins.
    public func intersect(_ other: DisclosurePolicy) -> DisclosurePolicy {
        let order: [DisclosureMode] = [.localOnly, .allowSelected, .askBeforeSending]
        let a = order.firstIndex(of: mode)!, b = order.firstIndex(of: other.mode)!
        let mode = order[min(a, b)]
        let providers: Set<ProviderID>
        if self.mode == .askBeforeSending && other.mode == .askBeforeSending {
            providers = allowedProviders.intersection(other.allowedProviders)
        } else if self.mode == .askBeforeSending {
            providers = other.allowedProviders
        } else if other.mode == .askBeforeSending {
            providers = allowedProviders
        } else {
            providers = allowedProviders.intersection(other.allowedProviders)
        }
        return DisclosurePolicy(mode: mode, allowedProviders: providers)
    }
}

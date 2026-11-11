import Foundation

/// Holds adapters and Keychain-backed credentials. Keys never enter prompts, logs or the database.
public final class ProviderRegistry: @unchecked Sendable {
    private let secrets: SecretStore
    private let settings: SettingsStore
    private var adapters: [ProviderID: LLMProvider]

    public init(secrets: SecretStore, settings: SettingsStore, adapters: [ProviderID: LLMProvider]? = nil) {
        self.secrets = secrets
        self.settings = settings
        self.adapters = adapters ?? [.anthropic: AnthropicProvider(), .openai: OpenAIProvider(), .deepseek: DeepSeekProvider()]
    }

    public func adapter(_ id: ProviderID) -> LLMProvider? { adapters[id] }
    public func setAdapter(_ a: LLMProvider) { adapters[a.id] = a }

    public func hasKey(_ id: ProviderID) -> Bool { secrets.string(SecretAccounts.providerKey(id))?.isEmpty == false }
    public func key(_ id: ProviderID) -> String? { secrets.string(SecretAccounts.providerKey(id)) }

    public func setKey(_ key: String, for id: ProviderID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw CompanionError.invalidArgument("API key looks malformed") }
        try secrets.setString(trimmed, for: SecretAccounts.providerKey(id))
    }

    public func removeKey(_ id: ProviderID) throws { try secrets.delete(SecretAccounts.providerKey(id)) }

    public var configured: [ProviderID] { ProviderID.allCases.filter(hasKey) }

    public func model(for id: ProviderID) -> String {
        settings.get(Settings.providerModels)[id.rawValue] ?? ProviderID.defaultModels[id.rawValue] ?? ""
    }

    public func setModel(_ model: String, for id: ProviderID) {
        var m = settings.get(Settings.providerModels)
        m[id.rawValue] = model
        settings.set(Settings.providerModels, m)
    }

    /// Explicit connection test with a tiny non-personal prompt (no documents sent).
    public func testConnection(_ id: ProviderID) async throws -> String {
        guard let adapter = adapter(id), let key = key(id) else { throw CompanionError.notConfigured("\(id.displayName) key") }
        let req = LLMRequest(model: model(for: id), system: "Reply with the single word: ready",
                             messages: [.user("Connection test. Reply with: ready")], maxOutputTokens: 64)
        var text = ""
        for try await ev in adapter.stream(req, apiKey: key) { if case .textDelta(let t) = ev { text += t } }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

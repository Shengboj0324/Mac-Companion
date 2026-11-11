import Foundation

public struct ToolSpec: Sendable, Hashable {
    public let name: String
    public let description: String
    /// JSON Schema object.
    public let parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct ToolCall: Sendable, Hashable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) { self.id = id; self.name = name; self.argumentsJSON = argumentsJSON }
}

/// Provider-neutral message used by every adapter.
public enum LLMMessage: Sendable, Hashable {
    case user(String)
    case assistant(String)
    /// Opaque provider turn state, replayed only to the adapter that produced it.
    case assistantRaw(provider: ProviderID, json: String, text: String)
    case toolResult(callID: String, name: String, content: String, isError: Bool)
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [LLMMessage]
    public var tools: [ToolSpec]
    public var maxOutputTokens: Int
    public init(model: String, system: String, messages: [LLMMessage], tools: [ToolSpec] = [], maxOutputTokens: Int = 8_000) {
        self.model = model; self.system = system; self.messages = messages; self.tools = tools; self.maxOutputTokens = maxOutputTokens
    }
}

public enum ProviderEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(ToolCall)
    case usage(input: Int, output: Int)
    /// Raw assistant turn for same-adapter tool-loop continuity.
    case turnState(String)
    case completed(stopReason: String?, requestID: String?)
}

public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var contextTokens: Int
    public var maxOutputTokens: Int
    public var tools: Bool
    public var images: Bool
    public var structuredOutput: Bool
}

/// Capability registry. Values are configuration and must be rechecked at release (spec §14).
public enum CapabilityRegistry {
    public static func capabilities(provider: ProviderID, model: String) -> ModelCapabilities {
        switch provider {
        case .anthropic:
            return ModelCapabilities(contextTokens: 1_000_000, maxOutputTokens: 128_000, tools: true, images: true, structuredOutput: true)
        case .openai:
            return ModelCapabilities(contextTokens: 400_000, maxOutputTokens: 128_000, tools: true, images: true, structuredOutput: true)
        case .deepseek:
            return ModelCapabilities(contextTokens: 128_000, maxOutputTokens: 8_000, tools: true, images: false, structuredOutput: false)
        }
    }
}

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func stream(_ request: LLMRequest, apiKey: String) -> AsyncThrowingStream<ProviderEvent, Error>
}

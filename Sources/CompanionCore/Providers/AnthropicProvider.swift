import Foundation

/// Anthropic Messages API adapter (raw HTTPS; no Swift SDK exists).
public struct AnthropicProvider: LLMProvider {
    public let id = ProviderID.anthropic
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    /// Models that accept server-side refusal fallbacks.
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-1", "claude-fable-5-2"]
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    func body(_ r: LLMRequest) throws -> Data {
        var messages: [[String: Any]] = []
        func append(role: String, block: [String: Any]) {
            if let last = messages.last, last["role"] as? String == role, var content = last["content"] as? [[String: Any]] {
                content.append(block)
                messages[messages.count - 1]["content"] = content
            } else {
                messages.append(["role": role, "content": [block]])
            }
        }
        for m in r.messages {
            switch m {
            case .user(let t): append(role: "user", block: ["type": "text", "text": t])
            case .assistant(let t): if !t.isEmpty { append(role: "assistant", block: ["type": "text", "text": t]) }
            case .assistantRaw(let p, let json, let text):
                if p == .anthropic, let blocks = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
                    for b in blocks { append(role: "assistant", block: b) }
                } else if !text.isEmpty { append(role: "assistant", block: ["type": "text", "text": text]) }
            case .toolResult(let id, _, let content, let isError):
                append(role: "user", block: ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError])
            }
        }
        var body: [String: Any] = ["model": r.model, "max_tokens": r.maxOutputTokens, "stream": true,
                                   "system": r.system, "messages": messages]
        if !r.tools.isEmpty {
            body["tools"] = r.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.anyValue] }
        }
        if Self.fallbackModels.contains(r.model) { body["fallbacks"] = "default" }
        return try JSON.data(body)
    }

    static func appendField(_ blocks: inout [Int: [String: Any]], _ index: Int, _ key: String, _ value: String) {
        var block = blocks[index] ?? [:]
        block[key] = (block[key] as? String ?? "") + value
        blocks[index] = block
    }

    public func stream(_ request: LLMRequest, apiKey: String) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ProviderHTTP.validateHost(Self.endpoint, provider: id)
                    var req = URLRequest(url: Self.endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
                    if Self.fallbackModels.contains(request.model) {
                        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    }
                    req.httpBody = try body(request)
                    let (http, lines) = try await transport.lines(for: req)
                    guard (200..<300).contains(http.statusCode) else {
                        throw ProviderHTTP.error(status: http.statusCode, body: await ProviderHTTP.collect(lines), provider: id)
                    }
                    let requestID = http.value(forHTTPHeaderField: "request-id")
                    var parser = SSEParser()
                    var blocks: [Int: [String: Any]] = [:]
                    var partialJSON: [Int: String] = [:]
                    var inputTokens = 0, outputTokens = 0
                    var stopReason: String?
                    for try await line in lines {
                        guard let ev = parser.feed(line), let obj = try? JSON.object(Data(ev.data.utf8)) else { continue }
                        switch obj["type"] as? String {
                        case "message_start":
                            let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                            inputTokens = (usage?["input_tokens"] as? Int ?? 0) + (usage?["cache_read_input_tokens"] as? Int ?? 0)
                                + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                        case "content_block_start":
                            let index = obj["index"] as? Int ?? 0
                            blocks[index] = obj["content_block"] as? [String: Any] ?? [:]
                        case "content_block_delta":
                            let index = obj["index"] as? Int ?? 0
                            let delta = obj["delta"] as? [String: Any] ?? [:]
                            switch delta["type"] as? String {
                            case "text_delta":
                                let t = delta["text"] as? String ?? ""
                                Self.appendField(&blocks, index, "text", t)
                                continuation.yield(.textDelta(t))
                            case "input_json_delta":
                                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                            case "thinking_delta":
                                Self.appendField(&blocks, index, "thinking", delta["thinking"] as? String ?? "")
                            case "signature_delta":
                                Self.appendField(&blocks, index, "signature", delta["signature"] as? String ?? "")
                            default: break
                            }
                        case "content_block_stop":
                            let index = obj["index"] as? Int ?? 0
                            if blocks[index]?["type"] as? String == "tool_use" {
                                let args = partialJSON[index].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                                blocks[index]?["input"] = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) ?? [String: Any]()
                                continuation.yield(.toolCall(ToolCall(id: blocks[index]?["id"] as? String ?? UUID().uuidString,
                                                                      name: blocks[index]?["name"] as? String ?? "", argumentsJSON: args)))
                            }
                        case "message_delta":
                            stopReason = (obj["delta"] as? [String: Any])?["stop_reason"] as? String ?? stopReason
                            if let out = (obj["usage"] as? [String: Any])?["output_tokens"] as? Int { outputTokens = out }
                        case "error":
                            let err = obj["error"] as? [String: Any]
                            let type = err?["type"] as? String ?? ""
                            let kind: ProviderErrorKind = type == "overloaded_error" ? .overloaded : type == "rate_limit_error" ? .rateLimited : .server
                            throw CompanionError.provider(kind, Redactor.redact(err?["message"] as? String ?? ""))
                        default: break
                        }
                    }
                    continuation.yield(.usage(input: inputTokens, output: outputTokens))
                    if stopReason == "refusal" { throw CompanionError.provider(.refused, "") }
                    let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
                        .filter { ["text", "tool_use", "thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
                    if let data = try? JSONSerialization.data(withJSONObject: ordered) {
                        continuation.yield(.turnState(String(decoding: data, as: UTF8.self)))
                    }
                    continuation.yield(.completed(stopReason: stopReason, requestID: requestID))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderHTTP.mapTransport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

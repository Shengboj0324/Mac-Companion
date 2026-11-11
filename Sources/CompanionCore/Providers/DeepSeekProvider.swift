import Foundation

/// DeepSeek adapter using its documented OpenAI-compatible Chat Completions mode.
/// Format compatibility does not imply identical behaviour (spec §14).
public struct DeepSeekProvider: LLMProvider {
    public let id = ProviderID.deepseek
    public static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    func body(_ r: LLMRequest) throws -> Data {
        var messages: [[String: Any]] = [["role": "system", "content": r.system]]
        for m in r.messages {
            switch m {
            case .user(let t): messages.append(["role": "user", "content": t])
            case .assistant(let t): messages.append(["role": "assistant", "content": t])
            case .assistantRaw(let p, let json, let text):
                if p == .deepseek, let msg = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                    messages.append(msg)
                } else { messages.append(["role": "assistant", "content": text]) }
            case .toolResult(let id, _, let content, _):
                messages.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        var body: [String: Any] = ["model": r.model, "messages": messages, "stream": true,
                                   "stream_options": ["include_usage": true], "max_tokens": min(r.maxOutputTokens, 8_000)]
        if !r.tools.isEmpty {
            body["tools"] = r.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters.anyValue]] }
        }
        return try JSON.data(body)
    }

    public func stream(_ request: LLMRequest, apiKey: String) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ProviderHTTP.validateHost(Self.endpoint, provider: id)
                    var req = URLRequest(url: Self.endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try body(request)
                    let (http, lines) = try await transport.lines(for: req)
                    guard (200..<300).contains(http.statusCode) else {
                        throw ProviderHTTP.error(status: http.statusCode, body: await ProviderHTTP.collect(lines), provider: id)
                    }
                    var parser = SSEParser()
                    var requestID: String?
                    var text = ""
                    var calls: [Int: (id: String, name: String, args: String)] = [:]
                    var finish: String?
                    for try await line in lines {
                        guard let ev = parser.feed(line) else { continue }
                        if ev.data == "[DONE]" { break }
                        guard let obj = try? JSON.object(Data(ev.data.utf8)) else { continue }
                        requestID = obj["id"] as? String ?? requestID
                        if let usage = obj["usage"] as? [String: Any] {
                            continuation.yield(.usage(input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0))
                        }
                        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                        if let f = choice["finish_reason"] as? String { finish = f }
                        let delta = choice["delta"] as? [String: Any] ?? [:]
                        if let t = delta["content"] as? String, !t.isEmpty { text += t; continuation.yield(.textDelta(t)) }
                        for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let i = tc["index"] as? Int ?? 0
                            var entry = calls[i] ?? (id: "", name: "", args: "")
                            if let id = tc["id"] as? String { entry.id = id }
                            let fn = tc["function"] as? [String: Any] ?? [:]
                            if let n = fn["name"] as? String { entry.name += n }
                            if let a = fn["arguments"] as? String { entry.args += a }
                            calls[i] = entry
                        }
                    }
                    let ordered = calls.keys.sorted().compactMap { calls[$0] }
                    for c in ordered { continuation.yield(.toolCall(ToolCall(id: c.id, name: c.name, argumentsJSON: c.args.isEmpty ? "{}" : c.args))) }
                    var raw: [String: Any] = ["role": "assistant", "content": text]
                    if !ordered.isEmpty {
                        raw["tool_calls"] = ordered.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.args]] }
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: raw) { continuation.yield(.turnState(String(decoding: data, as: UTF8.self))) }
                    if finish == "content_filter" { throw CompanionError.provider(.refused, "") }
                    continuation.yield(.completed(stopReason: finish, requestID: requestID))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderHTTP.mapTransport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

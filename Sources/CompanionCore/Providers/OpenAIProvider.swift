import Foundation

/// OpenAI Responses API adapter. Uses `store: false`; local state is canonical.
public struct OpenAIProvider: LLMProvider {
    public let id = ProviderID.openai
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    func body(_ r: LLMRequest) throws -> Data {
        var input: [[String: Any]] = []
        for m in r.messages {
            switch m {
            case .user(let t): input.append(["role": "user", "content": t])
            case .assistant(let t): if !t.isEmpty { input.append(["role": "assistant", "content": t]) }
            case .assistantRaw(let p, let json, let text):
                if p == .openai, let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
                    input.append(contentsOf: items)
                } else if !text.isEmpty { input.append(["role": "assistant", "content": text]) }
            case .toolResult(let id, _, let content, _):
                input.append(["type": "function_call_output", "call_id": id, "output": content])
            }
        }
        var body: [String: Any] = ["model": r.model, "instructions": r.system, "input": input, "stream": true,
                                   "store": false, "max_output_tokens": r.maxOutputTokens,
                                   "include": ["reasoning.encrypted_content"]]
        if !r.tools.isEmpty {
            body["tools"] = r.tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters.anyValue] }
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
                    var requestID = http.value(forHTTPHeaderField: "x-request-id")
                    var completed = false
                    for try await line in lines {
                        guard let ev = parser.feed(line), ev.data != "[DONE]", let obj = try? JSON.object(Data(ev.data.utf8)) else { continue }
                        switch obj["type"] as? String {
                        case "response.output_text.delta":
                            continuation.yield(.textDelta(obj["delta"] as? String ?? ""))
                        case "response.output_item.done":
                            if let item = obj["item"] as? [String: Any], item["type"] as? String == "function_call" {
                                continuation.yield(.toolCall(ToolCall(id: item["call_id"] as? String ?? UUID().uuidString,
                                                                      name: item["name"] as? String ?? "",
                                                                      argumentsJSON: item["arguments"] as? String ?? "{}")))
                            }
                        case "response.completed", "response.incomplete":
                            let response = obj["response"] as? [String: Any] ?? [:]
                            requestID = response["id"] as? String ?? requestID
                            let usage = response["usage"] as? [String: Any]
                            continuation.yield(.usage(input: usage?["input_tokens"] as? Int ?? 0, output: usage?["output_tokens"] as? Int ?? 0))
                            if let output = response["output"] as? [[String: Any]],
                               let data = try? JSONSerialization.data(withJSONObject: output) {
                                continuation.yield(.turnState(String(decoding: data, as: UTF8.self)))
                            }
                            let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                            continuation.yield(.completed(stopReason: reason ?? "end_turn", requestID: requestID))
                            completed = true
                        case "response.failed", "error":
                            let err = (obj["response"] as? [String: Any])?["error"] as? [String: Any] ?? obj["error"] as? [String: Any] ?? obj
                            let code = (err["code"] as? String ?? "").lowercased()
                            let kind: ProviderErrorKind = code.contains("rate") ? .rateLimited : code.contains("quota") ? .insufficientBalance : .server
                            throw CompanionError.provider(kind, Redactor.redact(err["message"] as? String ?? ""))
                        case "response.refusal.done":
                            throw CompanionError.provider(.refused, "")
                        default: break
                        }
                    }
                    if !completed { continuation.yield(.completed(stopReason: nil, requestID: requestID)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderHTTP.mapTransport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

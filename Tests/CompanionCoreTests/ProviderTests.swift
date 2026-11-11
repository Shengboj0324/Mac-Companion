import XCTest
@testable import CompanionCore

final class ProviderTests: XCTestCase {
    private func collect(_ s: AsyncThrowingStream<ProviderEvent, Error>) async throws -> [ProviderEvent] {
        var out: [ProviderEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    func testSSEParser() {
        var p = SSEParser()
        XCTAssertNil(p.feed("event: message_start"))
        XCTAssertEqual(p.feed("data: {\"a\":1}"), SSEParser.Event(event: "message_start", data: "{\"a\":1}"))
        XCTAssertNil(p.feed(": keepalive"))
        XCTAssertEqual(p.feed("data: [DONE]\r")?.data, "[DONE]")
    }

    func testAnthropicStreamingTextToolsUsageAndHeaders() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.host, "api.anthropic.com")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-test")
            let body = try JSON.object(req.httpBody!)
            XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertNil(body["temperature"])
            return .init(status: 200, lines: [
                "event: message_start", #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":120}}}"#,
                "event: content_block_start", #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                "event: content_block_delta", #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
                #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"search_sources","input":{}}}"#,
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"gaps\"}"}}"#,
                #"data: {"type":"content_block_stop","index":1}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
                #"data: {"type":"message_stop"}"#,
            ], headers: ["request-id": "req_9"])
        }
        let events = try await collect(AnthropicProvider(transport: transport).stream(
            LLMRequest(model: "claude-opus-5-5", system: "s", messages: [.user("hi")], tools: ToolRegistry.specs), apiKey: "sk-test"))
        XCTAssertEqual(events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined(), "Hello")
        XCTAssertTrue(events.contains(.toolCall(ToolCall(id: "tu_1", name: "search_sources", argumentsJSON: "{\"query\":\"gaps\"}"))))
        XCTAssertTrue(events.contains(.usage(input: 120, output: 42)))
        XCTAssertTrue(events.contains(.completed(stopReason: "tool_use", requestID: "req_9")))
        let state = events.compactMap { if case .turnState(let s) = $0 { return s }; return nil }.first
        XCTAssertTrue(state?.contains("tool_use") == true, "raw blocks kept for same-adapter tool loop")
    }

    func testAnthropicRefusalAndErrorMapping() async throws {
        let refusal = MockTransport { _ in .init(status: 200, lines: [#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#]) }
        await XCTAssertThrowsAsync(try await self.collect(AnthropicProvider(transport: refusal).stream(LLMRequest(model: "m", system: "", messages: [.user("x")]), apiKey: "k"))) {
            XCTAssertEqual($0 as? CompanionError, .provider(.refused, ""))
        }
        for (status, kind) in [(401, ProviderErrorKind.invalidKey), (402, .insufficientBalance), (404, .unsupportedModel), (429, .rateLimited), (529, .overloaded), (500, .server)] {
            let t = MockTransport { _ in .init(status: status, lines: [#"{"error":{"message":"nope sk-ant-secretsecretsecret"}}"#]) }
            await XCTAssertThrowsAsync(try await self.collect(AnthropicProvider(transport: t).stream(LLMRequest(model: "m", system: "", messages: [.user("x")]), apiKey: "k"))) { e in
                guard case .provider(let k, let msg)? = e as? CompanionError else { return XCTFail("\(e)") }
                XCTAssertEqual(k, kind)
                XCTAssertFalse(msg.contains("secretsecret"), "provider error messages are redacted")
            }
        }
    }

    func testOpenAIResponsesStreaming() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/responses")
            let body = try JSON.object(req.httpBody!)
            XCTAssertEqual(body["store"] as? Bool, false)
            return .init(status: 200, lines: [
                #"data: {"type":"response.output_text.delta","delta":"Hi "}"#,
                #"data: {"type":"response.output_text.delta","delta":"there"}"#,
                #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"read_excerpt","arguments":"{\"excerpt_id\":\"x\"}"}}"#,
                #"data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":50,"output_tokens":7},"output":[{"type":"function_call","call_id":"c1"}]}}"#,
            ])
        }
        let events = try await collect(OpenAIProvider(transport: transport).stream(LLMRequest(model: "gpt-5.1", system: "s", messages: [.user("x")]), apiKey: "k"))
        XCTAssertEqual(events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined(), "Hi there")
        XCTAssertTrue(events.contains(.usage(input: 50, output: 7)))
        XCTAssertTrue(events.contains { if case .toolCall(let c) = $0 { return c.name == "read_excerpt" }; return false })
    }

    func testDeepSeekChatCompletionsStreaming() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.host, "api.deepseek.com")
            return .init(status: 200, lines: [
                #"data: {"id":"d1","choices":[{"delta":{"content":"Answer"}}]}"#,
                #"data: {"id":"d1","choices":[{"delta":{"tool_calls":[{"index":0,"id":"t1","function":{"name":"search_sources","arguments":"{\"query\""}}]}}]}"#,
                #"data: {"id":"d1","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"x\"}"}}]},"finish_reason":"tool_calls"}]}"#,
                #"data: {"id":"d1","choices":[],"usage":{"prompt_tokens":30,"completion_tokens":5}}"#,
                "data: [DONE]",
            ])
        }
        let events = try await collect(DeepSeekProvider(transport: transport).stream(LLMRequest(model: "deepseek-chat", system: "s", messages: [.user("x")]), apiKey: "k"))
        XCTAssertTrue(events.contains(.textDelta("Answer")))
        XCTAssertTrue(events.contains(.toolCall(ToolCall(id: "t1", name: "search_sources", argumentsJSON: "{\"query\":\"x\"}"))))
        XCTAssertTrue(events.contains(.usage(input: 30, output: 5)))
    }

    func testRequestBodiesSerializeToolResultsPerProvider() throws {
        let msgs: [LLMMessage] = [.user("q"), .assistantRaw(provider: .anthropic, json: #"[{"type":"tool_use","id":"tu","name":"x","input":{}}]"#, text: ""),
                                  .toolResult(callID: "tu", name: "x", content: "r", isError: false)]
        let a = try JSON.object(AnthropicProvider().body(LLMRequest(model: "claude-opus-5-5", system: "s", messages: msgs)))
        let am = a["messages"] as! [[String: Any]]
        XCTAssertEqual(am.map { $0["role"] as! String }, ["user", "assistant", "user"])
        XCTAssertEqual(a["fallbacks"] as? String, "default")
        let o = try JSON.object(OpenAIProvider().body(LLMRequest(model: "gpt", system: "s", messages: msgs)))
        XCTAssertTrue((o["input"] as! [[String: Any]]).contains { $0["type"] as? String == "function_call_output" })
        let d = try JSON.object(DeepSeekProvider().body(LLMRequest(model: "deepseek-chat", system: "s", messages: msgs)))
        XCTAssertTrue((d["messages"] as! [[String: Any]]).contains { $0["role"] as? String == "tool" })
    }
}

final class BudgetTests: XCTestCase {
    func testReserveSettleWarnAndStop() throws {
        let t = TestEnv()
        t.env.settings.set(Settings.monthlyBudgetUSD, 1.0)
        let b = t.env.budget
        let r = try b.reserve(provider: .anthropic, model: "claude-opus-5-5", estimatedInput: 10_000, maxOutput: 4_000)
        XCTAssertEqual(b.status().reserved, 0.04 + 0.08, accuracy: 0.0001)
        let entry = b.settle(reservation: r, provider: .anthropic, model: "claude-opus-5-5", requestID: "x", inputTokens: 100_000, outputTokens: 20_000, estimatedInput: 0)
        XCTAssertEqual(entry.estimatedCost, 0.4 + 0.4, accuracy: 0.0001)
        XCTAssertFalse(entry.isEstimate)
        XCTAssertEqual(b.status().reserved, 0)
        XCTAssertTrue(b.status().isWarning)
        XCTAssertThrowsError(try b.reserve(provider: .anthropic, model: "claude-opus-5-5", estimatedInput: 50_000, maxOutput: 10_000)) {
            guard case .budgetExceeded = $0 as? CompanionError else { return XCTFail() }
        }
    }

    func testMissingUsageIsFlaggedAsEstimate() throws {
        let t = TestEnv()
        let r = try t.env.budget.reserve(provider: .openai, model: "unknown-model", estimatedInput: 100, maxOutput: 100)
        let e = t.env.budget.settle(reservation: r, provider: .openai, model: "unknown-model", requestID: nil, inputTokens: nil, outputTokens: nil, estimatedInput: 100)
        XCTAssertTrue(e.isEstimate)
    }

    func testIllustrativeArithmeticFromSpec() {
        let table = PriceTable(version: "test", rates: ["openai/a": .init(inputPerMillion: 1, outputPerMillion: 5)], fallback: .init(inputPerMillion: 3, outputPerMillion: 15))
        XCTAssertEqual(table.cost(.openai, "a", input: 3_600_000, output: 600_000).0, 6.60, accuracy: 0.001)
        XCTAssertEqual(table.cost(.openai, "b", input: 3_600_000, output: 600_000).0, 19.80, accuracy: 0.001)
    }
}

final class ConversationTests: XCTestCase {
    func testAskRequiresKeyButLocalFeaturesDoNot() async throws {
        let t = TestEnv()
        await XCTAssertThrowsAsync(try await self.drain(t.env.conversations.ask("hello", options: AskOptions(provider: .anthropic, projectID: nil)))) {
            guard case .notConfigured = $0 as? CompanionError else { return XCTFail("\($0)") }
        }
        t.temp.write("Root/a.txt", "offline search works")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        XCTAssertEqual(t.env.search.search("offline").count, 1)
    }

    func testConsentGateThenSendOnce() async throws {
        let t = TestEnv()
        try t.env.providers.setKey("sk-test", for: .anthropic)
        t.temp.write("Root/notes.txt", "mitochondria powerhouse")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        let p = try t.env.projects.create(name: "Bio")
        for a in t.env.indexing.assets() { try t.env.projects.addItem(projectID: p.id, kind: .file, targetID: a.id) }

        var options = AskOptions(provider: .anthropic, projectID: p.id)
        let first = try await drain(t.env.conversations.ask("mitochondria", options: options))
        guard let consent = first.compactMap({ if case .needsConsent(let i) = $0 { return i }; return nil }).first else { return XCTFail("expected consent gate") }
        XCTAssertEqual(t.provider.received.count, 0, "nothing sent before consent")

        options.oneTimeAllowed = Set(consent.map(\.id))
        let second = try await drain(t.env.conversations.ask("mitochondria", options: options))
        XCTAssertEqual(t.provider.received.count, 1)
        XCTAssertTrue(Self.text(t.provider.received[0].messages.last!).contains("powerhouse"))
        XCTAssertTrue(second.contains { if case .finished = $0 { return true }; return false })
        XCTAssertEqual(t.env.budget.usage().count, 1)
    }

    func testExcludeUnconsentedSendsNoSourceText() async throws {
        let t = TestEnv()
        try t.env.providers.setKey("sk-test", for: .anthropic)
        t.temp.write("Root/notes.txt", "classified ribosome")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        _ = try await drain(t.env.conversations.ask("ribosome", options: AskOptions(provider: .anthropic, projectID: nil, excludeUnconsented: true)))
        XCTAssertFalse(Self.text(t.provider.received[0].messages.last!).contains("classified"))
    }

    func testToolLoopProducesProposalWithoutExecuting() async throws {
        let provider = ScriptedProvider(scripts: [
            [.toolCall(ToolCall(id: "c1", name: "propose_memory", argumentsJSON: #"{"statement":"Source readings stay separate from drafts","kind":"preference"}"#)),
             .usage(input: 10, output: 5), .turnState("[]"), .completed(stopReason: "tool_use", requestID: "1")],
            [.textDelta("I proposed a memory for you to confirm."), .usage(input: 20, output: 8), .completed(stopReason: "end_turn", requestID: "2")],
        ])
        let t = TestEnv(provider: provider)
        try t.env.providers.setKey("sk-test", for: .anthropic)
        let events = try await drain(t.env.conversations.ask("remember my habit", options: AskOptions(provider: .anthropic, projectID: nil, excludeUnconsented: true)))
        let proposed = events.compactMap { if case .memoryProposal(let m) = $0 { return m }; return nil }
        XCTAssertEqual(proposed.first?.status, .proposed)
        XCTAssertEqual(proposed.first?.provenance, .aiInference)
        XCTAssertEqual(provider.received.count, 2)
        guard case .toolResult(_, _, let content, false) = provider.received[1].messages.last! else { return XCTFail() }
        XCTAssertTrue(content.contains("confirmation"))
        XCTAssertEqual(t.env.budget.usage().count, 2)
    }

    func testTransientFailureRetriesThenSucceeds() async throws {
        let provider = ScriptedProvider(scripts: [])
        provider.failures = [CompanionError.provider(.overloaded, "")]
        let t = TestEnv(provider: provider)
        try t.env.providers.setKey("sk-test", for: .anthropic)
        let events = try await drain(t.env.conversations.ask("hi", options: AskOptions(provider: .anthropic, projectID: nil, excludeUnconsented: true)))
        XCTAssertTrue(events.contains { if case .finished = $0 { return true }; return false })
        XCTAssertEqual(provider.received.count, 2)
    }

    func testInvalidKeyIsNotRetried() async throws {
        let provider = ScriptedProvider(scripts: [])
        provider.failures = [CompanionError.provider(.invalidKey, "")]
        let t = TestEnv(provider: provider)
        try t.env.providers.setKey("sk-test", for: .anthropic)
        await XCTAssertThrowsAsync(try await self.drain(t.env.conversations.ask("hi", options: AskOptions(provider: .anthropic, projectID: nil, excludeUnconsented: true))))
        XCTAssertEqual(provider.received.count, 1)
    }

    func testBudgetLimitBlocksRequest() async throws {
        let t = TestEnv()
        try t.env.providers.setKey("sk-test", for: .anthropic)
        t.env.settings.set(Settings.monthlyBudgetUSD, 0.0001)
        await XCTAssertThrowsAsync(try await self.drain(t.env.conversations.ask("hi", options: AskOptions(provider: .anthropic, projectID: nil, excludeUnconsented: true)))) {
            guard case .budgetExceeded = $0 as? CompanionError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(t.provider.received.count, 0)
    }

    func testPausedBlocksRequests() async throws {
        let t = TestEnv()
        try t.env.providers.setKey("sk-test", for: .anthropic)
        t.env.setPaused(true)
        await XCTAssertThrowsAsync(try await self.drain(t.env.conversations.ask("hi", options: AskOptions(provider: .anthropic, projectID: nil))))
    }

    func drain(_ s: AsyncThrowingStream<ConversationEvent, Error>) async throws -> [ConversationEvent] {
        var out: [ConversationEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    static func text(_ m: LLMMessage) -> String { ConversationService.text(m) }
}

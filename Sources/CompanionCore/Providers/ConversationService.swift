import Foundation

public enum ConversationEvent: Sendable {
    case packet(ContextPacket)
    case needsConsent([PacketItem])
    case textDelta(String)
    case toolActivity(String)
    case proposal(ActionRun)
    case memoryProposal(MemoryRecord)
    case usage(UsageEntry)
    case budgetWarning(BudgetStatus)
    case finished(ChatMessage)
}

public struct AskOptions: Sendable {
    public var provider: ProviderID
    public var projectID: UUID?
    public var conversationID: UUID?
    public var attached: [UUID]
    /// Items the user allowed for this request only ("Send once").
    public var oneTimeAllowed: Set<String>
    /// Proceed without the items that still need consent.
    public var excludeUnconsented: Bool
    public var maxOutputTokens: Int

    public init(provider: ProviderID, projectID: UUID?, conversationID: UUID? = nil, attached: [UUID] = [],
                oneTimeAllowed: Set<String> = [], excludeUnconsented: Bool = false, maxOutputTokens: Int = 4_000) {
        self.provider = provider; self.projectID = projectID; self.conversationID = conversationID; self.attached = attached
        self.oneTimeAllowed = oneTimeAllowed; self.excludeUnconsented = excludeUnconsented; self.maxOutputTokens = maxOutputTokens
    }
}

/// Request path: local retrieval → disclosure policy → context preview/consent →
/// budget reservation → model call → typed proposals → journal (spec §12).
public final class ConversationService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore
    private let registry: ProviderRegistry
    private let budget: BudgetService
    private let retrieval: RetrievalService
    private let tools: ToolRegistry
    private let builder = ContextPacketBuilder()
    public var retryDelay: @Sendable (Int) async -> Void = { attempt in try? await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt))) * 500_000_000) }

    init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore, registry: ProviderRegistry, budget: BudgetService,
         retrieval: RetrievalService, tools: ToolRegistry) {
        self.db = db; self.clock = clock; self.settings = settings; self.registry = registry; self.budget = budget
        self.retrieval = retrieval; self.tools = tools
    }

    // MARK: Conversations

    @discardableResult
    public func createConversation(projectID: UUID?, title: String) throws -> Conversation {
        let c = Conversation(id: UUID(), projectID: projectID, title: String(title.prefix(80)), createdAt: clock.now(), updatedAt: clock.now())
        try db.execute("INSERT INTO conversations(id, project_id, title, created_at, updated_at) VALUES(?,?,?,?,?)",
                       [c.id, projectID, c.title, c.createdAt, c.updatedAt])
        return c
    }

    public func conversations(projectID: UUID?) -> [Conversation] {
        let rows: [SQLRow]
        if let projectID { rows = (try? db.query("SELECT * FROM conversations WHERE project_id=? ORDER BY updated_at DESC", [projectID])) ?? [] }
        else { rows = (try? db.query("SELECT * FROM conversations ORDER BY updated_at DESC LIMIT 50")) ?? [] }
        return rows.compactMap { r in
            guard let id = r.uuid("id"), let c = r.date("created_at") else { return nil }
            return Conversation(id: id, projectID: r.uuid("project_id"), title: r.string("title") ?? "", createdAt: c,
                                updatedAt: r.date("updated_at") ?? c, summary: r.string("summary"))
        }
    }

    public func messages(_ conversationID: UUID) -> [ChatMessage] {
        ((try? db.query("SELECT * FROM messages WHERE conversation_id=? ORDER BY created_at", [conversationID])) ?? []).compactMap { r in
            guard let id = r.uuid("id"), let role = ChatRole(rawValue: r.string("role") ?? ""), let d = r.date("created_at") else { return nil }
            return ChatMessage(id: id, conversationID: conversationID, role: role, content: r.string("content") ?? "",
                               provider: r.string("provider").flatMap(ProviderID.init(rawValue:)), model: r.string("model"),
                               sourceRefs: r.json("source_refs", as: [SourceRef].self) ?? [], adapterState: r.string("adapter_state"), createdAt: d)
        }
    }

    public func deleteConversation(_ id: UUID) throws { try db.execute("DELETE FROM conversations WHERE id=?", [id]) }

    private func save(_ m: ChatMessage) {
        try? db.execute("""
            INSERT INTO messages(id, conversation_id, role, content, provider, model, source_refs, adapter_state, created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [m.id, m.conversationID, m.role.rawValue, m.content, m.provider?.rawValue, m.model,
                  (try? JSON.encode(m.sourceRefs)) ?? "[]", m.adapterState, m.createdAt])
        try? db.execute("UPDATE conversations SET updated_at=? WHERE id=?", [m.createdAt, m.conversationID])
    }

    // MARK: Preview

    /// Builds the packet without sending anything — used by the request inspector.
    public func preview(_ request: String, options: AskOptions) -> ContextPacket {
        var items = retrieval.gather(request: request, projectID: options.projectID, attached: options.attached)
        items += historyItems(options)
        return builder.build(request: request, provider: options.provider, items: items, oneTimeAllowed: options.oneTimeAllowed)
    }

    private func historyItems(_ options: AskOptions) -> [PacketItem] {
        guard let cid = options.conversationID else { return [] }
        let policy = retrieval.projectPolicy(options.projectID)
        return messages(cid).suffix(10).filter { $0.role == .user || $0.role == .assistant }.map {
            PacketItem(id: "turn:\($0.id)", kind: .turn, title: "Earlier \($0.role.rawValue) turn", text: $0.content,
                       source: SourceRef(kind: .conversation, id: $0.id.uuidString, title: "Conversation"), policy: policy)
        }
    }

    // MARK: Ask

    public func ask(_ request: String, options: AskOptions) -> AsyncThrowingStream<ConversationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, options: options, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: String, options: AskOptions, emit: @Sendable (ConversationEvent) -> Void) async throws {
        guard !settings.get(Settings.paused) else { throw CompanionError.policyViolation("Companion is paused") }
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CompanionError.invalidArgument("Empty request") }
        guard let adapter = registry.adapter(options.provider), let key = registry.key(options.provider) else {
            throw CompanionError.notConfigured("Add a \(options.provider.displayName) API key in Settings to ask questions. Search and opening files work without one.")
        }
        let packet = preview(trimmed, options: options)
        emit(.packet(packet))
        if !packet.needsConsent.isEmpty && !options.excludeUnconsented {
            emit(.needsConsent(packet.needsConsent))
            return
        }
        // Final policy check immediately before transmission.
        try builder.revalidate(packet, currentPolicy: { self.retrieval.current($0, projectID: options.projectID) }, oneTimeAllowed: options.oneTimeAllowed)

        let conversationID = try options.conversationID ?? createConversation(projectID: options.projectID, title: trimmed).id
        let model = registry.model(for: options.provider)
        let userMessage = ChatMessage(id: UUID(), conversationID: conversationID, role: .user, content: trimmed, provider: nil, model: nil,
                                      sourceRefs: packet.outboundSources, adapterState: nil, createdAt: clock.now())
        save(userMessage)

        // Portable history: allowed earlier turns as plain messages (no foreign adapter state).
        var messages: [LLMMessage] = packet.included.filter { $0.kind == .turn }.compactMap { item in
            item.title.contains("user") ? .user(item.text) : .assistant(item.text)
        }
        let context = packet.renderedContext
        messages.append(.user(context.isEmpty ? trimmed : "Context from the user's sources:\n\n\(context)\n\nRequest: \(trimmed)"))

        let toolContext = ToolRegistry.Context(provider: options.provider, projectID: options.projectID, oneTimeAllowed: options.oneTimeAllowed)
        var fullText = ""
        var lastState: String?
        for step in 0..<ToolRegistry.maxSteps {
            try Task.checkCancellation()
            let req = LLMRequest(model: model, system: packet.system, messages: messages, tools: ToolRegistry.specs, maxOutputTokens: options.maxOutputTokens)
            let estimate = TokenEstimator.estimate(packet.system) + messages.reduce(0) { $0 + TokenEstimator.estimate(Self.text($1)) } + 1_500
            let reservation = try budget.reserve(provider: options.provider, model: model, estimatedInput: estimate, maxOutput: options.maxOutputTokens)
            var stepText = ""
            var calls: [ToolCall] = []
            var usage: (Int, Int)?
            var requestID: String?
            var attempt = 0
            while true {
                do {
                    for try await ev in adapter.stream(req, apiKey: key) {
                        switch ev {
                        case .textDelta(let t): stepText += t; emit(.textDelta(t))
                        case .toolCall(let c): calls.append(c)
                        case .usage(let i, let o): usage = (i, o)
                        case .turnState(let s): lastState = s
                        case .completed(_, let rid): requestID = rid
                        }
                    }
                    break
                } catch let e as CompanionError {
                    // Bounded retry only for transient failures before any output was shown.
                    if case .provider(let kind, _) = e, kind.isTransient, stepText.isEmpty, calls.isEmpty, attempt < 2 {
                        attempt += 1
                        await retryDelay(attempt)
                        continue
                    }
                    budget.settle(reservation: reservation, provider: options.provider, model: model, requestID: requestID,
                                  inputTokens: usage?.0, outputTokens: usage?.1, estimatedInput: estimate)
                    throw e
                } catch {
                    budget.release(reservation)
                    throw error is CancellationError ? CompanionError.cancelled : error
                }
            }
            let entry = budget.settle(reservation: reservation, provider: options.provider, model: model, requestID: requestID,
                                      inputTokens: usage?.0, outputTokens: usage?.1, estimatedInput: estimate)
            emit(.usage(entry))
            let status = budget.status()
            if status.isWarning { emit(.budgetWarning(status)) }
            fullText += stepText
            guard !calls.isEmpty else { break }
            if step == ToolRegistry.maxSteps - 1 { fullText += "\n\n(Stopped after the maximum number of tool steps.)"; break }

            messages.append(.assistantRaw(provider: options.provider, json: lastState ?? "[]", text: stepText))
            for call in calls {
                emit(.toolActivity(Self.describe(call)))
                switch tools.run(call, context: toolContext) {
                case .result(let r): messages.append(.toolResult(callID: call.id, name: call.name, content: r, isError: false))
                case .error(let e): messages.append(.toolResult(callID: call.id, name: call.name, content: e, isError: true))
                case .proposal(let run, let r): emit(.proposal(run)); messages.append(.toolResult(callID: call.id, name: call.name, content: r, isError: false))
                case .memoryProposal(let m, let r): emit(.memoryProposal(m)); messages.append(.toolResult(callID: call.id, name: call.name, content: r, isError: false))
                }
            }
        }
        let reply = ChatMessage(id: UUID(), conversationID: conversationID, role: .assistant, content: fullText, provider: options.provider,
                                model: model, sourceRefs: packet.outboundSources, adapterState: nil, createdAt: clock.now())
        save(reply)
        emit(.finished(reply))
    }

    static func text(_ m: LLMMessage) -> String {
        switch m {
        case .user(let t), .assistant(let t): return t
        case .assistantRaw(_, let j, _): return j
        case .toolResult(_, _, let c, _): return c
        }
    }

    static func describe(_ call: ToolCall) -> String {
        switch call.name {
        case "search_sources": return "Searching your sources…"
        case "read_excerpt": return "Reading an excerpt…"
        case "list_upcoming_events": return "Checking upcoming events…"
        case "propose_memory": return "Proposing something to remember…"
        case "propose_working_copy": return "Preparing a copy proposal for your review…"
        case "propose_focus_block": return "Preparing a focus-block proposal for your review…"
        default: return "Using \(call.name)…"
        }
    }
}

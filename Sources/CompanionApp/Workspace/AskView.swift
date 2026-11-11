import SwiftUI
import CompanionCore

@MainActor
final class AskSession: ObservableObject {
    @Published var prompt = ""
    @Published var transcript: [ChatMessage] = []
    @Published var streaming = ""
    @Published var activity: String?
    @Published var running = false
    @Published var consent: [PacketItem]?
    @Published var packet: ContextPacket?
    @Published var error: String?
    @Published var proposals: [ActionRun] = []
    @Published var memoryProposals: [MemoryRecord] = []
    @Published var conversationID: UUID?
    var lastRequest = ""
    private var task: Task<Void, Never>?

    func send(model: AppModel, provider: ProviderID, oneTime: Set<String> = [], exclude: Bool = false) {
        let request = lastRequest.isEmpty || !prompt.isEmpty ? prompt : lastRequest
        guard !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lastRequest = request
        error = nil; consent = nil; streaming = ""; activity = nil; running = true
        let options = AskOptions(provider: provider, projectID: model.selectedProjectID, conversationID: conversationID,
                                 oneTimeAllowed: oneTime, excludeUnconsented: exclude)
        let stream = model.env.conversations.ask(request, options: options)
        task = Task {
            do {
                for try await ev in stream {
                    switch ev {
                    case .packet(let p): packet = p
                    case .needsConsent(let items): consent = items
                    case .textDelta(let t): streaming += t
                    case .toolActivity(let a): activity = a
                    case .proposal(let r): proposals.append(r)
                    case .memoryProposal(let m): memoryProposals.append(m)
                    case .usage: break
                    case .budgetWarning(let s): error = String(format: "Budget warning: $%.2f of $%.0f used this month.", s.spent, s.limit)
                    case .finished(let m):
                        conversationID = m.conversationID
                        transcript = model.env.conversations.messages(m.conversationID)
                        streaming = ""; prompt = ""
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            running = false; activity = nil
            model.reload()
        }
    }

    /// Stop: cancels the stream; anything already sent cannot be recalled.
    func stop() { task?.cancel(); running = false; activity = "Stopped." }

    func newConversation() { conversationID = nil; transcript = []; streaming = ""; packet = nil; proposals = []; memoryProposals = []; error = nil }
}

struct AskView: View {
    @ObservedObject var model: AppModel
    @StateObject private var session = AskSession()
    @State private var provider: ProviderID = .anthropic
    @State private var showInspector = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Ask", subtitle: model.selectedProject.map { "Project: \($0.name)" } ?? "No project selected — only global memories and search")
                Picker("Provider", selection: $provider) {
                    ForEach(ProviderID.allCases) { p in Text(p.displayName + (model.env.providers.hasKey(p) ? "" : " (no key)")).tag(p) }
                }.frame(width: 240)
                Button("New conversation") { session.newConversation() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.transcript) { m in MessageBubble(message: m) }
                    if !session.streaming.isEmpty {
                        MessageBubble(message: ChatMessage(id: UUID(), conversationID: UUID(), role: .assistant, content: session.streaming,
                                                           provider: provider, model: nil, sourceRefs: [], adapterState: nil, createdAt: Date()))
                    }
                    if let a = session.activity { Label(a, systemImage: "gearshape.2").font(.caption).foregroundStyle(.secondary) }
                    ForEach(session.proposals) { run in
                        HStack { Image(systemName: "checklist"); Text("Proposed: \(run.plan.title) — not applied"); Spacer()
                            Button("Review") { model.review(run) } }
                            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.1)))
                    }
                    ForEach(session.memoryProposals) { m in
                        HStack { Image(systemName: "brain"); Text("Remember: “\(m.statement)”?"); Spacer()
                            Button("Confirm") { try? model.env.memory.confirm(m.id); session.memoryProposals.removeAll { $0.id == m.id } }
                            Button("Discard") { try? model.env.memory.forget(m.id); session.memoryProposals.removeAll { $0.id == m.id } } }
                            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.1)))
                    }
                    if let e = session.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            HStack {
                                Button("Retry") { session.send(model: model, provider: provider) }
                                // Alternate providers only if already authorized for this project; never silent.
                                ForEach(ProviderID.allCases.filter { $0 != provider && model.env.providers.hasKey($0) }) { alt in
                                    Button("Try \(alt.displayName)…") { provider = alt; session.send(model: model, provider: alt) }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let packet = session.packet {
                DisclosureGroup(isExpanded: $showInspector) {
                    RequestInspector(packet: packet)
                } label: {
                    Text("Request inspector — \(packet.outboundSources.count) source(s) will leave this Mac, \(packet.excluded.count) kept local, ~\(packet.estimatedInputTokens) tokens")
                        .font(.caption)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Ask about your project. Nothing is sent until you press Send.", text: $session.prompt, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder)
                    .onSubmit { session.send(model: model, provider: provider) }
                if session.running {
                    Button("Stop") { session.stop() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Send") { session.send(model: model, provider: provider) }.keyboardShortcut(.return, modifiers: .command)
                        .disabled(session.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .onAppear { provider = model.selectedProject?.defaultProvider ?? model.env.settings.get(Settings.defaultProvider) }
        .sheet(item: Binding(get: { session.consent.map(ConsentRequest.init) }, set: { if $0 == nil { session.consent = nil } })) { req in
            ConsentSheet(items: req.items, provider: provider,
                         sendOnce: { session.send(model: model, provider: provider, oneTime: Set(req.items.map(\.id))) },
                         alwaysAllow: {
                             if var p = model.selectedProject { p.disclosure.allowedProviders.insert(provider); try? model.env.projects.update(p) }
                             session.send(model: model, provider: provider, oneTime: Set(req.items.map(\.id)))
                         },
                         exclude: { session.send(model: model, provider: provider, exclude: true) },
                         cancel: { session.consent = nil; session.running = false })
        }
    }
}

struct ConsentRequest: Identifiable { let id = UUID(); let items: [PacketItem] }

struct ConsentSheet: View {
    let items: [PacketItem]
    let provider: ProviderID
    let sendOnce: () -> Void
    let alwaysAllow: () -> Void
    let exclude: () -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send these sources to \(provider.displayName)?").font(.title3.bold())
            Text("These items are set to “Ask before sending”. Sharing them is a disclosure to \(provider.displayName); local deletion cannot recall what was sent.")
                .font(.callout).foregroundStyle(.secondary)
            List(items) { i in
                VStack(alignment: .leading) {
                    Text(i.title).font(.headline)
                    Text(i.text).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 180)
            Link("\(provider.displayName) data policy", destination: provider.dataPolicyURL).font(.caption)
            HStack {
                Button("Cancel", role: .cancel) { cancel(); dismiss() }
                Spacer()
                Button("Send without these") { exclude(); dismiss() }
                Button("Always allow for this project") { alwaysAllow(); dismiss() }
                Button("Send once") { sendOnce(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RequestInspector: View {
    let packet: ContextPacket
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(packet.included) { i in Label("\(i.title) — will be sent", systemImage: "arrow.up.circle").font(.caption) }
            ForEach(packet.excluded) { i in Label("\(i.title) — kept local", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.role == .user ? "You" : (message.provider?.displayName ?? "Assistant")).font(.caption.bold())
                if let m = message.model { Text(m).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(LocalizedStringKey(message.content)).textSelection(.enabled)
            if !message.sourceRefs.isEmpty && message.role == .assistant {
                Text("Sources: " + message.sourceRefs.prefix(6).map(\.title).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(message.role == .user ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor)))
    }
}

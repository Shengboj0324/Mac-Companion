import SwiftUI
import CompanionCore

struct MemoryActivityView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    @State private var newStatement = ""
    @State private var newKind: MemoryKind = .preference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Memory & Activity", subtitle: "What Companion remembers, where it came from, and what it changed")
            Picker("", selection: $tab) {
                Text("Memory").tag(0); Text("Activity").tag(1); Text("Actions").tag(2); Text("Usage").tag(3)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case 0: memory
                    case 1: activity
                    case 2: actions
                    default: usage
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .id(model.refreshToken)
    }

    @ViewBuilder var memory: some View {
        let conflicts = model.env.memory.conflicts
        if !conflicts.isEmpty {
            GroupBox("Conflicting statements — choose which is right") {
                ForEach(conflicts) { m in
                    HStack { Text(m.statement); Spacer()
                        Button("Keep this") { try? model.env.memory.resolveConflict(keep: m.id, supersede: conflicts.map(\.id)); model.reload() } }
                }
            }
        }
        HStack {
            Picker("", selection: $newKind) { ForEach([MemoryKind.preference, .projectFact, .taskState], id: \.self) { Text($0.label).tag($0) } }
                .labelsHidden().frame(width: 140)
            TextField("Add something to remember", text: $newStatement)
            Button("Remember") {
                _ = try? model.env.memory.add(MemoryRecord(projectID: model.selectedProjectID, kind: newKind, statement: newStatement,
                                                           provenance: .userConfirmed, sourceRef: SourceRef(kind: .user, id: "user", title: "You"),
                                                           observedAt: Date()))
                newStatement = ""; model.reload()
            }.disabled(newStatement.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ForEach(model.env.memory.all(projectID: model.selectedProjectID)) { m in MemoryRow(model: model, memory: m) }
        Text("Forgetting removes a memory from Companion and future requests. It cannot recall information already sent to a provider or erase external backups.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Export memories…") {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "memories.json"
            if panel.runModal() == .OK, let url = panel.url, let d = try? model.env.memory.export() { try? d.write(to: url) }
        }
    }

    @ViewBuilder var activity: some View {
        ForEach(model.env.activity.recent()) { e in
            HStack(alignment: .top) {
                Text(e.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                Tag(e.initiator, color: e.initiator == "user" ? .blue : .gray)
                Text(e.summary).font(.callout)
            }
        }
    }

    @ViewBuilder var actions: some View {
        ForEach(model.env.executor.runs()) { r in
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(r.plan.title).font(.headline); Spacer(); Tag(r.state.rawValue, color: r.state == .succeeded ? .green : r.state.isTerminal ? .orange : .blue) }
                Text("Initiated by \(r.plan.initiator) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened)) · policy: \(r.policyDecision ?? "not evaluated")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(r.results, id: \.index) { res in
                    Text("• \(r.plan.operations[res.index].summary) — \(res.status.rawValue)\(res.verified ? ", verified" : "")").font(.caption)
                }
                if let e = r.error { Text(e).font(.caption).foregroundStyle(.orange) }
            }.padding(.vertical, 4)
            Divider()
        }
    }

    @ViewBuilder var usage: some View {
        let s = model.env.budget.status()
        GroupBox("This month") {
            VStack(alignment: .leading) {
                ProgressView(value: min(1, s.fraction)) { Text(String(format: "$%.2f spent + $%.2f reserved of $%.2f", s.spent, s.reserved, s.limit)) }
                Text("Estimates use price table “\(model.env.budget.prices.version)”. Provider invoices are authoritative; in-flight calls can slightly exceed the limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(model.env.budget.usage()) { u in
            HStack {
                Text(u.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).frame(width: 140, alignment: .leading)
                Text("\(u.provider.displayName) · \(u.model)").font(.caption)
                Spacer()
                Text("\(u.inputTokens) in / \(u.outputTokens) out").font(.caption).monospacedDigit()
                Text(String(format: "$%.4f%@", u.estimatedCost, u.isEstimate ? " (est.)" : "")).font(.caption).monospacedDigit()
            }
        }
    }
}

struct MemoryRow: View {
    @ObservedObject var model: AppModel
    let memory: MemoryRecord
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("", text: $text).onSubmit { try? model.env.memory.edit(memory.id, statement: text); editing = false; model.reload() }
                } else { Text(memory.statement) }
                HStack(spacing: 6) {
                    Tag(memory.kind.label, color: .blue)
                    Tag(memory.provenance.label, color: memory.provenance == .aiInference ? .orange : .green)
                    if memory.status != .active { Tag(memory.status.rawValue, color: .purple) }
                    if let s = memory.sourceRef { Text("Source: \(s.title)").font(.caption2).foregroundStyle(.secondary) }
                    Text(memory.observedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                if memory.provenance != .userConfirmed || memory.status == .proposed { Button("Confirm") { try? model.env.memory.confirm(memory.id); model.reload() } }
                Button("Edit") { text = memory.statement; editing = true }
                Menu("Providers") {
                    Button("Inherit project policy") { try? model.env.memory.setProviders(memory.id, [], sensitivity: .normal); model.reload() }
                    ForEach(ProviderID.allCases) { p in Button("Only \(p.displayName)") { try? model.env.memory.setProviders(memory.id, [p], sensitivity: .normal); model.reload() } }
                    Button("Sensitive — always ask") { try? model.env.memory.setProviders(memory.id, memory.allowedProviders, sensitivity: .sensitive); model.reload() }
                    Button("Never send") { try? model.env.memory.setProviders(memory.id, [], sensitivity: .neverSend); model.reload() }
                }
                Divider()
                Button("Forget", role: .destructive) { try? model.env.memory.forget(memory.id); model.reload() }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

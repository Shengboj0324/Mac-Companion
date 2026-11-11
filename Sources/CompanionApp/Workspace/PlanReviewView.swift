import SwiftUI
import CompanionCore

/// Trusted review: exact before/after, reasons, impact, row selection and an
/// Apply button naming the exact action count. Only this view issues approvals.
struct PlanReviewView: View {
    @ObservedObject var model: AppModel
    let run: ActionRun
    @State private var selected: Set<Int>
    @State private var result: ActionRun?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, run: ActionRun) {
        self.model = model
        self.run = run
        _selected = State(initialValue: Set(run.plan.operations.indices))
    }

    var problems: [String] {
        let subset = ActionPlan(title: run.plan.title, operations: run.plan.operations.enumerated().filter { selected.contains($0.offset) }.map(\.element), createdAt: Date())
        return subset.operations.isEmpty ? [] : model.env.executor.evaluate(subset)
    }

    var applyLabel: String {
        ActionPlan(title: "", operations: run.plan.operations.enumerated().filter { selected.contains($0.offset) }.map(\.element), createdAt: Date()).applyLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review: \(run.plan.title)").font(.title3.bold())
            Text("Proposed by \(run.plan.initiator). Approval covers only the selected rows, expires in 60 seconds and can be used once.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(run.plan.operations.enumerated()), id: \.offset) { i, op in
                    HStack(alignment: .top) {
                        if result == nil {
                            Toggle("", isOn: Binding(get: { selected.contains(i) }, set: { if $0 { selected.insert(i) } else { selected.remove(i) } })).labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(op.kind.verb.capitalized).font(.caption.bold()).foregroundStyle(.purple)
                            if let s = op.sourcePath { Text("Before: \((s as NSString).abbreviatingWithTildeInPath)").font(.callout).textSelection(.enabled) }
                            if let d = op.destinationPath { Text("After:  \((d as NSString).abbreviatingWithTildeInPath)").font(.callout).textSelection(.enabled) }
                            if let c = op.calendar {
                                Text("\(c.title) · \(c.start.formatted(date: .abbreviated, time: .shortened))–\(c.end.formatted(date: .omitted, time: .shortened)) · \(c.timeZone) · \(c.calendarTitle)")
                                let conflicts = model.env.calendar.conflicts(start: c.start, end: c.end)
                                if !conflicts.isEmpty { Text("Conflicts: " + conflicts.map(\.title).joined(separator: ", ")).foregroundStyle(.red).font(.caption) }
                            }
                            if let d = op.docs {
                                Text("Account: \(d.accountIdentity)").font(.caption)
                                ForEach(Array(d.edits.enumerated()), id: \.offset) { _, e in
                                    Text("− \(e.before)").foregroundStyle(.red).font(.callout)
                                    Text("+ \(e.after)").foregroundStyle(.green).font(.callout)
                                }
                                Text(op.kind == .docsEdit ? "Edits the original document" : "Creates a new document").font(.caption).bold()
                            }
                            if let r = op.reason { Text("Why: \(r)").font(.caption).foregroundStyle(.secondary) }
                            if op.kind == .move || op.kind == .rename {
                                Text("Impact: other apps' references and cloud sync may be affected; Companion cannot detect every dependency.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let res = result?.results.first(where: { $0.index == i }) {
                                HStack {
                                    Tag(res.status.rawValue + (res.verified ? " · verified" : ""), color: res.status == .succeeded ? .green : .red)
                                    if let d = res.detail { Text(d).font(.caption) }
                                    if res.status == .succeeded, [.move, .rename, .replaceContents].contains(op.kind) {
                                        Button("Undo") {
                                            switch model.env.executor.undo(actionID: result!.id, index: i) {
                                            case .restored: model.banner = "Restored."
                                            case .restoredAsCopy(let p): model.banner = "The file had later edits, so the previous version was restored as \((p as NSString).lastPathComponent)."
                                            case .notPossible(let why): model.banner = "Undo not possible: \(why)"
                                            }
                                            model.reload()
                                        }.buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            if result == nil && !problems.isEmpty {
                VStack(alignment: .leading) { ForEach(problems, id: \.self) { Label($0, systemImage: "hand.raised").foregroundStyle(.red).font(.caption) } }
            }
            if let r = result {
                Label(r.state == .succeeded ? "All selected operations completed and were verified." :
                        "Stopped: \(r.state.rawValue). \(r.error ?? "") Completed rows were not reversed.",
                      systemImage: r.state == .succeeded ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(r.state == .succeeded ? .green : .orange)
            }
            HStack {
                if result == nil {
                    Button("Reject plan", role: .destructive) { model.reject(run.plan); dismiss() }
                    Spacer()
                    Button("Not now") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(working ? "Applying…" : applyLabel) {
                        working = true
                        Task { result = await model.approve(run.plan, selected: selected); working = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || !problems.isEmpty || working)
                } else {
                    Spacer()
                    Button("Done") { model.reviewPlan = nil; dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

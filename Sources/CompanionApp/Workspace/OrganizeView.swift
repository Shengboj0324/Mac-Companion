import SwiftUI
import CompanionCore

struct OrganizeView: View {
    @ObservedObject var model: AppModel
    @State private var learnMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Organize", subtitle: "Proposals only. Nothing is moved, renamed or created until you approve an exact plan.")
                GroupBox("Awaiting your review (\(model.pendingProposals.count))") {
                    if model.pendingProposals.isEmpty { Text("No pending proposals.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(model.pendingProposals) { run in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(run.plan.title).font(.headline)
                                Text("\(run.plan.operations.count) operation(s) · proposed by \(run.plan.initiator)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review…") { model.review(run) }
                            Button("Reject") { model.reject(run.plan) }
                        }
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        let rules = model.env.filing.rules()
                        if rules.isEmpty { Text("No preferences learned yet. Companion observes your selected folders; it never imposes a generic folder tree.").foregroundStyle(.secondary) }
                        ForEach(ProfileField.allCases, id: \.self) { field in
                            let fr = rules.filter { $0.field == field }
                            if !fr.isEmpty {
                                Text(field.label).font(.subheadline.bold()).padding(.top, 4)
                                ForEach(fr) { r in RuleRow(model: model, rule: r) }
                            }
                        }
                        if let learnMessage { Text(learnMessage).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack {
                        Text("How I understand your filing system")
                        Spacer()
                        Button("Learn from my folders") {
                            let n = (try? model.env.filing.learn().count) ?? 0
                            learnMessage = n == 0 ? "No new patterns with enough evidence." : "Found \(n) candidate pattern(s). Confirm the ones that are right."
                            model.reload()
                        }
                        Button("Export") { if let d = try? model.env.filing.export() { save(d, name: "filing-profile.json") } }
                    }
                }
                PlacementPanel(model: model)
            }
            .padding(20)
        }
        .id(model.refreshToken)
    }

    func save(_ data: Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

struct RuleRow: View {
    @ObservedObject var model: AppModel
    let rule: OrganizationRule
    @State private var editing = false
    @State private var text = ""
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if editing { TextField("Rule", text: $text).onSubmit { try? model.env.filing.edit(rule.id, statement: text); editing = false; model.reload() } }
                else { Text(rule.statement) }
                Text("\(rule.scope) · \(rule.observationCount) observation(s)\(rule.confirmedAt.map { " · confirmed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
                if !rule.evidence.isEmpty { Text("e.g. " + rule.evidence.prefix(2).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Tag(rule.status == .explicit ? "Your rule" : "Candidate", color: rule.status == .explicit ? .green : .orange)
            if rule.status == .candidate {
                Button("Confirm") { try? model.env.filing.confirm(rule.id); model.reload() }.buttonStyle(.borderless)
                Button("Not right") { try? model.env.filing.reject(rule.id); model.reload() }.buttonStyle(.borderless)
            }
            Button(editing ? "Cancel" : "Edit") { text = rule.statement; editing.toggle() }.buttonStyle(.borderless)
        }
    }
}

/// Ranked destinations for recent files with reasons; producing a move plan for review.
struct PlacementPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("Placement suggestions for recent files") {
            let roots = model.env.indexing.roots().filter(\.enabled)
            let recent = model.env.indexing.recentAssets(limit: 8).filter { !$0.isManagedCopy }
            if roots.isEmpty || recent.isEmpty { Text("Add a folder to see suggestions.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(recent) { asset in
                if let root = roots.first(where: { $0.id == asset.rootID }) {
                    let ctx = context(root: root, excluding: asset)
                    let s = PlacementSuggester().suggest(fileName: asset.name, context: ctx)
                    let current = relFolder(asset.path, root: root)
                    let options = s.candidates.filter { $0.folder != current }
                    // Show files with a better-fitting destination, or unfiled files at the folder's top level.
                    if !options.isEmpty || current.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(asset.name).font(.headline); Text("in \(current.isEmpty ? root.url.lastPathComponent : current)").foregroundStyle(.secondary) }
                        if let q = s.question { Text(q).font(.caption).foregroundStyle(.orange) }
                        ForEach(options, id: \.folder) { c in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("→ \(c.folder)")
                                    Text(c.reasons.joined(separator: " · ") + (c.examples.isEmpty ? "" : " (e.g. \(c.examples.joined(separator: ", ")))"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Propose move") { propose(asset, root: root, folder: c.folder) }
                                Button("Wrong location") {
                                    model.env.filing.recordFeedback(filePath: asset.path, suggested: c.folder, outcome: .wrongLocation); model.reload()
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    func relFolder(_ path: String, root: Root) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder == root.path ? "" : String(folder.dropFirst(root.path.count + 1))
    }

    func context(root: Root, excluding: FileAsset) -> PlacementSuggester.Context {
        let assets = model.env.indexing.assets(rootID: root.id).filter { $0.id != excluding.id }
        let fb = model.env.filing.feedback()
        var rejected: [String: Int] = [:], accepted: [String: Int] = [:]
        for f in fb {
            if f.outcome == "wrongLocation" { rejected[f.suggested, default: 0] += 1 }
            if f.outcome == "accepted" { accepted[f.suggested, default: 0] += 1 }
        }
        let protected = Set(model.env.indexing.roots().filter(\.isProtected).compactMap { r -> String? in
            r.path.hasPrefix(root.path + "/") ? String(r.path.dropFirst(root.path.count + 1)) : nil })
        return PlacementSuggester.Context(existing: assets.map { (relFolder($0.path, root: root), $0.name) }.filter { !$0.0.isEmpty },
                                          protectedFolders: protected, explicitRules: model.env.filing.rules().filter { $0.status == .explicit },
                                          rejectedFolders: rejected, acceptedFolders: accepted)
    }

    func propose(_ asset: FileAsset, root: Root, folder: String) {
        let dest = root.url.appendingPathComponent(folder).appendingPathComponent(asset.name)
        model.env.filing.recordFeedback(filePath: asset.path, suggested: folder, outcome: .accepted)
        let plan = ActionPlan(title: "Move \(asset.name) to \(folder)",
                              operations: [PlannedOperation(kind: .move, sourcePath: asset.path,
                                                            sourceHash: asset.contentHash ?? (try? Hashing.sha256Hex(fileAt: asset.url)),
                                                            destinationPath: dest.path, reason: "Matches where similar files are kept")],
                              initiator: "user", projectID: model.selectedProjectID, createdAt: Date())
        model.submit(plan)
    }
}

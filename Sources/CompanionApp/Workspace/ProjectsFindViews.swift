import SwiftUI
import CompanionCore

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""
    @State private var assignment = ""
    @State private var taskTitle = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(model.projects, selection: $model.selectedProjectID) { p in Text(p.name).tag(p.id) }
                HStack {
                    TextField("New project", text: $newName).onSubmit(create)
                    Button("Add", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(8)
            }
            .frame(minWidth: 200, maxWidth: 260)
            ScrollView {
                if let p = model.selectedProject { detail(p).padding(20) }
                else { EmptyState(symbol: "folder", title: "No project selected", message: "Projects are virtual: grouping files here never moves them in Finder.") }
            }
        }
        .id(model.refreshToken)
    }

    func create() { model.createProject(newName); newName = "" }

    @ViewBuilder func detail(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: p.name, subtitle: "Created \(p.createdAt.formatted(date: .abbreviated, time: .omitted))")
            GroupBox("Cloud disclosure for this project") {
                DisclosureEditor(policy: p.disclosure) { newPolicy in
                    var q = p; q.disclosure = newPolicy; try? model.env.projects.update(q); model.env.approvals.bumpPolicyVersion(); model.reload()
                }
                Picker("Default provider", selection: Binding(get: { p.defaultProvider }, set: { v in var q = p; q.defaultProvider = v; try? model.env.projects.update(q); model.reload() })) {
                    Text("App default").tag(ProviderID?.none)
                    ForEach(ProviderID.allCases) { Text($0.displayName).tag(ProviderID?.some($0)) }
                }.frame(maxWidth: 320)
            }
            ProjectItemsList(model: model, project: p)
            GroupBox("Assignment requirements") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.env.tasks.tasks(projectID: p.id)) { t in TaskBlock(model: model, task: t) }
                    Divider()
                    TextField("Task title (e.g. Rough draft of literature review)", text: $taskTitle)
                    TextField("Paste the assignment description", text: $assignment, axis: .vertical).lineLimit(3...8)
                    HStack {
                        Text("Items are extracted locally with their source text and start unconfirmed.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Extract requirements") {
                            if let t = try? model.env.tasks.create(title: taskTitle.isEmpty ? "Assignment" : taskTitle, projectID: p.id) {
                                _ = try? model.env.tasks.extractRequirements(taskID: t.id, from: assignment, locator: "pasted description")
                            }
                            assignment = ""; taskTitle = ""; model.reload()
                        }.disabled(assignment.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            HStack {
                Toggle("Active", isOn: Binding(get: { p.active }, set: { v in var q = p; q.active = v; try? model.env.projects.update(q); model.reload() }))
                Spacer()
                Button("Delete project (files are kept)", role: .destructive) { try? model.env.projects.delete(p.id); model.selectedProjectID = nil; model.reload() }
            }
        }
    }
}

struct TaskBlock: View {
    @ObservedObject var model: AppModel
    let task: TaskItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title).font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { task.state }, set: { try? model.env.tasks.setState(task.id, $0); model.reload() })) {
                    Text("Open").tag(TaskState.open); Text("Ready").tag(TaskState.ready)
                    Text("Submitted (by you)").tag(TaskState.submitted); Text("Done").tag(TaskState.done)
                }.frame(width: 170)
            }
            if let d = task.deadline {
                HStack {
                    Text("Deadline: \(d.formatted(date: .abbreviated, time: .shortened))")
                    Tag(task.deadlineConfirmed ? "Confirmed" : "Proposed — verify", color: task.deadlineConfirmed ? .green : .orange)
                    if !task.deadlineConfirmed { Button("Confirm") { try? model.env.tasks.confirmDeadline(task.id, date: d); model.reload() }.buttonStyle(.borderless) }
                }.font(.caption)
            }
            ForEach(model.env.tasks.requirements(taskID: task.id)) { r in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { r.done }, set: { try? model.env.tasks.setDone(r.id, $0); model.reload() })).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.text).strikethrough(r.confirmation == .rejected)
                        Text("“\(r.evidence)”").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Tag(r.status.rawValue.capitalized, color: r.status == .required ? .blue : r.status == .optional ? .gray : .orange)
                    if r.confirmation == .unconfirmed {
                        Button("Confirm") { try? model.env.tasks.setConfirmation(r.id, .confirmed); model.reload() }.buttonStyle(.borderless)
                        Button("Not required") { try? model.env.tasks.setConfirmation(r.id, .rejected); model.reload() }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DisclosureEditor: View {
    let policy: DisclosurePolicy
    let onChange: (DisclosurePolicy) -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Sending to AI providers", selection: Binding(get: { policy.mode }, set: { var p = policy; p.mode = $0; onChange(p) })) {
                ForEach(DisclosureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            if policy.mode != .localOnly {
                HStack {
                    Text(policy.mode == .allowSelected ? "Allowed:" : "Send without asking:").font(.caption)
                    ForEach(ProviderID.allCases) { pid in
                        Toggle(pid.displayName, isOn: Binding(get: { policy.allowedProviders.contains(pid) }, set: { on in
                            var p = policy
                            if on { p.allowedProviders.insert(pid) } else { p.allowedProviders.remove(pid) }
                            onChange(p)
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            Text("Applies to excerpts, filenames, calendar titles, summaries and memories — not only whole files.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FindView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var kinds: Set<SearchKind> = [.localFile, .googleDoc]
    @State private var onlyProject = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Find Files", subtitle: "Local search — works offline and without an API key")
            HStack {
                TextField("Search names and contents", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                Toggle("Local", isOn: binding(.localFile)).toggleStyle(.checkbox)
                Toggle("Google Docs", isOn: binding(.googleDoc)).toggleStyle(.checkbox)
                Toggle("Checkpoints", isOn: binding(.checkpoint)).toggleStyle(.checkbox)
                if model.selectedProject != nil { Toggle("This project", isOn: $onlyProject).toggleStyle(.checkbox) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let scope = onlyProject ? model.env.retrieval.scope(projectID: model.selectedProjectID) : nil
                    let hits = query.isEmpty ? [] : model.env.search.search(query, filter: SearchFilter(kinds: kinds, itemIDs: scope, limit: 60))
                    if query.isEmpty {
                        Text("Recent files").font(.headline)
                        ForEach(model.env.indexing.recentAssets(limit: 15)) { FileCard(model: model, asset: $0) }
                        if model.env.indexing.roots().isEmpty && model.env.cloudDocs.assets().isEmpty {
                            EmptyState(symbol: "folder.badge.plus", title: "No sources yet", message: "Add a folder or a Google Doc in Settings → Sources.")
                            Button("Add a folder…") { model.addFolder() }.frame(maxWidth: .infinity)
                        }
                    } else if hits.isEmpty {
                        Text("No matches for “\(query)”.").foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        switch hit.kind {
                        case .localFile:
                            if let a = model.env.indexing.asset(hit.itemID) { FileCard(model: model, asset: a, snippet: hit.snippet) }
                        case .googleDoc:
                            if let c = model.env.cloudDocs.asset(hit.itemID) { CloudCard(model: model, asset: c, snippet: hit.snippet) }
                        default:
                            VStack(alignment: .leading) { Text(hit.title).font(.headline); Text(hit.snippet).font(.callout) }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    func binding(_ k: SearchKind) -> Binding<Bool> {
        Binding(get: { kinds.contains(k) }, set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } })
    }
}

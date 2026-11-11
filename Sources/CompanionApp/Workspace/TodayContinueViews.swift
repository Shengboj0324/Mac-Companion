import SwiftUI
import CompanionCore

struct TodayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Today", subtitle: Date().formatted(date: .complete, time: .omitted))
                GroupBox("Suggestions") {
                    if model.suggestions.isEmpty {
                        Text("Nothing needs your attention. Suggestions come only from local data — no AI call is made to build them.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    ForEach(model.suggestions) { s in SuggestionRow(model: model, suggestion: s) }
                }
                GroupBox {
                    let events = model.env.calendar.upcoming(hours: 72)
                    if !model.env.calendar.isAuthorized {
                        HStack {
                            Text("Calendar is not connected. Companion works without it.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Connect Calendar…") { Task { await model.requestCalendarAccess() } }
                        }
                    } else if events.isEmpty {
                        Text("No upcoming events in selected calendars.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(events) { e in EventRow(model: model, event: e) }
                } label: {
                    HStack { Text("Upcoming"); Spacer(); Text(model.env.calendar.freshnessLabel).font(.caption).foregroundStyle(.secondary) }
                }
                GroupBox("Tasks and deadlines") {
                    let tasks = model.env.tasks.tasks().filter { $0.state != .done }
                    if tasks.isEmpty { Text("No open tasks.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(tasks) { t in
                        HStack {
                            Text(t.title)
                            Spacer()
                            if let d = t.deadline {
                                Text(d.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(t.deadlineConfirmed ? .primary : .secondary)
                                Tag(t.deadlineConfirmed ? "Confirmed" : "Proposed", color: t.deadlineConfirmed ? .green : .orange)
                            }
                            let prog = model.env.tasks.progress(taskID: t.id)
                            if prog.required > 0 { Text("\(prog.done)/\(prog.required)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .id(model.refreshToken)
    }
}

struct SuggestionRow: View {
    @ObservedObject var model: AppModel
    let suggestion: Suggestion
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).font(.headline)
                Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch suggestion.kind {
            case .materialsReady, .resume:
                Button("Open workspace") { model.selectedProjectID = suggestion.projectID; model.section = .continueWork }
            case .linkEvent:
                Button("Link") {
                    if let p = suggestion.projectID, let e = suggestion.eventID {
                        _ = try? model.env.projects.addItem(projectID: p, kind: .event, targetID: e, reason: "Confirmed by you"); model.reload()
                    }
                }
                Button("Not now") { model.suggestions.removeAll { $0.id == suggestion.id } }
            case .confirmDeadline:
                Button("Review") { model.selectedProjectID = suggestion.projectID; model.section = .projects }
            case .reviewProposal:
                Button("Review") { model.section = .organize }
            case .staleCopy:
                Button("Review") { model.section = .projects }
            }
            if let pid = suggestion.projectID {
                Menu("Snooze") {
                    Button("1 hour") { snooze(pid, 3_600) }
                    Button("Until tomorrow") { snooze(pid, 86_400) }
                }.menuStyle(.borderlessButton).frame(width: 70)
            }
        }
        .padding(.vertical, 4)
    }

    func snooze(_ id: UUID, _ seconds: Double) {
        guard var p = model.env.projects.project(id) else { return }
        p.snoozedUntil = Date().addingTimeInterval(seconds)
        try? model.env.projects.update(p)
        model.reload()
    }
}

struct EventRow: View {
    @ObservedObject var model: AppModel
    let event: CalendarItem
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(event.title)
                Text("\(event.isAllDay ? "All day" : event.startAt.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle)\(event.isRecurring ? " · repeats" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Link to project") {
                ForEach(model.projects) { p in
                    Button(p.name) { _ = try? model.env.projects.addItem(projectID: p.id, kind: .event, targetID: event.id, reason: "Linked by you"); model.reload() }
                }
                Divider()
                Button("Create task from event…") {
                    // Event start is recorded only as a *proposed* deadline.
                    _ = try? model.env.tasks.create(title: event.title, projectID: model.selectedProjectID, eventID: event.id,
                                                    proposedDeadline: event.startAt, evidence: "Calendar event start (unconfirmed)")
                    if let notes = event.notes, let t = model.env.tasks.tasks().last { _ = try? model.env.tasks.extractRequirements(taskID: t.id, from: notes, locator: "event notes") }
                    model.reload()
                }
            }.menuStyle(.borderlessButton).frame(width: 140)
        }
    }
}

struct ContinueView: View {
    @ObservedObject var model: AppModel
    @State private var note = ""
    @State private var next = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = model.selectedProject ?? model.env.projects.lastActive {
                    SectionHeader(title: "Continue — \(p.name)", subtitle: "Your last stopping point and working files")
                    GroupBox("Where you stopped") {
                        if let cp = model.env.projects.latestCheckpoint(projectID: p.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cp.note)
                                if let n = cp.nextStep { Text("Next: \(n)").bold() }
                                Text(cp.createdAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("No checkpoint yet. Save one when you stop working.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox("Save a resume note") {
                        VStack(alignment: .leading) {
                            TextField("What did you finish?", text: $note, axis: .vertical).lineLimit(2...4)
                            TextField("What's next?", text: $next)
                            HStack { Spacer()
                                Button("Save checkpoint") {
                                    _ = try? model.env.projects.saveCheckpoint(projectID: p.id, note: note, nextStep: next.isEmpty ? nil : next)
                                    note = ""; next = ""; model.reload()
                                }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
                            }
                        }
                    }
                    ProjectItemsList(model: model, project: p)
                } else {
                    EmptyState(symbol: "arrow.uturn.forward.circle", title: "Nothing to continue yet",
                               message: "Create a project, add files or Google Docs to it, and save a checkpoint when you stop.")
                    Button("Create a project") { model.section = .projects }.frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .id(model.refreshToken)
    }
}

struct ProjectItemsList: View {
    @ObservedObject var model: AppModel
    let project: Project
    var body: some View {
        let items = model.env.projects.items(projectID: project.id)
        GroupBox("Materials (\(items.filter { $0.kind != .event }.count))") {
            if items.isEmpty { Text("Drop files on the companion icon, or add them from Find Files.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(items) { item in
                switch item.kind {
                case .file:
                    if let a = model.env.indexing.asset(item.targetID) {
                        FileCard(model: model, asset: a, onRemove: { try? model.env.projects.removeItem(item.id); model.reload() })
                    }
                case .cloudDoc:
                    if let c = model.env.cloudDocs.asset(item.targetID) {
                        CloudCard(model: model, asset: c, onRemove: { try? model.env.projects.removeItem(item.id); model.reload() })
                    }
                case .event:
                    if let e = model.env.calendar.item(item.targetID) {
                        HStack { Image(systemName: "calendar"); Text(e.title); Text(e.startAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            Spacer(); Button("Unlink") { try? model.env.projects.removeItem(item.id); model.reload() }.buttonStyle(.borderless) }
                    }
                case .task: EmptyView()
                }
            }
        }
        let copies = model.env.copies.all(projectID: project.id)
        if !copies.isEmpty {
            GroupBox("Working copies") {
                ForEach(copies) { wc in
                    HStack {
                        VStack(alignment: .leading) {
                            Text((wc.copyPath as NSString).lastPathComponent)
                            Text("From \((wc.sourcePath as NSString).abbreviatingWithTildeInPath)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Tag(wc.state.label, color: wc.state == .current ? .green : .orange)
                        if wc.state == .sourceChanged || wc.state == .conflict {
                            Button("Keep both") { _ = try? model.env.copies.keepBoth(wc.id); model.reload() }
                            Button("Compare") { NSWorkspace.shared.open([URL(fileURLWithPath: wc.sourcePath), URL(fileURLWithPath: wc.copyPath)],
                                                                         withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                                                         configuration: .init()) }
                        }
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: wc.copyPath)) }
                    }
                }
            }
        }
    }
}

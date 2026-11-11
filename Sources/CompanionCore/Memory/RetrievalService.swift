import Foundation

/// Resolves disclosure policy + provenance for any retrievable item and gathers
/// scoped context. Access filters are applied before ranking (scope restriction)
/// and again before transmission (`ContextPacketBuilder.revalidate`).
public final class RetrievalService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let search: SearchIndex
    private let indexing: IndexingService
    private let projects: ProjectService
    private let memory: MemoryService
    private let tasks: TaskService
    private let calendar: CalendarService
    private let cloud: () -> CloudDocumentService?

    public init(db: SQLiteDatabase, search: SearchIndex, indexing: IndexingService, projects: ProjectService, memory: MemoryService,
                tasks: TaskService, calendar: CalendarService, cloud: @escaping () -> CloudDocumentService?) {
        self.db = db; self.search = search; self.indexing = indexing; self.projects = projects; self.memory = memory
        self.tasks = tasks; self.calendar = calendar; self.cloud = cloud
    }

    func projectPolicy(_ projectID: UUID?) -> DisclosurePolicy {
        projectID.flatMap(projects.project)?.disclosure ?? DisclosurePolicy()
    }

    /// Item IDs visible within a project scope (files, cloud docs, memories, checkpoints).
    public func scope(projectID: UUID?) -> Set<UUID>? {
        guard let projectID else { return nil }
        var ids = Set(projects.items(projectID: projectID).filter { $0.kind == .file || $0.kind == .cloudDoc }.map(\.targetID))
        ids.formUnion(memory.all(projectID: projectID).map(\.id))
        ids.formUnion(projects.checkpoints(projectID: projectID).map(\.id))
        return ids
    }

    /// Policy + source for a search item; nil when the item no longer exists or is unavailable.
    public func describe(itemID: UUID, kind: SearchKind, projectID: UUID?) -> (DisclosurePolicy, SourceRef, Bool)? {
        let project = projectPolicy(projectID)
        switch kind {
        case .localFile:
            guard let a = indexing.asset(itemID), a.availability == .available else { return nil }
            let rootPolicy = a.rootID.flatMap(indexing.root)?.disclosure ?? DisclosurePolicy()
            return (rootPolicy.intersect(project), SourceRef(kind: .localFile, id: a.id.uuidString, title: a.name, locator: a.path,
                                                             version: a.contentHash, retrievedAt: a.lastIndexedAt), false)
        case .googleDoc:
            guard let c = cloud()?.asset(itemID), c.freshness != .unavailable else { return nil }
            return (c.disclosure.intersect(project), SourceRef(kind: .googleDoc, id: c.providerFileID, title: c.name, locator: c.canonicalURL,
                                                               version: c.revisionID, retrievedAt: c.retrievedAt, accountID: c.accountID), false)
        case .memory:
            guard let m = memory.memory(itemID), m.status != .superseded else { return nil }
            var policy = project
            if !m.allowedProviders.isEmpty { policy = DisclosurePolicy(mode: .allowSelected, allowedProviders: m.allowedProviders).intersect(project) }
            if m.sensitivity == .sensitive { policy = policy.intersect(DisclosurePolicy(mode: .askBeforeSending)) }
            return (policy, SourceRef(kind: .user, id: m.id.uuidString, title: m.kind.label, locator: m.provenance.label, retrievedAt: m.observedAt),
                    m.sensitivity == .neverSend)
        case .checkpoint:
            return (project, SourceRef(kind: .user, id: itemID.uuidString, title: "Resume checkpoint"), false)
        case .event:
            guard let e = calendar.item(itemID) else { return nil }
            return (project, SourceRef(kind: .calendarEvent, id: e.id.uuidString, title: e.title, retrievedAt: e.refreshedAt), false)
        }
    }

    public func packetItem(for hit: SearchHit, projectID: UUID?) -> PacketItem? {
        guard let (policy, source, never) = describe(itemID: hit.itemID, kind: hit.kind, projectID: projectID) else { return nil }
        let segment = hit.segmentID.flatMap(search.segment)
        let text = segment?.text ?? hit.snippet
        var title = hit.title
        if let h = segment?.heading { title += " › \(h)" }
        if hit.kind == .googleDoc, let cov = cloud()?.asset(hit.itemID)?.coverage, !cov.isComplete {
            return PacketItem(id: "seg:\(hit.segmentID?.uuidString ?? hit.itemID.uuidString)", kind: .excerpt, title: title,
                              text: text + "\n[Coverage note: \(cov.summary)]", source: source, policy: policy, neverSend: never)
        }
        return PacketItem(id: "seg:\(hit.segmentID?.uuidString ?? hit.itemID.uuidString)", kind: hit.kind == .memory ? .memory : .excerpt,
                          title: title, text: text, source: source, policy: policy, neverSend: never)
    }

    /// Gathers request-relevant context for a project. Nothing here leaves the Mac.
    public func gather(request: String, projectID: UUID?, attached: [UUID] = [], maxExcerpts: Int = 8) -> [PacketItem] {
        var items: [PacketItem] = []
        var seen = Set<String>()
        func add(_ i: PacketItem?) { if let i, !seen.contains(i.id) { seen.insert(i.id); items.append(i) } }
        let project = projectPolicy(projectID)

        // Explicitly attached sources first.
        for id in attached {
            let kind = search.kind(of: id) ?? .localFile
            for seg in search.segments(for: id).prefix(3) {
                add(packetItem(for: SearchHit(itemID: id, kind: kind, segmentID: seg.id, title: titleFor(id, kind), snippet: "", heading: seg.heading, score: 1),
                               projectID: projectID))
            }
        }
        // Memories: confirmed facts and preferences for this project and globally.
        for m in memory.all(projectID: projectID).filter({ $0.status != .proposed }).prefix(15) {
            guard let (policy, source, never) = describe(itemID: m.id, kind: .memory, projectID: projectID) else { continue }
            let label = m.status == .conflicted ? "CONFLICTED — unresolved" : m.provenance.label
            add(PacketItem(id: "mem:\(m.id)", kind: .memory, title: "\(m.kind.label) (\(label))", text: m.statement,
                           source: source, policy: policy, neverSend: never))
        }
        // Latest checkpoint and outstanding decisions.
        if let projectID, let cp = projects.latestCheckpoint(projectID: projectID) {
            add(PacketItem(id: "cp:\(cp.id)", kind: .checkpoint, title: "Last checkpoint", text: cp.note + (cp.nextStep.map { "\nNext: \($0)" } ?? ""),
                           source: SourceRef(kind: .user, id: cp.id.uuidString, title: "Checkpoint", retrievedAt: cp.createdAt), policy: project))
        }
        if let projectID {
            for t in tasks.tasks(projectID: projectID) where t.state == .open {
                let reqs = tasks.requirements(taskID: t.id).filter { $0.confirmation != .rejected }
                guard !reqs.isEmpty || t.deadline != nil else { continue }
                var text = "Task: \(t.title)"
                if let d = t.deadline { text += "\nDeadline: \(ISO8601DateFormatter().string(from: d)) (\(t.deadlineConfirmed ? "confirmed" : "unconfirmed proposal"))" }
                for r in reqs { text += "\n- [\(r.done ? "x" : " ")] (\(r.status.rawValue), \(r.confirmation.rawValue)) \(r.text)" }
                add(PacketItem(id: "task:\(t.id)", kind: .requirement, title: "Task \(t.title)", text: text,
                               source: SourceRef(kind: .user, id: t.id.uuidString, title: t.title), policy: project))
            }
            for item in projects.items(projectID: projectID) where item.kind == .event {
                guard let e = calendar.item(item.targetID), e.endAt > Date().addingTimeInterval(-86_400) else { continue }
                add(PacketItem(id: "evt:\(e.id)", kind: .event, title: "Event \(e.title)",
                               text: "\(e.title) — \(e.isAllDay ? "all day" : ISO8601DateFormatter().string(from: e.startAt)) (\(e.calendarTitle)). Event time is not a confirmed deadline.",
                               source: SourceRef(kind: .calendarEvent, id: e.id.uuidString, title: e.title, retrievedAt: e.refreshedAt), policy: project))
            }
        }
        // Scoped search (filter before ranking).
        let filter = SearchFilter(kinds: [.localFile, .googleDoc, .checkpoint], itemIDs: scope(projectID: projectID), limit: maxExcerpts)
        for hit in search.search(request, filter: filter) { add(packetItem(for: hit, projectID: projectID)) }
        return items
    }

    func titleFor(_ id: UUID, _ kind: SearchKind) -> String {
        switch kind {
        case .localFile: return indexing.asset(id)?.name ?? "File"
        case .googleDoc: return cloud()?.asset(id)?.name ?? "Google Doc"
        default: return kind.label
        }
    }

    /// Re-resolves an item's current policy (used immediately before transmission).
    public func current(_ item: PacketItem, projectID: UUID?) -> PacketItem? {
        let parts = item.id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return item }
        switch parts[0] {
        case "seg":
            guard let seg = search.segment(uuid) else {
                // Title-only hit keyed by item id.
                if let k = search.kind(of: uuid), let d = describe(itemID: uuid, kind: k, projectID: projectID) {
                    return PacketItem(id: item.id, kind: item.kind, title: item.title, text: item.text, source: d.1, policy: d.0, neverSend: d.2)
                }
                return nil
            }
            guard let k = search.kind(of: seg.assetID), let d = describe(itemID: seg.assetID, kind: k, projectID: projectID) else { return nil }
            return PacketItem(id: item.id, kind: item.kind, title: item.title, text: item.text, source: d.1, policy: d.0, neverSend: d.2)
        case "mem":
            guard let d = describe(itemID: uuid, kind: .memory, projectID: projectID) else { return nil }
            return PacketItem(id: item.id, kind: item.kind, title: item.title, text: item.text, source: d.1, policy: d.0, neverSend: d.2)
        default:
            return PacketItem(id: item.id, kind: item.kind, title: item.title, text: item.text, source: item.source,
                              policy: projectPolicy(projectID), neverSend: item.neverSend)
        }
    }
}

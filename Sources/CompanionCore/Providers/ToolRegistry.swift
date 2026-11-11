import Foundation

/// Bounded model tool surface: typed read tools and proposal tools only. No write
/// credential, shell, SQL or unrestricted path tool is ever exposed (spec §13).
/// Proposals are stored as data for trusted review; tools cannot approve them.
public final class ToolRegistry: @unchecked Sendable {
    public struct Context: Sendable {
        public let provider: ProviderID
        public let projectID: UUID?
        public let oneTimeAllowed: Set<String>
    }

    public enum Outcome: Sendable {
        case result(String)
        case proposal(ActionRun, String)
        case memoryProposal(MemoryRecord, String)
        case error(String)
    }

    private let retrieval: RetrievalService
    private let search: SearchIndex
    private let indexing: IndexingService
    private let projects: ProjectService
    private let memory: MemoryService
    private let executor: ActionExecutor
    private let calendar: CalendarService
    private let copies: WorkingCopyService
    private let settings: SettingsStore
    private let clock: Clock

    init(retrieval: RetrievalService, search: SearchIndex, indexing: IndexingService, projects: ProjectService, memory: MemoryService,
         executor: ActionExecutor, calendar: CalendarService, copies: WorkingCopyService, settings: SettingsStore, clock: Clock) {
        self.retrieval = retrieval; self.search = search; self.indexing = indexing; self.projects = projects; self.memory = memory
        self.executor = executor; self.calendar = calendar; self.copies = copies; self.settings = settings; self.clock = clock
    }

    static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    static func str(_ d: String) -> JSONValue { .object(["type": .string("string"), "description": .string(d)]) }
    static func int(_ d: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(d)]) }

    public static let specs: [ToolSpec] = [
        ToolSpec(name: "search_sources", description: "Search the user's authorized files, Google Docs and checkpoints in the current project. Returns excerpt IDs and snippets.",
                 parameters: schema(["query": str("Keywords to search for")], required: ["query"])),
        ToolSpec(name: "read_excerpt", description: "Read the full text of an excerpt returned by search_sources.",
                 parameters: schema(["excerpt_id": str("Excerpt ID from search_sources")], required: ["excerpt_id"])),
        ToolSpec(name: "list_upcoming_events", description: "List the user's upcoming calendar events (titles and times) from selected calendars.",
                 parameters: schema(["days": int("Days ahead, 1-14")], required: ["days"])),
        ToolSpec(name: "propose_memory", description: "Propose a durable fact or preference to remember. The user must confirm it.",
                 parameters: schema(["statement": str("One concise statement"), "kind": str("preference | projectFact | taskState")], required: ["statement", "kind"])),
        ToolSpec(name: "propose_working_copy", description: "Propose making a working copy of a file in the project's managed folder. The user reviews and approves; nothing happens until then.",
                 parameters: schema(["excerpt_id": str("Excerpt ID of the file to copy"), "reason": str("Why a copy helps")], required: ["excerpt_id", "reason"])),
        ToolSpec(name: "propose_focus_block", description: "Propose a calendar focus block. The user reviews calendar, time and conflicts before anything is saved.",
                 parameters: schema(["title": str("Event title"), "start": str("ISO 8601 start time with offset"), "minutes": int("Duration in minutes, 15-240")],
                                    required: ["title", "start", "minutes"])),
    ]

    public static let maxSteps = 6

    public func run(_ call: ToolCall, context: Context) -> Outcome {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .error("Arguments must be a JSON object") }
        switch call.name {
        case "search_sources": return searchSources(args, context)
        case "read_excerpt": return readExcerpt(args, context)
        case "list_upcoming_events": return listEvents(args, context)
        case "propose_memory": return proposeMemory(args, context)
        case "propose_working_copy": return proposeCopy(args, context)
        case "propose_focus_block": return proposeFocus(args, context)
        default: return .error("Unknown tool \(call.name)")
        }
    }

    // MARK: Read tools

    private func allowed(_ item: PacketItem, _ c: Context) -> Bool { item.decision(for: c.provider, oneTimeAllowed: c.oneTimeAllowed) == .allow }

    private func searchSources(_ args: [String: Any], _ c: Context) -> Outcome {
        guard let q = args["query"] as? String, !q.isEmpty, q.count <= 200 else { return .error("query is required (≤200 chars)") }
        let hits = search.search(q, filter: SearchFilter(kinds: [.localFile, .googleDoc, .checkpoint], itemIDs: retrieval.scope(projectID: c.projectID), limit: 8))
        var lines: [String] = []
        var withheld = 0
        for h in hits {
            guard let item = retrieval.packetItem(for: h, projectID: c.projectID) else { continue }
            if allowed(item, c) {
                lines.append("excerpt_id=\(h.segmentID?.uuidString ?? h.itemID.uuidString) | \(item.title) | \(h.snippet)")
            } else { withheld += 1 }
        }
        if lines.isEmpty && withheld == 0 { return .result("No matching sources.") }
        if withheld > 0 { lines.append("(\(withheld) result(s) withheld: the user has not allowed them to be sent to this provider.)") }
        return .result(lines.joined(separator: "\n"))
    }

    private func readExcerpt(_ args: [String: Any], _ c: Context) -> Outcome {
        guard let s = args["excerpt_id"] as? String, let id = UUID(uuidString: s) else { return .error("excerpt_id must be an ID from search_sources") }
        let seg = search.segment(id)
        let itemID = seg?.assetID ?? id
        if let scope = retrieval.scope(projectID: c.projectID), !scope.contains(itemID) { return .error("That excerpt is outside the current project") }
        guard let kind = search.kind(of: itemID) else { return .error("Unknown excerpt") }
        let hit = SearchHit(itemID: itemID, kind: kind, segmentID: seg?.id, title: retrieval.titleFor(itemID, kind), snippet: "", heading: seg?.heading, score: 0)
        guard let item = retrieval.packetItem(for: hit, projectID: c.projectID) else { return .error("Source is no longer available") }
        guard allowed(item, c) else { return .error("The user has not allowed this source to be sent to this provider") }
        return .result("[\(item.title)]\n\(item.text)")
    }

    private func listEvents(_ args: [String: Any], _ c: Context) -> Outcome {
        let days = min(14, max(1, args["days"] as? Int ?? 7))
        let policy = retrieval.projectPolicy(c.projectID)
        guard policy.decision(for: c.provider) == .allow || c.oneTimeAllowed.contains("calendar") else {
            return .error("Calendar titles are not allowed to be sent to this provider for this project")
        }
        let now = clock.now()
        let events = calendar.items(from: now, to: now.addingTimeInterval(Double(days) * 86_400))
        if events.isEmpty { return .result("No upcoming events in selected calendars (\(calendar.freshnessLabel)).") }
        let f = ISO8601DateFormatter()
        return .result(events.prefix(40).map { "\($0.title) — \($0.isAllDay ? "all day " : "")\(f.string(from: $0.startAt)) [\($0.calendarTitle)]" }
            .joined(separator: "\n") + "\nNote: event times are not confirmed deadlines.")
    }

    // MARK: Proposal tools

    private func proposeMemory(_ args: [String: Any], _ c: Context) -> Outcome {
        guard let statement = (args["statement"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty, statement.count <= 500 else {
            return .error("statement is required (≤500 chars)")
        }
        let kind = MemoryKind(rawValue: args["kind"] as? String ?? "") ?? .projectFact
        let record = MemoryRecord(projectID: c.projectID, kind: kind == .sessionContext ? .projectFact : kind, statement: statement,
                                  provenance: .aiInference, observedAt: clock.now(), status: .proposed)
        let saved: MemoryRecord?
        do { saved = try memory.add(record) } catch { return .error("Could not save the proposal") }
        guard let r = saved else { return .result("The user previously asked to forget this; not proposed again.") }
        return .memoryProposal(r, "Proposed memory saved for the user's confirmation.")
    }

    private func proposeCopy(_ args: [String: Any], _ c: Context) -> Outcome {
        guard let s = args["excerpt_id"] as? String, let id = UUID(uuidString: s) else { return .error("excerpt_id required") }
        let itemID = search.segment(id)?.assetID ?? id
        guard let asset = indexing.asset(itemID) else { return .error("Only local files can be copied") }
        if let scope = retrieval.scope(projectID: c.projectID), !scope.contains(itemID) { return .error("That file is outside the current project") }
        let project = c.projectID.flatMap(projects.project)
        let dest = WorkingCopyService.uniqueDestination(for: asset.name, in: copies.folder(for: project))
        let plan = ActionPlan(title: "Working copy of \(asset.name)",
                              operations: [PlannedOperation(kind: .copyFile, sourcePath: asset.path, sourceHash: asset.contentHash,
                                                            destinationPath: dest.path, reason: (args["reason"] as? String).map { String($0.prefix(300)) })],
                              initiator: "model proposal", projectID: c.projectID, createdAt: clock.now())
        guard let run = try? executor.propose(plan) else { return .error("Could not record the proposal") }
        return .proposal(run, "Proposal recorded. The user will review it; it has NOT been applied.")
    }

    private func proposeFocus(_ args: [String: Any], _ c: Context) -> Outcome {
        guard let title = args["title"] as? String, !title.isEmpty, title.count <= 120,
              let startS = args["start"] as? String, let start = ISO8601DateFormatter().date(from: startS),
              let minutes = args["minutes"] as? Int, (15...240).contains(minutes) else {
            return .error("title, ISO 8601 start and minutes (15-240) are required")
        }
        guard let calID = settings.get(Settings.writableCalendars).first,
              let cal = calendar.source.calendars().first(where: { $0.id == calID }) else {
            return .error("No calendar is designated to receive changes. The user can enable one in Settings.")
        }
        guard start > clock.now() else { return .error("Start time must be in the future") }
        let spec = FocusBlockSpec(calendarID: cal.id, calendarTitle: cal.title, title: title, start: start,
                                  end: start.addingTimeInterval(Double(minutes) * 60), timeZone: TimeZone.current.identifier)
        let plan = ActionPlan(title: "Focus block: \(title)", operations: [PlannedOperation(kind: .createCalendarEvent, calendar: spec)],
                              initiator: "model proposal", projectID: c.projectID, createdAt: clock.now())
        guard let run = try? executor.propose(plan) else { return .error("Could not record the proposal") }
        let conflicts = calendar.conflicts(start: spec.start, end: spec.end)
        return .proposal(run, "Proposal recorded for review; NOT saved." + (conflicts.isEmpty ? "" : " It conflicts with \(conflicts.count) event(s)."))
    }
}

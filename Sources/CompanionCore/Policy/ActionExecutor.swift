import Foundation

/// The only component that can carry out approved user-content changes.
/// Model access is read-only; mutations arrive as reviewed `ActionPlan` data plus
/// a single-use grant from the trusted UI (spec §12–§15).
public final class ActionExecutor: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore
    private let approvals: ApprovalAuthority
    private let indexing: IndexingService
    private let activity: ActivityLog
    private let recoveryDirectory: URL
    private let managedRoot: URL
    private var performers: [ExternalOperationPerformer] = []
    private let lock = NSLock()
    private var cancelled = Set<UUID>()

    public init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore, approvals: ApprovalAuthority,
                indexing: IndexingService, activity: ActivityLog, recoveryDirectory: URL, managedRoot: URL) {
        self.db = db; self.clock = clock; self.settings = settings; self.approvals = approvals
        self.indexing = indexing; self.activity = activity; self.recoveryDirectory = recoveryDirectory; self.managedRoot = managedRoot
    }

    public func register(_ performer: ExternalOperationPerformer) { lock.lock(); performers.append(performer); lock.unlock() }

    // MARK: Plans

    /// Records a proposal. Proposals are data — nothing is executed.
    @discardableResult
    public func propose(_ plan: ActionPlan) throws -> ActionRun {
        let maxOps = settings.get(Settings.maxOperationsPerApproval)
        guard !plan.operations.isEmpty else { throw CompanionError.invalidArgument("Empty plan") }
        guard plan.operations.count <= maxOps else {
            throw CompanionError.policyViolation("At most \(maxOps) operations can be approved at once")
        }
        let now = clock.now()
        let run = ActionRun(id: plan.id, plan: plan, state: .proposed, results: [], error: nil, policyDecision: nil, createdAt: now, updatedAt: now)
        try db.execute("""
            INSERT INTO action_runs(id, plan_hash, plan, summary, initiator, state, results, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [run.id, plan.hash, try JSON.encode(plan), plan.title, plan.initiator, run.state.rawValue, "[]", now, now])
        activity.record(kind: "proposal", initiator: plan.initiator, summary: "Proposed: \(plan.title) (\(plan.operations.count) operation(s))", actionID: plan.id)
        return run
    }

    public func run(_ id: UUID) -> ActionRun? {
        (try? db.queryOne("SELECT * FROM action_runs WHERE id=?", [id])).flatMap(Self.decode)
    }

    public func runs(limit: Int = 100) -> [ActionRun] {
        ((try? db.query("SELECT * FROM action_runs ORDER BY created_at DESC LIMIT ?", [limit])) ?? []).compactMap(Self.decode)
    }

    public func pendingProposals() -> [ActionRun] {
        ((try? db.query("SELECT * FROM action_runs WHERE state IN ('proposed','reviewed') ORDER BY created_at DESC")) ?? []).compactMap(Self.decode)
    }

    public func markReviewed(_ id: UUID) throws { try transition(id, to: .reviewed) }

    public func reject(_ id: UUID) throws {
        try transition(id, to: .rejected)
        activity.record(kind: "proposal", summary: "Rejected a proposed plan", actionID: id)
    }

    /// Stops future steps; never pretends to reverse completed writes.
    public func cancel(_ id: UUID) {
        lock.lock(); cancelled.insert(id); lock.unlock()
        if let r = run(id), !r.state.isTerminal, r.state.canTransition(to: .cancelled) { try? transition(id, to: .cancelled) }
    }

    // MARK: Policy

    /// Deterministic policy check, independent of any model prose.
    public func evaluate(_ plan: ActionPlan) -> [String] {
        var problems: [String] = []
        if settings.get(Settings.paused) { problems.append("Companion is paused") }
        let mode = settings.get(Settings.safetyMode)
        let maxOps = settings.get(Settings.maxOperationsPerApproval)
        if plan.operations.count > maxOps { problems.append("More than \(maxOps) operations") }
        let guardRoots = PathGuard(roots: indexing.roots().filter(\.enabled).map(\.url) + [managedRoot])
        let protectedRoots = indexing.roots().filter(\.isProtected).map { PathGuard.canonical($0.url) }
        for (i, op) in plan.operations.enumerated() {
            let n = "Operation \(i + 1)"
            if mode == .observeAndSuggest {
                let managedOnly = [.copyFile, .createFolder].contains(op.kind)
                    && op.destinationPath.map { PathGuard.isDescendant(PathGuard.canonical(URL(fileURLWithPath: $0)), of: PathGuard.canonical(managedRoot)) } == true
                if op.kind.mutatesUserContent && !managedOnly {
                    problems.append("\(n): Observe-and-suggest mode allows only copies into Companion's managed folder")
                }
            }
            if op.kind.isLocalFileWrite {
                for path in [op.sourcePath, op.destinationPath].compactMap({ $0 }) {
                    let url = URL(fileURLWithPath: path)
                    if (try? guardRoots.validate(url)) == nil, !(op.kind == .copyFile && path == op.sourcePath && indexing.asset(atPath: path) != nil) {
                        problems.append("\(n): \((path as NSString).lastPathComponent) is outside approved folders")
                    }
                    if url.pathComponents.contains(where: { [".git", ".hg", ".svn", "node_modules"].contains($0) }) {
                        problems.append("\(n): repository or dependency internals are excluded")
                    }
                    if IgnoreRules.ignoredBundleExtensions.contains(url.pathExtension) {
                        problems.append("\(n): application bundles are excluded")
                    }
                }
                if [.rename, .move, .replaceContents].contains(op.kind), let s = op.sourcePath {
                    let c = PathGuard.canonical(URL(fileURLWithPath: s))
                    if protectedRoots.contains(where: { PathGuard.isDescendant(c, of: $0) }) { problems.append("\(n): source is in a protected folder") }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: s, isDirectory: &isDir), isDir.boolValue {
                        problems.append("\(n): folder and package moves are not supported")
                    }
                    if op.sourceHash == nil { problems.append("\(n): missing reviewed source version") }
                }
                if let d = op.destinationPath {
                    let c = PathGuard.canonical(URL(fileURLWithPath: d))
                    if protectedRoots.contains(where: { PathGuard.isDescendant(c, of: $0) }) { problems.append("\(n): destination is in a protected folder") }
                }
                if op.kind == .move, let s = op.sourcePath, let d = op.destinationPath, !Self.sameVolume(s, d) {
                    problems.append("\(n): cross-volume moves are not supported")
                }
            }
            if op.kind == .createCalendarEvent {
                guard let c = op.calendar else { problems.append("\(n): missing event details"); continue }
                if !settings.get(Settings.writableCalendars).contains(c.calendarID) {
                    problems.append("\(n): \(c.calendarTitle) is not designated to receive changes")
                }
                if c.end <= c.start { problems.append("\(n): event ends before it starts") }
            }
            if op.kind.isCloud, op.docs == nil { problems.append("\(n): missing document details") }
            if op.kind == .docsEdit, op.docs?.requiredRevisionID == nil { problems.append("\(n): edits require a reviewed revision") }
            if op.kind.isCloud || op.kind == .createCalendarEvent {
                if !performers.contains(where: { $0.handles(op.kind) }) { problems.append("\(n): this connector is unavailable") }
            }
        }
        return problems
    }

    // MARK: Execution

    /// Executes an approved plan. Revalidates each operation, stops on first
    /// failure, reads back every result and journals everything.
    @discardableResult
    public func execute(_ planID: UUID, grant: ApprovalGrant) async -> ActionRun {
        guard var run = run(planID) else {
            return ActionRun(id: planID, plan: ActionPlan(title: "", operations: [], createdAt: clock.now()), state: .failed,
                             results: [], error: "Unknown plan", policyDecision: nil, createdAt: clock.now(), updatedAt: clock.now())
        }
        do {
            if run.state == .proposed { try transition(planID, to: .reviewed) }
            try approvals.consume(grant, for: run.plan)
            try transition(planID, to: .approved)
            try transition(planID, to: .validating)
        } catch {
            if run.state.canTransition(to: .expired) { try? transition(planID, to: .expired) }
            return finish(planID, error: error.localizedDescription, keepState: true)
        }
        let problems = evaluate(run.plan)
        try? db.execute("UPDATE action_runs SET policy_decision=? WHERE id=?", [problems.isEmpty ? "allowed" : problems.joined(separator: "; "), planID])
        guard problems.isEmpty else {
            try? transition(planID, to: .failed)
            return finish(planID, error: problems.joined(separator: "; "))
        }
        try? transition(planID, to: .executing)
        run = self.run(planID) ?? run
        var results: [OperationResult] = run.plan.operations.indices.map { OperationResult(index: $0, status: .pending, verified: false) }
        persist(planID, results)

        for (i, op) in run.plan.operations.enumerated() {
            if isCancelled(planID) {
                for j in i..<results.count { results[j].status = .skipped; results[j].detail = "Cancelled before this step" }
                persist(planID, results)
                try? transition(planID, to: i == 0 ? .cancelled : .partiallyCompleted)
                return finish(planID, error: "Cancelled; \(i) step(s) completed and were not reversed")
            }
            do {
                let result: OperationResult
                if let performer = performers.first(where: { $0.handles(op.kind) }) {
                    try await performer.validate(op)
                    result = try await performer.perform(op, actionID: planID, index: i)
                } else {
                    result = try performLocal(op, actionID: planID, index: i)
                }
                results[i] = result
                persist(planID, results)
                if result.status != .succeeded || !result.verified { throw CompanionError.outcomeUnknown(result.detail ?? "Verification failed") }
            } catch {
                results[i].status = (error as? CompanionError).map { if case .outcomeUnknown = $0 { return .outcomeUnknown }; return .failed } ?? .failed
                results[i].detail = error.localizedDescription
                for j in (i + 1)..<results.count { results[j].status = .skipped; results[j].detail = "Not run because an earlier step failed" }
                persist(planID, results)
                let state: ActionState = results[i].status == .outcomeUnknown ? .outcomeUnknown : (i == 0 ? .failed : .partiallyCompleted)
                try? transition(planID, to: state)
                return finish(planID, error: error.localizedDescription)
            }
        }
        try? transition(planID, to: .verifying)
        try? transition(planID, to: .succeeded)
        activity.record(kind: "action", initiator: run.plan.initiator, summary: "Applied: \(run.plan.title) — verified", actionID: planID)
        return finish(planID, error: nil)
    }

    // MARK: Local operations

    func performLocal(_ op: PlannedOperation, actionID: UUID, index: Int) throws -> OperationResult {
        let fm = FileManager.default
        let guardRoots = PathGuard(roots: indexing.roots().filter(\.enabled).map(\.url) + [managedRoot])
        func checkSource() throws -> URL {
            guard let s = op.sourcePath else { throw CompanionError.invalidArgument("Missing source") }
            let url = URL(fileURLWithPath: s)
            guard fm.fileExists(atPath: s) else { throw CompanionError.notFound((s as NSString).lastPathComponent) }
            if op.kind != .copyFile || indexing.asset(atPath: s) == nil { try guardRoots.validate(url) }
            if let expected = op.sourceHash {
                let actual = try Hashing.sha256Hex(fileAt: url)
                guard actual == expected else { throw CompanionError.staleSource(url.lastPathComponent) }
            }
            return url
        }
        func checkDestination() throws -> URL {
            guard let d = op.destinationPath else { throw CompanionError.invalidArgument("Missing destination") }
            let url = try guardRoots.validate(URL(fileURLWithPath: d))
            guard !fm.fileExists(atPath: url.path) else { throw CompanionError.collision(url.lastPathComponent) }
            return url
        }

        switch op.kind {
        case .addReference:
            let src = try checkSource()
            let asset = try indexing.addReference(src)
            return OperationResult(index: index, status: .succeeded, verified: true, detail: nil, resultPath: asset.path)

        case .createFolder:
            let dst = try checkDestination()
            try fm.createDirectory(at: dst, withIntermediateDirectories: false)
            var isDir: ObjCBool = false
            let ok = fm.fileExists(atPath: dst.path, isDirectory: &isDir) && isDir.boolValue
            return OperationResult(index: index, status: ok ? .succeeded : .failed, verified: ok, detail: nil, resultPath: dst.path)

        case .copyFile:
            let src = try checkSource()
            let dst = try checkDestination()
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = dst.deletingLastPathComponent().appendingPathComponent(".companion-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: src, to: temp)
            let srcHash = try Hashing.sha256Hex(fileAt: src)
            guard try Hashing.sha256Hex(fileAt: temp) == srcHash else { throw CompanionError.outcomeUnknown("Copy verification failed") }
            try WorkingCopyService.publishNoOverwrite(temp, to: dst)
            let readBack = try Hashing.sha256Hex(fileAt: dst)
            return OperationResult(index: index, status: .succeeded, verified: readBack == srcHash, detail: nil, resultPath: dst.path, resultHash: readBack)

        case .rename, .move:
            let src = try checkSource()
            let dst = try checkDestination()
            let before = try Hashing.sha256Hex(fileAt: src)
            try recordRecovery(actionID: actionID, index: index, kind: op.kind.rawValue, beforePath: src.path, snapshot: nil, hash: before)
            let rc = src.path.withCString { s in dst.path.withCString { d in renamex_np(s, d, UInt32(RENAME_EXCL)) } }
            if rc != 0 {
                if errno == EEXIST { throw CompanionError.collision(dst.lastPathComponent) }
                throw CompanionError.permissionDenied("Could not \(op.kind.rawValue) \(src.lastPathComponent)")
            }
            let after = try Hashing.sha256Hex(fileAt: dst)
            let verified = after == before && !fm.fileExists(atPath: src.path)
            indexing.reconcile(path: dst.path)
            return OperationResult(index: index, status: .succeeded, verified: verified, detail: nil, resultPath: dst.path, resultHash: after)

        case .replaceContents:
            let src = try checkSource()
            guard let replacement = op.replacementPath, fm.fileExists(atPath: replacement) else {
                throw CompanionError.notFound("Replacement draft")
            }
            // A recoverable snapshot is mandatory; block the replacement if it cannot be made.
            let snapshot: URL
            do { snapshot = try makeSnapshot(of: src, actionID: actionID, index: index) }
            catch { throw CompanionError.policyViolation("Snapshot could not be created; replacement blocked") }
            let before = try Hashing.sha256Hex(fileAt: src)
            try recordRecovery(actionID: actionID, index: index, kind: "replace", beforePath: src.path, snapshot: snapshot.path, hash: before)
            let newData = try Data(contentsOf: URL(fileURLWithPath: replacement))
            try newData.write(to: src, options: .atomic)
            let after = try Hashing.sha256Hex(fileAt: src)
            indexing.reconcile(path: src.path)
            return OperationResult(index: index, status: .succeeded, verified: after == Hashing.sha256Hex(newData), detail: nil,
                                   resultPath: src.path, resultHash: after)

        case .createCalendarEvent, .docsCreate, .docsCopy, .docsEdit:
            throw CompanionError.unsupported("No connector available for \(op.kind.verb)")
        }
    }

    // MARK: Undo (conditional)

    public enum UndoOutcome: Equatable, Sendable { case restored, restoredAsCopy(String), notPossible(String) }

    /// Reverses a verified local operation only if no later edits would be overwritten.
    public func undo(actionID: UUID, index: Int) -> UndoOutcome {
        guard let run = run(actionID), index < run.plan.operations.count, index < run.results.count,
              run.results[index].status == .succeeded else { return .notPossible("Nothing verified to undo") }
        let op = run.plan.operations[index]
        let result = run.results[index]
        let fm = FileManager.default
        switch op.kind {
        case .rename, .move:
            guard let now = result.resultPath, let original = op.sourcePath else { return .notPossible("Missing paths") }
            guard fm.fileExists(atPath: now) else { return .notPossible("The file is no longer at its new location") }
            guard !fm.fileExists(atPath: original) else { return .notPossible("Something now exists at the original location") }
            let current = try? Hashing.sha256Hex(fileAt: URL(fileURLWithPath: now))
            guard current == result.resultHash else { return .notPossible("The file was edited after the move; move it back manually") }
            let rc = now.withCString { s in original.withCString { d in renamex_np(s, d, UInt32(RENAME_EXCL)) } }
            guard rc == 0 else { return .notPossible("Move back failed") }
            indexing.reconcile(path: original)
            activity.record(kind: "undo", summary: "Undid \(op.kind.verb) of \((original as NSString).lastPathComponent)", actionID: actionID)
            return .restored
        case .replaceContents:
            guard let path = op.sourcePath,
                  let rec = try? db.queryOne("SELECT snapshot_path FROM recovery_records WHERE action_id=? AND operation_index=?", [actionID, index]),
                  let snap = rec.string("snapshot_path"), fm.fileExists(atPath: snap) else { return .notPossible("No snapshot available") }
            let current = try? Hashing.sha256Hex(fileAt: URL(fileURLWithPath: path))
            if current == result.resultHash {
                guard (try? fm.removeItem(atPath: path)) != nil, (try? fm.copyItem(atPath: snap, toPath: path)) != nil else {
                    return .notPossible("Restore failed; snapshot kept at \(snap)")
                }
                indexing.reconcile(path: path)
                activity.record(kind: "undo", summary: "Restored previous contents", actionID: actionID)
                return .restored
            }
            // Later edits exist: never overwrite them — restore alongside instead.
            let dest = WorkingCopyService.uniqueDestination(for: "Restored " + (path as NSString).lastPathComponent,
                                                            in: URL(fileURLWithPath: path).deletingLastPathComponent())
            guard (try? fm.copyItem(atPath: snap, toPath: dest.path)) != nil else { return .notPossible("Restore failed") }
            activity.record(kind: "undo", summary: "Restored previous contents as a separate copy (file had later edits)", actionID: actionID)
            return .restoredAsCopy(dest.path)
        default:
            return .notPossible("Undo for \(op.kind.verb) is a new reviewed operation")
        }
    }

    // MARK: Crash recovery

    /// Inspects unfinished runs after a restart and resolves them from external state.
    public func reconcileUnfinished() async {
        let rows = (try? db.query("SELECT * FROM action_runs WHERE state IN ('approved','validating','executing','verifying','outcomeUnknown')")) ?? []
        for run in rows.compactMap(Self.decode) {
            var results = run.results
            if results.count < run.plan.operations.count {
                results = run.plan.operations.indices.map { i in i < run.results.count ? run.results[i] : OperationResult(index: i, status: .pending, verified: false) }
            }
            for (i, op) in run.plan.operations.enumerated() where results[i].status == .pending || results[i].status == .outcomeUnknown {
                if let performer = performers.first(where: { $0.handles(op.kind) }) {
                    if let r = await performer.reconcile(op, actionID: run.id, index: i) { results[i] = r }
                } else {
                    results[i] = reconcileLocal(op, index: i)
                }
            }
            persist(run.id, results)
            let statuses = results.map(\.status)
            let final: ActionState
            if statuses.allSatisfy({ $0 == .succeeded }) { final = .succeeded }
            else if statuses.contains(.outcomeUnknown) { final = .outcomeUnknown }
            else if statuses.contains(.succeeded) { final = .partiallyCompleted }
            else { final = .failed }
            try? db.execute("UPDATE action_runs SET state=?, error=?, updated_at=? WHERE id=?",
                            [final.rawValue, final == .succeeded ? nil : "Interrupted; reconciled after restart", clock.now(), run.id])
            activity.record(kind: "recovery", initiator: "system", summary: "Reconciled interrupted action: \(final.rawValue)", actionID: run.id)
        }
    }

    func reconcileLocal(_ op: PlannedOperation, index: Int) -> OperationResult {
        let fm = FileManager.default
        switch op.kind {
        case .copyFile, .rename, .move, .createFolder:
            guard let d = op.destinationPath else { return OperationResult(index: index, status: .failed, verified: false, detail: "No destination") }
            if fm.fileExists(atPath: d) {
                let h = try? Hashing.sha256Hex(fileAt: URL(fileURLWithPath: d))
                let matches = op.kind == .createFolder || op.sourceHash == nil || h == op.sourceHash
                if op.kind == .copyFile || op.kind == .createFolder || (op.sourcePath.map { !fm.fileExists(atPath: $0) } ?? true) {
                    return OperationResult(index: index, status: matches ? .succeeded : .outcomeUnknown, verified: matches,
                                           detail: "Found at destination after restart", resultPath: d, resultHash: h)
                }
            }
            return OperationResult(index: index, status: .failed, verified: false, detail: "Not performed before interruption")
        default:
            return OperationResult(index: index, status: .outcomeUnknown, verified: false, detail: "Needs manual review")
        }
    }

    // MARK: Helpers

    private func makeSnapshot(of url: URL, actionID: UUID, index: Int) throws -> URL {
        let dir = recoveryDirectory.appendingPathComponent(actionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(index)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: dest)
        guard try Hashing.sha256Hex(fileAt: dest) == Hashing.sha256Hex(fileAt: url) else {
            throw CompanionError.outcomeUnknown("Snapshot verification failed")
        }
        return dest
    }

    private func recordRecovery(actionID: UUID, index: Int, kind: String, beforePath: String?, snapshot: String?, hash: String?) throws {
        try db.execute("""
            INSERT INTO recovery_records(id, action_id, operation_index, kind, before_path, snapshot_path, before_hash, created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [UUID(), actionID, index, kind, beforePath, snapshot, hash, clock.now()])
    }

    /// Rotates app-owned recovery storage, never discarding the sole record for an unresolved action.
    public func pruneRecovery() {
        let days = settings.get(Settings.recoveryRetentionDays)
        let cutoff = clock.now().addingTimeInterval(-Double(days) * 86_400)
        let rows = (try? db.query("""
            SELECT r.id, r.snapshot_path FROM recovery_records r JOIN action_runs a ON a.id = r.action_id
            WHERE r.created_at < ? AND a.state = 'succeeded'
            """, [cutoff])) ?? []
        for r in rows {
            if let p = r.string("snapshot_path") { try? FileManager.default.removeItem(atPath: p) }
            try? db.execute("DELETE FROM recovery_records WHERE id=?", [r.string("id")])
        }
    }

    private func isCancelled(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(id) }

    private func persist(_ id: UUID, _ results: [OperationResult]) {
        try? db.execute("UPDATE action_runs SET results=?, updated_at=? WHERE id=?", [(try? JSON.encode(results)) ?? "[]", clock.now(), id])
    }

    func transition(_ id: UUID, to next: ActionState) throws {
        guard let current = run(id)?.state else { throw CompanionError.notFound("action") }
        guard current.canTransition(to: next) else {
            throw CompanionError.policyViolation("Invalid action transition \(current.rawValue) → \(next.rawValue)")
        }
        try db.execute("UPDATE action_runs SET state=?, updated_at=? WHERE id=?", [next.rawValue, clock.now(), id])
    }

    private func finish(_ id: UUID, error: String?, keepState: Bool = false) -> ActionRun {
        if let error { try? db.execute("UPDATE action_runs SET error=? WHERE id=?", [Redactor.redact(error), id]) }
        if let error { activity.record(kind: "action", summary: "Action stopped: \(error)", actionID: id) }
        return run(id)!
    }

    static func sameVolume(_ a: String, _ b: String) -> Bool {
        let ua = URL(fileURLWithPath: a), ub = URL(fileURLWithPath: b).deletingLastPathComponent()
        let va = try? ua.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let vb = try? ub.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let va, let vb else { return false }
        return va.isEqual(vb)
    }

    static func decode(_ r: SQLRow) -> ActionRun? {
        guard let id = r.uuid("id"), let plan = r.json("plan", as: ActionPlan.self),
              let state = ActionState(rawValue: r.string("state") ?? ""), let created = r.date("created_at") else { return nil }
        return ActionRun(id: id, plan: plan, state: state, results: r.json("results", as: [OperationResult].self) ?? [],
                         error: r.string("error"), policyDecision: r.string("policy_decision"), createdAt: created,
                         updatedAt: r.date("updated_at") ?? created)
    }
}

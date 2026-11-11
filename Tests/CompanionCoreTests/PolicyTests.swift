import XCTest
@testable import CompanionCore

final class PolicyTests: XCTestCase {
    private func setup(mode: SafetyMode = .reviewedChanges) throws -> (TestEnv, Root) {
        let t = TestEnv()
        t.env.settings.set(Settings.safetyMode, mode)
        let root = try t.env.indexing.addRoot(t.root)
        return (t, root)
    }

    private func movePlan(_ t: TestEnv, from: URL, to: URL) throws -> ActionPlan {
        ActionPlan(title: "Move", operations: [PlannedOperation(kind: .move, sourcePath: from.path, sourceHash: try Hashing.sha256Hex(fileAt: from),
                                                                destinationPath: to.path)], createdAt: t.clock.now())
    }

    func testStateMachineRejectsInvalidTransitions() {
        XCTAssertTrue(ActionState.proposed.canTransition(to: .reviewed))
        XCTAssertFalse(ActionState.proposed.canTransition(to: .executing))
        XCTAssertFalse(ActionState.succeeded.canTransition(to: .executing))
        XCTAssertTrue(ActionState.executing.canTransition(to: .outcomeUnknown))
    }

    func testPlanHashChangesWithAnyOperationChange() throws {
        let t = TestEnv()
        var plan = ActionPlan(title: "x", operations: [PlannedOperation(kind: .createFolder, destinationPath: "/tmp/a")], createdAt: t.clock.now())
        let h = plan.hash
        plan.operations[0].destinationPath = "/tmp/b"
        XCTAssertNotEqual(h, plan.hash)
        XCTAssertEqual(ActionPlan(title: "m", operations: Array(repeating: PlannedOperation(kind: .move), count: 3), createdAt: Date()).applyLabel, "Apply 3 moves")
    }

    func testApprovedMoveExecutesVerifiesAndUndoes() async throws {
        let (t, root) = try setup()
        let src = t.temp.write("Root/Downloads/Practice.pdf", "pdf bytes")
        let dest = t.temp.mkdir("Root/Math/Unit 3").appendingPathComponent("Practice.pdf")
        t.env.indexing.scan(root)
        let plan = try movePlan(t, from: src, to: dest)
        try t.env.executor.propose(plan)
        let grant = t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now())
        let run = await t.env.executor.execute(plan.id, grant: grant)
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(run.results[0].verified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(t.env.executor.undo(actionID: plan.id, index: 0), .restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testUndoRefusesWhenFileEditedAfterMove() async throws {
        let (t, _) = try setup()
        let src = t.temp.write("Root/a.txt", "v1")
        let dest = t.root.appendingPathComponent("b.txt")
        let plan = try movePlan(t, from: src, to: dest)
        try t.env.executor.propose(plan)
        let run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .succeeded)
        try Data("v2 edited".utf8).write(to: dest)
        guard case .notPossible = t.env.executor.undo(actionID: plan.id, index: 0) else { return XCTFail("undo must not overwrite later edits") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testObserveModeBlocksOriginalChanges() async throws {
        let (t, _) = try setup(mode: .observeAndSuggest)
        let src = t.temp.write("Root/a.txt", "x")
        let plan = try movePlan(t, from: src, to: t.root.appendingPathComponent("b.txt"))
        try t.env.executor.propose(plan)
        let run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(run.error?.contains("Observe-and-suggest") == true)
    }

    func testObserveModeAllowsReviewedCopyIntoManagedFolder() async throws {
        let (t, _) = try setup(mode: .observeAndSuggest)
        let src = t.temp.write("Root/a.txt", "x")
        let dest = t.env.paths.managedWorkspaces.appendingPathComponent("P/a.txt")
        let plan = ActionPlan(title: "Copy", operations: [PlannedOperation(kind: .copyFile, sourcePath: src.path, sourceHash: try Hashing.sha256Hex(fileAt: src), destinationPath: dest.path)], createdAt: t.clock.now())
        try t.env.executor.propose(plan)
        let run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original untouched")
    }

    func testForgedReusedExpiredAndMismatchedGrantsAreRejected() async throws {
        let (t, _) = try setup()
        let src = t.temp.write("Root/a.txt", "x")
        let plan = try movePlan(t, from: src, to: t.root.appendingPathComponent("b.txt"))
        try t.env.executor.propose(plan)

        // Forged: never issued by the authority.
        let forged = ApprovalGrant(id: UUID(), planHash: plan.hash, issuedAt: t.clock.now(), expiresAt: t.clock.now() + 60, policyVersion: 1)
        var run = await t.env.executor.execute(plan.id, grant: forged)
        XCTAssertEqual(run.state, .expired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))

        // Expired.
        let plan2 = try movePlan(t, from: src, to: t.root.appendingPathComponent("c.txt"))
        try t.env.executor.propose(plan2)
        let g2 = t.env.approvals.issue(for: plan2, userConfirmedAt: t.clock.now())
        t.clock.advance(61)
        run = await t.env.executor.execute(plan2.id, grant: g2)
        XCTAssertEqual(run.state, .expired)

        // Bound to a different plan.
        let plan3 = try movePlan(t, from: src, to: t.root.appendingPathComponent("d.txt"))
        let plan4 = try movePlan(t, from: src, to: t.root.appendingPathComponent("e.txt"))
        try t.env.executor.propose(plan3); try t.env.executor.propose(plan4)
        run = await t.env.executor.execute(plan4.id, grant: t.env.approvals.issue(for: plan3, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .expired)

        // Policy change after approval invalidates it.
        let plan5 = try movePlan(t, from: src, to: t.root.appendingPathComponent("f.txt"))
        try t.env.executor.propose(plan5)
        let g5 = t.env.approvals.issue(for: plan5, userConfirmedAt: t.clock.now())
        t.env.approvals.bumpPolicyVersion()
        run = await t.env.executor.execute(plan5.id, grant: g5)
        XCTAssertEqual(run.state, .expired)

        // Reuse: a consumed grant cannot run again.
        let plan6 = try movePlan(t, from: src, to: t.root.appendingPathComponent("g.txt"))
        try t.env.executor.propose(plan6)
        let g6 = t.env.approvals.issue(for: plan6, userConfirmedAt: t.clock.now())
        run = await t.env.executor.execute(plan6.id, grant: g6)
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertThrowsError(try t.env.approvals.consume(g6, for: plan6))
    }

    func testStaleSourceCollisionAndPathEscapeAreBlocked() async throws {
        let (t, _) = try setup()
        let src = t.temp.write("Root/a.txt", "v1")
        // Stale: source changed after review.
        let plan = try movePlan(t, from: src, to: t.root.appendingPathComponent("b.txt"))
        try Data("v2".utf8).write(to: src)
        try t.env.executor.propose(plan)
        var run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.error?.contains("changed") == true)

        // Collision: never overwrite.
        let existing = t.temp.write("Root/existing.txt", "keep me")
        let plan2 = try movePlan(t, from: src, to: existing)
        try t.env.executor.propose(plan2)
        run = await t.env.executor.execute(plan2.id, grant: t.env.approvals.issue(for: plan2, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")

        // Escape via symlink to outside the approved root.
        let outside = t.temp.mkdir("Outside")
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("escape"), withDestinationURL: outside)
        let plan3 = try movePlan(t, from: src, to: t.root.appendingPathComponent("escape/stolen.txt"))
        try t.env.executor.propose(plan3)
        run = await t.env.executor.execute(plan3.id, grant: t.env.approvals.issue(for: plan3, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("stolen.txt").path))

        // Traversal.
        let plan4 = try movePlan(t, from: src, to: URL(fileURLWithPath: t.root.path + "/../Outside/x.txt"))
        try t.env.executor.propose(plan4)
        run = await t.env.executor.execute(plan4.id, grant: t.env.approvals.issue(for: plan4, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testProtectedFoldersAndRepositoryInternalsAreExcluded() async throws {
        let t = TestEnv()
        t.env.settings.set(Settings.safetyMode, .reviewedChanges)
        let protectedDir = t.temp.mkdir("Root/Archive")
        _ = try t.env.indexing.addRoot(t.root)
        _ = try t.env.indexing.addRoot(protectedDir, isProtected: true)
        let src = t.temp.write("Root/Archive/old.txt", "x")
        let plan = try movePlan(t, from: src, to: t.root.appendingPathComponent("old.txt"))
        XCTAssertTrue(t.env.executor.evaluate(plan).contains { $0.contains("protected") })
        let git = t.temp.write("Root/repo/.git/config", "x")
        let plan2 = try movePlan(t, from: git, to: t.root.appendingPathComponent("config"))
        XCTAssertTrue(t.env.executor.evaluate(plan2).contains { $0.contains("repository") })
        let folder = t.temp.mkdir("Root/Folder")
        let plan3 = ActionPlan(title: "m", operations: [PlannedOperation(kind: .move, sourcePath: folder.path, sourceHash: "x", destinationPath: t.root.appendingPathComponent("F2").path)], createdAt: Date())
        XCTAssertTrue(t.env.executor.evaluate(plan3).contains { $0.contains("folder") })
    }

    func testOperationCapAndPause() throws {
        let (t, _) = try setup()
        let ops = (0..<21).map { PlannedOperation(kind: .createFolder, destinationPath: t.root.appendingPathComponent("f\($0)").path) }
        XCTAssertThrowsError(try t.env.executor.propose(ActionPlan(title: "big", operations: ops, createdAt: Date())))
        t.env.setPaused(true)
        let plan = ActionPlan(title: "one", operations: [ops[0]], createdAt: Date())
        XCTAssertTrue(t.env.executor.evaluate(plan).contains("Companion is paused"))
    }

    func testBatchStopsOnFirstFailureAndReportsPartialCompletion() async throws {
        let (t, _) = try setup()
        let a = t.temp.write("Root/a.txt", "a")
        let b = t.temp.write("Root/b.txt", "b")
        let c = t.temp.write("Root/c.txt", "c")
        t.temp.write("Root/taken.txt", "taken")
        let plan = ActionPlan(title: "3 moves", operations: [
            PlannedOperation(kind: .rename, sourcePath: a.path, sourceHash: try Hashing.sha256Hex(fileAt: a), destinationPath: t.root.appendingPathComponent("a2.txt").path),
            PlannedOperation(kind: .rename, sourcePath: b.path, sourceHash: try Hashing.sha256Hex(fileAt: b), destinationPath: t.root.appendingPathComponent("taken.txt").path),
            PlannedOperation(kind: .rename, sourcePath: c.path, sourceHash: try Hashing.sha256Hex(fileAt: c), destinationPath: t.root.appendingPathComponent("c2.txt").path),
        ], createdAt: t.clock.now())
        try t.env.executor.propose(plan)
        let run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .partiallyCompleted)
        XCTAssertEqual(run.results.map(\.status), [.succeeded, .failed, .skipped])
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path), "later steps not run")
    }

    func testReplaceRequiresSnapshotAndUndoKeepsLaterEdits() async throws {
        let (t, _) = try setup()
        let original = t.temp.write("Root/essay.txt", "original text")
        let draft = t.temp.write("Root/draft.txt", "revised text")
        let plan = ActionPlan(title: "Replace", operations: [PlannedOperation(kind: .replaceContents, sourcePath: original.path,
            sourceHash: try Hashing.sha256Hex(fileAt: original), replacementPath: draft.path)], createdAt: t.clock.now())
        try t.env.executor.propose(plan)
        let run = await t.env.executor.execute(plan.id, grant: t.env.approvals.issue(for: plan, userConfirmedAt: t.clock.now()))
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "revised text")
        try Data("revised text plus later user edits".utf8).write(to: original)
        guard case .restoredAsCopy(let path) = t.env.executor.undo(actionID: plan.id, index: 0) else { return XCTFail("expected restored copy") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original text")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "revised text plus later user edits")
    }

    func testCrashRecoveryReconcilesFromFilesystem() async throws {
        let (t, _) = try setup()
        let src = t.temp.write("Root/a.txt", "data")
        let dest = t.root.appendingPathComponent("b.txt")
        let plan = try movePlan(t, from: src, to: dest)
        try t.env.executor.propose(plan)
        // Simulate a crash after the rename but before the journal recorded success.
        try t.env.db.execute("UPDATE action_runs SET state='executing', results='[]' WHERE id=?", [plan.id])
        try FileManager.default.moveItem(at: src, to: dest)
        await t.env.executor.reconcileUnfinished()
        XCTAssertEqual(t.env.executor.run(plan.id)?.state, .succeeded)
    }

    func testCalendarAndDocsWritesRequireDesignationAndConnector() throws {
        let t = TestEnv()
        t.env.settings.set(Settings.safetyMode, .reviewedChanges)
        let spec = FocusBlockSpec(calendarID: "cal", calendarTitle: "School", title: "Focus", start: Date() + 3600, end: Date() + 7200, timeZone: "UTC")
        let plan = ActionPlan(title: "f", operations: [PlannedOperation(kind: .createCalendarEvent, calendar: spec)], createdAt: Date())
        XCTAssertTrue(t.env.executor.evaluate(plan).contains { $0.contains("not designated") })
        let docs = ActionPlan(title: "d", operations: [PlannedOperation(kind: .docsEdit, docs: DocsOperationSpec(accountID: UUID(), accountIdentity: "a", documentID: "x", documentTitle: "Doc", requiredRevisionID: nil))], createdAt: Date())
        XCTAssertTrue(t.env.executor.evaluate(docs).contains { $0.contains("reviewed revision") })
    }

    func testModelProposalsNeverExecuteWithoutGrant() throws {
        let (t, _) = try setup()
        let src = t.temp.write("Root/a.txt", "x")
        let plan = ActionPlan(title: "proposal", operations: [PlannedOperation(kind: .rename, sourcePath: src.path, sourceHash: try Hashing.sha256Hex(fileAt: src),
                                                                               destinationPath: t.root.appendingPathComponent("z.txt").path)],
                              initiator: "model proposal", createdAt: t.clock.now())
        // 100 propose/reject cycles: no mutation ever occurs without an approval grant.
        for _ in 0..<100 {
            var p = plan
            p = ActionPlan(title: p.title, operations: p.operations, initiator: p.initiator, createdAt: t.clock.now())
            try t.env.executor.propose(p)
            try t.env.executor.reject(p.id)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.root.appendingPathComponent("z.txt").path))
    }
}

final class WorkspaceTests: XCTestCase {
    func testWorkingCopyLifecycleAndDivergence() throws {
        let t = TestEnv()
        let src = t.temp.write("Root/paper.txt", "base")
        let p = try t.env.projects.create(name: "Research")
        let folder = t.env.copies.folder(for: p)
        let wc = try t.env.copies.createCopy(of: src, into: folder, projectID: p.id)
        XCTAssertEqual(wc.state, .current)
        let wc2 = try t.env.copies.createCopy(of: src, into: folder, projectID: p.id)
        XCTAssertEqual((wc2.copyPath as NSString).lastPathComponent, "paper (2).txt", "unique names, no overwrite")
        XCTAssertTrue(t.env.indexing.asset(atPath: wc.copyPath)?.isManagedCopy == true)

        try Data("source edit".utf8).write(to: src)
        XCTAssertEqual(t.env.copies.refreshState(wc.id), .sourceChanged)
        try Data("copy edit".utf8).write(to: URL(fileURLWithPath: wc.copyPath))
        XCTAssertEqual(t.env.copies.refreshState(wc.id), .conflict)
        let both = try t.env.copies.keepBoth(wc.id)
        XCTAssertEqual(try String(contentsOfFile: both.copyPath, encoding: .utf8), "source edit")
        XCTAssertEqual(try String(contentsOfFile: wc.copyPath, encoding: .utf8), "copy edit", "existing copy untouched")
    }

    func testPublishNoOverwrite() throws {
        let tmp = TempDir()
        let a = tmp.write("a", "new"), b = tmp.write("b", "old")
        XCTAssertThrowsError(try WorkingCopyService.publishNoOverwrite(a, to: b))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "old")
    }

    func testCopyRulesOffByDefaultQuotaAndOnce() throws {
        let t = TestEnv()
        let root = try t.env.indexing.addRoot(t.root)
        let dest = t.env.paths.managedWorkspaces.appendingPathComponent("Inbox")
        let rule = try t.env.copyRules.create(rootID: root.id, pattern: "*.pdf", destination: dest, maxFiles: 2)
        XCTAssertFalse(rule.enabled)
        for i in 0..<3 { t.temp.write("Root/r\(i).pdf", "pdf \(i)") }
        t.temp.write("Root/notes.txt", "n")
        t.env.indexing.scan(root)
        let assets = t.env.indexing.assets(rootID: root.id)
        XCTAssertTrue(t.env.copyRules.apply(newAssets: assets).isEmpty, "disabled rule copies nothing")
        try t.env.copyRules.setEnabled(rule.id, true)
        XCTAssertEqual(t.env.copyRules.apply(newAssets: assets).count, 2, "quota enforced")
        XCTAssertEqual(t.env.copyRules.apply(newAssets: assets).count, 0, "each file copied once")
        for i in 0..<3 { XCTAssertTrue(FileManager.default.fileExists(atPath: t.root.appendingPathComponent("r\(i).pdf").path)) }
        XCTAssertTrue(CopyRuleService.matches("Week3.PDF", pattern: "*.pdf"))
    }

    func testRemovingCardNeverDeletesFile() throws {
        let t = TestEnv()
        let f = t.temp.write("Root/keep.txt", "k")
        let asset = try t.env.indexing.addReference(f)
        let p = try t.env.projects.create(name: "P")
        let item = try t.env.projects.addItem(projectID: p.id, kind: .file, targetID: asset.id)
        try t.env.projects.removeItem(item.id)
        try t.env.projects.delete(p.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testCheckpointsSearchableAndResume() throws {
        let t = TestEnv()
        let p = try t.env.projects.create(name: "Lit review")
        try t.env.projects.saveCheckpoint(projectID: p.id, note: "Finished the introduction", nextStep: "Check the second example")
        XCTAssertEqual(t.env.projects.latestCheckpoint(projectID: p.id)?.nextStep, "Check the second example")
        XCTAssertEqual(t.env.projects.lastActive?.id, p.id)
        XCTAssertEqual(t.env.search.search("introduction").first?.kind, .checkpoint)
    }
}

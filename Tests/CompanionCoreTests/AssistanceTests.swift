import XCTest
@testable import CompanionCore

final class RequirementTests: XCTestCase {
    func testMathAssignmentSeparatesRequiredOptionalAndResources() {
        let text = """
        HW#40: Section 13.5 problems 1, 5, 9, 11, 15, 17, 21, 23, 31, 49, and 50. Optional: 53, 54.
        Read Section 13.6 and watch the directional derivative video.
        """
        let (reqs, _) = RequirementExtractor().extract(text)
        let required = reqs.filter { $0.status == .required }
        let optional = reqs.filter { $0.status == .optional }
        XCTAssertEqual(required.count, 11)
        XCTAssertEqual(Set(optional.map(\.text)), ["Section 13.5 problem 53", "Section 13.5 problem 54"])
        XCTAssertTrue(required.allSatisfy { $0.note?.contains("not provided") == true }, "never invents problem statements")
        XCTAssertTrue(reqs.contains { $0.status == .inferred && $0.text.contains("13.6") })
        XCTAssertTrue(reqs.allSatisfy { !$0.evidence.isEmpty })
    }

    func testEssayAssignmentFormattingAndSubmission() {
        let text = """
        Write a thematic synthesis of other researchers' work. Include an introduction that identifies the topic and central argument.
        Use 12-point font, double-spaced, with one-inch margins.
        Submit the Google Doc link with editing access for your teacher. Extra credit: add a visual.
        Due November 16, 2026 at 11:59 PM.
        """
        let (reqs, deadlines) = RequirementExtractor().extract(text)
        XCTAssertTrue(reqs.contains { $0.text.lowercased().contains("font size") && $0.status == .required })
        XCTAssertTrue(reqs.contains { $0.text.lowercased().contains("spacing") })
        XCTAssertTrue(reqs.contains { $0.text.lowercased().contains("margins") })
        XCTAssertTrue(reqs.contains { $0.note?.contains("will not submit") == true })
        XCTAssertTrue(reqs.contains { $0.status == .optional && $0.text.contains("visual") })
        XCTAssertTrue(reqs.contains { $0.text.contains("introduction") && $0.status == .required })
        XCTAssertEqual(deadlines.count, 1)
    }

    func testTaskDeadlinesStayProposedUntilConfirmed() throws {
        let t = TestEnv()
        let task = try t.env.tasks.create(title: "Lit review draft", projectID: nil, proposedDeadline: t.clock.now() + 86_400, evidence: "Calendar event start")
        XCTAssertFalse(task.deadlineConfirmed)
        let reqs = try t.env.tasks.extractRequirements(taskID: task.id, from: "Section 2.1 problems 1-3.")
        XCTAssertEqual(reqs.count, 3)
        XCTAssertTrue(reqs.allSatisfy { $0.confirmation == .unconfirmed })
        try t.env.tasks.setDone(reqs[0].id, true)
        XCTAssertEqual(t.env.tasks.progress(taskID: task.id).done, 1)
        XCTAssertEqual(t.env.tasks.nextUnfinished(taskID: task.id)?.id, reqs[1].id)
        try t.env.tasks.confirmDeadline(task.id, date: t.clock.now() + 3_600)
        XCTAssertTrue(t.env.tasks.task(task.id)!.deadlineConfirmed)
    }
}

final class FilingTests: XCTestCase {
    func testAnalyzerFindsConventions() {
        let paths = [
            "Bio/2025/2025-09-01 Cells notes.md", "Bio/2025/2025-09-08 Mitosis notes.md", "Bio/2026/2026-01-10 Genetics notes.md",
            "Bio/2026/2026-02-01 Evolution notes.md", "Research/Drafts/Lit review draft.docx", "Research/Drafts/Intro v2.docx",
            "Research/Drafts/Methods final.docx", "Research/Readings/smith2020.pdf", "Research/Readings/lee2021.pdf", "Research/Readings/kim2019.pdf",
        ]
        let findings = FilingAnalyzer.analyze(paths: paths)
        XCTAssertTrue(findings.contains { $0.field == .naming && $0.statement.contains("date") })
        XCTAssertTrue(findings.contains { $0.field == .naming && $0.statement.contains("suffix") })
        XCTAssertTrue(findings.contains { $0.field == .placement && $0.statement.contains("“Readings” folders hold .pdf") })
        XCTAssertTrue(findings.contains { $0.statement.contains("separate subfolders") })
        XCTAssertTrue(findings.contains { $0.field == .hierarchy })
    }

    func testLearnCreatesCandidatesUntilConfirmed() throws {
        let t = TestEnv()
        for n in ["2026-01-01 a.md", "2026-01-02 b.md", "2026-01-03 c.md", "2026-01-04 d.md"] { t.temp.write("Root/Notes/\(n)", "x") }
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root)
        let created = try t.env.filing.learn()
        XCTAssertFalse(created.isEmpty)
        XCTAssertTrue(created.allSatisfy { $0.status == .candidate }, "silence is never acceptance")
        try t.env.filing.confirm(created[0].id)
        XCTAssertEqual(t.env.filing.rules().first { $0.id == created[0].id }?.status, .explicit)
        try t.env.filing.edit(created[0].id, statement: "Notes start with an ISO date")
        XCTAssertTrue(t.env.filing.rules(includeInactive: true).contains { $0.id == created[0].id && $0.status == .superseded })
        XCTAssertTrue(try t.env.filing.learn().isEmpty, "re-learning does not duplicate rules")
    }

    func testPlacementRanksAbstainsAndRespectsProtection() {
        let ctx = PlacementSuggester.Context(existing: [
            ("Math/Unit 3", "Directional derivatives practice.pdf"), ("Math/Unit 3", "Gradient worksheet.pdf"),
            ("Math/Unit 2", "Limits practice.pdf"), ("Research/Readings", "smith2020.pdf"), ("Archive", "Directional derivatives old.pdf"),
        ], protectedFolders: ["Archive"])
        let s = PlacementSuggester().suggest(fileName: "Directional derivatives HW.pdf", context: ctx)
        XCTAssertEqual(s.candidates.first?.folder, "Math/Unit 3")
        XCTAssertLessThanOrEqual(s.candidates.count, 3)
        XCTAssertFalse(s.candidates.contains { $0.folder == "Archive" })
        XCTAssertFalse(s.candidates.first!.reasons.isEmpty)
        let none = PlacementSuggester().suggest(fileName: "zzqx.bin", context: ctx)
        XCTAssertTrue(none.abstained)
        XCTAssertNotNil(none.question)
        var rejected = ctx; rejected.rejectedFolders = ["Math/Unit 3": 2]
        XCTAssertNotEqual(PlacementSuggester().suggest(fileName: "Directional derivatives HW.pdf", context: rejected).candidates.first?.folder, "Math/Unit 3",
                          "corrections are learned")
    }

    func testPersonalizedBeatsBaselineOnHeldOutSet() {
        // Small deterministic evaluation: personalized top-3 accuracy must not be worse than the generic baseline.
        let existing: [(String, String)] = [
            ("Bio/Cells", "cell membrane notes.pdf"), ("Bio/Cells", "cell organelles.pdf"), ("Bio/Genetics", "dna replication.pdf"),
            ("Bio/Genetics", "mendel genetics.pdf"), ("Math/Calculus", "derivative rules.pdf"), ("Math/Calculus", "integral practice.pdf"),
            ("History/WW2", "pacific theater.pdf"), ("History/WW2", "european theater.pdf"), ("Inbox", "scan001.pdf"), ("Inbox", "scan002.pdf"),
            ("Inbox", "scan003.pdf"), ("Inbox", "scan004.pdf"),
        ]
        let heldOut = [("cell division.pdf", "Bio/Cells"), ("genetics punnett squares.pdf", "Bio/Genetics"), ("derivative quiz.pdf", "Math/Calculus"),
                       ("integral review.pdf", "Math/Calculus"), ("theater timeline.pdf", "History/WW2"), ("dna transcription.pdf", "Bio/Genetics")]
        let ctx = PlacementSuggester.Context(existing: existing)
        let s = PlacementSuggester()
        let personal = heldOut.filter { f, truth in s.suggest(fileName: f, context: ctx).candidates.prefix(3).contains { $0.folder == truth } }.count
        let base = heldOut.filter { f, truth in s.baseline(fileName: f, context: ctx).contains(truth) }.count
        XCTAssertGreaterThan(personal, base)
        XCTAssertGreaterThanOrEqual(Double(personal) / Double(heldOut.count), 0.85)
    }
}

final class SuggestionTests: XCTestCase {
    func testTodayIsLimitedExplainedAndLocal() throws {
        let t = TestEnv()
        t.calendar.infos = [CalendarInfo(id: "c", title: "School", sourceTitle: "", allowsModifications: true, isSubscribed: false)]
        t.env.settings.set(Settings.selectedCalendars, ["c"])
        let now = t.clock.now()
        t.calendar.items = [CalendarItem(eventIdentifier: "e", externalIdentifier: "e", calendarID: "c", calendarTitle: "School",
                                         title: "Literature review study session", startAt: now + 3_600, endAt: now + 7_200, refreshedAt: now)]
        t.env.calendar.refresh()
        let p = try t.env.projects.create(name: "Literature review")
        var s = t.env.suggestions.today()
        XCTAssertEqual(s.first?.kind, .linkEvent, "similar title → ask before linking")
        let event = t.env.calendar.upcoming().first!
        try t.env.projects.addItem(projectID: p.id, kind: .event, targetID: event.id)
        try t.env.projects.saveCheckpoint(projectID: p.id, note: "Finished the introduction")
        s = t.env.suggestions.today()
        XCTAssertEqual(s.first?.kind, .materialsReady)
        XCTAssertTrue(s.first!.reason.contains("Finished the introduction"))
        XCTAssertLessThanOrEqual(s.count, 3)
    }

    func testAmbiguousEventTitlesAreNotAutoMatched() throws {
        let t = TestEnv()
        let a = try t.env.projects.create(name: "Biology lab")
        let b = try t.env.projects.create(name: "Biology lecture")
        XCTAssertNil(SuggestionEngine.bestProjectMatch(eventTitle: "Biology", projects: [a, b]))
    }

    func testNotificationLimitsQuietHoursAndPresentationMode() {
        let t = TestEnv()
        let policy = t.env.notifications
        XCTAssertFalse(policy.mayNotify(), "notifications are off until enabled")
        t.env.settings.set(Settings.notificationsEnabled, true)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        t.clock.set(cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!)
        XCTAssertTrue(policy.mayNotify(calendar: cal))
        policy.record(kind: "x", projectID: nil); policy.record(kind: "x", projectID: nil)
        XCTAssertFalse(policy.mayNotify(calendar: cal), "max two per day")
        t.clock.set(cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 23))!)
        XCTAssertFalse(policy.mayNotify(calendar: cal), "quiet hours")
        t.clock.set(cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!)
        XCTAssertTrue(policy.mayNotify(calendar: cal))
        t.env.settings.set(Settings.presentationMode, true)
        XCTAssertFalse(policy.mayNotify(calendar: cal))
        t.env.settings.set(Settings.presentationMode, false)
        XCTAssertFalse(policy.mayNotify(projectSnoozedUntil: t.clock.now() + 60, calendar: cal))
    }
}

final class PortabilityTests: XCTestCase {
    func testExportOmitsSecretsAndUninstallPreservesSources() throws {
        let t = TestEnv()
        try t.env.providers.setKey("sk-ant-supersecretkey123", for: .anthropic)
        let f = t.temp.write("Root/a.txt", "source")
        let asset = try t.env.indexing.addReference(f)
        let p = try t.env.projects.create(name: "P")
        try t.env.projects.addItem(projectID: p.id, kind: .file, targetID: asset.id)
        try t.env.memory.add(MemoryRecord(projectID: p.id, kind: .projectFact, statement: "Fact", provenance: .userConfirmed, observedAt: t.clock.now()))
        let dir = try t.env.portability.export()
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(all.contains("manifest.json"))
        for name in all {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("supersecret"))
        }
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("projects.json"), encoding: .utf8).contains("a.txt"))
        let report = try t.env.portability.prepareToUninstall(exportFirst: false, removeProviderKeys: true)
        XCTAssertEqual(report.removedProviderKeys, [.anthropic])
        XCTAssertFalse(t.env.providers.hasKey(.anthropic))
        XCTAssertTrue(t.env.settings.get(Settings.paused))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(t.env.portability.appDataRemovalPreview().contains { $0.path.hasPrefix(t.root.path) }, "removal never touches user folders")
    }
}

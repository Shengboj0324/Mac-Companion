import XCTest
@testable import CompanionCore

final class MemoryTests: XCTestCase {
    func testAddEditConfirmAndExport() throws {
        let t = TestEnv()
        let p = try t.env.projects.create(name: "P")
        let m = try XCTUnwrap(try t.env.memory.add(MemoryRecord(projectID: p.id, kind: .preference, statement: "Prefer concise explanations",
                                                                provenance: .aiInference, observedAt: t.clock.now())))
        XCTAssertEqual(t.env.memory.all(projectID: p.id).count, 1)
        try t.env.memory.edit(m.id, statement: "Prefer concise explanations with examples")
        XCTAssertEqual(t.env.memory.memory(m.id)?.provenance, .userConfirmed)
        let data = try t.env.memory.export()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("with examples"))
    }

    func testConflictsStayVisibleUntilResolved() throws {
        let t = TestEnv()
        let a = try XCTUnwrap(try t.env.memory.add(MemoryRecord(projectID: nil, kind: .projectFact, statement: "The draft is due on Friday",
                                                                provenance: .sourcedObservation, observedAt: t.clock.now())))
        let b = try XCTUnwrap(try t.env.memory.add(MemoryRecord(projectID: nil, kind: .projectFact, statement: "The draft is due on Monday",
                                                                provenance: .aiInference, observedAt: t.clock.now())))
        XCTAssertEqual(Set(t.env.memory.conflicts.map(\.id)), [a.id, b.id], "newest statement does not silently win")
        try t.env.memory.resolveConflict(keep: a.id, supersede: [b.id])
        XCTAssertTrue(t.env.memory.conflicts.isEmpty)
        XCTAssertEqual(t.env.memory.all().map(\.id), [a.id])
    }

    func testForgetLeavesTombstoneAndRemovesFromSearchAndContext() throws {
        let t = TestEnv()
        let p = try t.env.projects.create(name: "P")
        let m = try XCTUnwrap(try t.env.memory.add(MemoryRecord(projectID: p.id, kind: .projectFact, statement: "Evaluation used twelve participants",
                                                                provenance: .sourcedObservation, observedAt: t.clock.now())))
        XCTAssertFalse(t.env.search.search("twelve participants").isEmpty)
        try t.env.memory.forget(m.id)
        XCTAssertTrue(t.env.search.search("twelve participants").isEmpty)
        let again = try t.env.memory.add(MemoryRecord(projectID: p.id, kind: .projectFact, statement: "Evaluation used twelve participants!",
                                                      provenance: .aiInference, observedAt: t.clock.now()))
        XCTAssertNil(again, "tombstone blocks automatic re-creation")
        let items = t.env.retrieval.gather(request: "participants", projectID: p.id)
        XCTAssertFalse(items.contains { $0.text.contains("twelve") }, "forgotten fact excluded from future packets")
        XCTAssertNotNil(try t.env.memory.add(MemoryRecord(projectID: p.id, kind: .projectFact, statement: "Evaluation used twelve participants",
                                                          provenance: .userConfirmed, observedAt: t.clock.now())), "explicit user re-entry allowed")
    }

    func testSessionContextExpires() throws {
        let t = TestEnv()
        try t.env.memory.add(MemoryRecord(projectID: nil, kind: .sessionContext, statement: "Currently viewing chapter 2", provenance: .sourcedObservation,
                                          observedAt: t.clock.now(), expiresAt: t.clock.now() + 60))
        XCTAssertEqual(t.env.memory.all().count, 1)
        t.clock.advance(120)
        XCTAssertEqual(t.env.memory.all().count, 0)
    }
}

final class ContextPacketTests: XCTestCase {
    func testDisclosureDecisions() {
        XCTAssertEqual(DisclosurePolicy(mode: .localOnly, allowedProviders: [.anthropic]).decision(for: .anthropic), .deny)
        XCTAssertEqual(DisclosurePolicy(mode: .askBeforeSending).decision(for: .openai), .ask)
        XCTAssertEqual(DisclosurePolicy(mode: .askBeforeSending, allowedProviders: [.openai]).decision(for: .openai), .allow)
        XCTAssertEqual(DisclosurePolicy(mode: .allowSelected, allowedProviders: [.openai]).decision(for: .deepseek), .deny)
        let combined = DisclosurePolicy(mode: .allowSelected, allowedProviders: [.openai, .anthropic])
            .intersect(DisclosurePolicy(mode: .askBeforeSending, allowedProviders: [.anthropic]))
        XCTAssertEqual(combined.decision(for: .anthropic), .allow)
        XCTAssertEqual(combined.decision(for: .openai), .ask, "project still asks for OpenAI")
        XCTAssertEqual(combined.decision(for: .deepseek), .deny)
        XCTAssertEqual(DisclosurePolicy(mode: .localOnly).intersect(DisclosurePolicy(mode: .allowSelected, allowedProviders: [.openai])).decision(for: .openai), .deny)
    }

    func testPacketSeparatesAllowedAskAndDenied() {
        let allow = PacketItem(id: "1", kind: .excerpt, title: "a", text: "A", source: nil, policy: .init(mode: .allowSelected, allowedProviders: [.anthropic]))
        let ask = PacketItem(id: "2", kind: .excerpt, title: "b", text: "B", source: nil, policy: .init())
        let deny = PacketItem(id: "3", kind: .excerpt, title: "c", text: "C", source: nil, policy: .init(mode: .localOnly))
        let never = PacketItem(id: "4", kind: .memory, title: "d", text: "D", source: nil, policy: .init(mode: .allowSelected, allowedProviders: [.anthropic]), neverSend: true)
        let packet = ContextPacketBuilder().build(request: "q", provider: .anthropic, items: [allow, ask, deny, never])
        XCTAssertEqual(packet.included.map(\.id), ["1"])
        XCTAssertEqual(packet.needsConsent.map(\.id), ["2"])
        XCTAssertEqual(Set(packet.excluded.map(\.id)), ["3", "4"])
        let once = ContextPacketBuilder().build(request: "q", provider: .anthropic, items: [ask], oneTimeAllowed: ["2"])
        XCTAssertEqual(once.included.map(\.id), ["2"])
        XCTAssertTrue(packet.renderedContext.contains("<source id=\"S1\""))
    }

    func testRevalidationBlocksRevokedSourceBeforeTransmission() throws {
        let item = PacketItem(id: "1", kind: .excerpt, title: "doc", text: "x", source: nil, policy: .init(mode: .allowSelected, allowedProviders: [.openai]))
        let packet = ContextPacketBuilder().build(request: "q", provider: .openai, items: [item])
        XCTAssertNoThrow(try ContextPacketBuilder().revalidate(packet, currentPolicy: { $0 }, oneTimeAllowed: []))
        XCTAssertThrowsError(try ContextPacketBuilder().revalidate(packet, currentPolicy: { _ in nil }, oneTimeAllowed: []))
        XCTAssertThrowsError(try ContextPacketBuilder().revalidate(packet, currentPolicy: {
            PacketItem(id: $0.id, kind: $0.kind, title: $0.title, text: $0.text, source: nil, policy: .init(mode: .localOnly)) }, oneTimeAllowed: []))
    }

    func testRetrievalAppliesRootPolicyAndProjectScope() throws {
        let t = TestEnv()
        t.temp.write("Root/Private/diary.txt", "photosynthesis diary entry")
        t.temp.write("Root/Shared/notes.txt", "photosynthesis class notes")
        let privateRoot = try t.env.indexing.addRoot(t.root.appendingPathComponent("Private"), disclosure: .init(mode: .localOnly))
        let sharedRoot = try t.env.indexing.addRoot(t.root.appendingPathComponent("Shared"), disclosure: .init(mode: .allowSelected, allowedProviders: [.anthropic]))
        t.env.indexing.scan(privateRoot); t.env.indexing.scan(sharedRoot); t.env.indexing.processPending()
        let p = try t.env.projects.create(name: "Bio", disclosure: .init(mode: .allowSelected, allowedProviders: [.anthropic]))
        for a in t.env.indexing.assets() { try t.env.projects.addItem(projectID: p.id, kind: .file, targetID: a.id) }
        let packet = t.env.conversations.preview("photosynthesis", options: AskOptions(provider: .anthropic, projectID: p.id))
        XCTAssertTrue(packet.included.contains { $0.text.contains("class notes") })
        XCTAssertFalse(packet.included.contains { $0.text.contains("diary") })
        XCTAssertTrue(packet.excluded.contains { $0.text.contains("diary") })
        let other = t.env.conversations.preview("photosynthesis", options: AskOptions(provider: .openai, projectID: p.id))
        XCTAssertTrue(other.included.filter { $0.kind == .excerpt }.isEmpty, "switching provider is a new disclosure")
    }
}

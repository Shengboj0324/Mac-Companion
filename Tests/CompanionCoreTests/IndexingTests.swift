import XCTest
@testable import CompanionCore

final class IndexingTests: XCTestCase {
    func testScanIndexesTextAndSkipsExcludedContent() throws {
        let t = TestEnv()
        t.temp.write("Root/Course/notes.md", "# Derivatives\nDirectional derivative practice\n# Limits\nEpsilon delta")
        t.temp.write("Root/Course/readme.txt", "Plain text about gradients")
        t.temp.write("Root/node_modules/pkg/index.txt", "should be skipped")
        t.temp.write("Root/.env", "OPENAI_API_KEY=sk-secret")
        t.temp.write("Root/secret.pem", "-----BEGIN")
        t.temp.write("Root/Tool.app/Contents/info.txt", "bundle")
        t.temp.write("Root/.hidden/file.txt", "hidden")
        let root = try t.env.indexing.addRoot(t.root)
        let report = t.env.indexing.scan(root)
        XCTAssertEqual(report.added, 2)
        t.env.indexing.processPending()
        let names = Set(t.env.indexing.assets().map(\.name))
        XCTAssertEqual(names, ["notes.md", "readme.txt"])
        let hits = t.env.search.search("directional")
        XCTAssertEqual(hits.first?.title, "notes.md")
        XCTAssertEqual(hits.first?.heading, "Derivatives")
        XCTAssertTrue(t.env.search.search("sk-secret").isEmpty)
    }

    func testRenameKeepsIdentityWithoutDuplicateCards() throws {
        let t = TestEnv()
        let file = t.temp.write("Root/draft.txt", "unique zebra content")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        let original = try XCTUnwrap(t.env.indexing.asset(atPath: PathGuard.canonical(file).path))
        let project = try t.env.projects.create(name: "Essay")
        try t.env.projects.addItem(projectID: project.id, kind: .file, targetID: original.id)

        let renamed = t.root.appendingPathComponent("final.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        let report = t.env.indexing.scan(root)
        XCTAssertEqual(report.renamed, 1)
        XCTAssertEqual(t.env.indexing.assets().count, 1)
        let after = try XCTUnwrap(t.env.indexing.asset(original.id))
        XCTAssertEqual(after.name, "final.txt")
        XCTAssertEqual(t.env.projects.items(projectID: project.id).count, 1, "no duplicate cards")
        XCTAssertEqual(t.env.search.search("final").first?.itemID, original.id)
    }

    func testModifyReindexesAndDeleteMarksReferencedMissing() throws {
        let t = TestEnv()
        let file = t.temp.write("Root/a.txt", "alpha")
        let other = t.temp.write("Root/b.txt", "bravo")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        let a = try XCTUnwrap(t.env.indexing.asset(atPath: PathGuard.canonical(file).path))
        let p = try t.env.projects.create(name: "P")
        try t.env.projects.addItem(projectID: p.id, kind: .file, targetID: a.id)

        try Data("alpha gamma ray".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(t.env.indexing.scan(root).updated, 1)
        t.env.indexing.processPending()
        XCTAssertEqual(t.env.search.search("gamma").first?.itemID, a.id)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: other)
        t.env.indexing.scan(root)
        XCTAssertEqual(t.env.indexing.asset(a.id)?.availability, .missing, "card stays honest about missing file")
        XCTAssertNil(t.env.indexing.asset(atPath: PathGuard.canonical(other).path), "unreferenced asset is purged")
        XCTAssertTrue(t.env.search.search("gamma").isEmpty)
    }

    func testSymlinksOutsideRootAreNotTraversed() throws {
        let t = TestEnv()
        t.temp.write("Outside/private.txt", "outside secret words")
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("link"),
                                                   withDestinationURL: t.temp.url.appendingPathComponent("Outside"))
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        XCTAssertTrue(t.env.indexing.assets().isEmpty)
        XCTAssertTrue(t.env.search.search("outside").isEmpty)
    }

    func testStabilizationLeavesFreshFilesPending() throws {
        let t = TestEnv(stabilization: 3_600)
        t.temp.write("Root/new.txt", "fresh download")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root)
        XCTAssertEqual(t.env.indexing.processPending(), 0)
        XCTAssertEqual(t.env.indexing.pendingCount, 1)
    }

    func testDocxExtractionReportsOmissions() throws {
        let t = TestEnv()
        try FileManager.default.copyItem(at: t.fixture("sample.docx"), to: t.root.appendingPathComponent("review.docx"))
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        let asset = try XCTUnwrap(t.env.indexing.assets().first)
        XCTAssertEqual(asset.indexStatus, .indexed)
        XCTAssertTrue(asset.indexDetail?.contains("equation") == true)
        XCTAssertTrue(asset.indexDetail?.contains("drawing") == true)
        let hit = try XCTUnwrap(t.env.search.search("grammar").first)
        XCTAssertEqual(hit.heading, "Introduction")
        XCTAssertEqual(t.env.search.search("Deaf readers").first?.heading, "Evaluation")
    }

    func testUnsupportedAndPackageFilesStayVisible() throws {
        let t = TestEnv()
        t.temp.write("Root/slides.key/Index.zip", "x")
        t.temp.write("Root/photo.heic", "binary")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        let assets = Dictionary(uniqueKeysWithValues: t.env.indexing.assets().map { ($0.name, $0) })
        XCTAssertEqual(assets["slides.key"]?.indexStatus, .metadataOnly)
        XCTAssertEqual(assets["photo.heic"]?.indexStatus, .unsupported)
        XCTAssertEqual(t.env.search.search("slides").first?.title, "slides.key", "filename still searchable")
    }

    func testMetadataOnlyRootDoesNotExtract() throws {
        let t = TestEnv()
        t.temp.write("Root/a.txt", "confidential phrase")
        let root = try t.env.indexing.addRoot(t.root, extractContent: false)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        XCTAssertEqual(t.env.indexing.assets().first?.indexStatus, .metadataOnly)
        XCTAssertTrue(t.env.search.search("confidential").isEmpty)
    }

    func testRemovingRootPurgesDerivedData() throws {
        let t = TestEnv()
        t.temp.write("Root/a.txt", "purge me please")
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root); t.env.indexing.processPending()
        XCTAssertFalse(t.env.search.search("purge").isEmpty)
        try t.env.indexing.removeRoot(root.id)
        XCTAssertTrue(t.env.search.search("purge").isEmpty)
        XCTAssertTrue(t.env.indexing.assets().isEmpty)
        XCTAssertEqual(try t.env.db.scalarInt("SELECT COUNT(*) FROM document_segments"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.root.appendingPathComponent("a.txt").path), "source file untouched")
    }

    func testReconcileSinglePathHint() throws {
        let t = TestEnv()
        let root = try t.env.indexing.addRoot(t.root)
        t.env.indexing.scan(root)
        let f = t.temp.write("Root/hint.txt", "hinted content")
        t.env.indexing.reconcile(path: PathGuard.canonical(f).path)
        t.env.indexing.processPending()
        XCTAssertEqual(t.env.search.search("hinted").count, 1)
    }
}

final class SearchIndexTests: XCTestCase {
    func testExtractedTextIsEncryptedAtRestAndIndexIsContentless() throws {
        let t = TestEnv()
        let id = UUID()
        let seg = DocumentSegment(id: UUID(), assetID: id, sourceKind: .localFile, tabID: nil, sourceVersion: nil, heading: nil,
                                  startIndex: nil, endIndex: nil, ordinal: 0, text: "photosynthesis chlorophyll secretphrase")
        try t.env.search.replace(itemID: id, kind: .localFile, title: "bio.txt", segments: [seg])
        XCTAssertEqual(t.env.search.search("chlorophyll").first?.itemID, id)
        let raw = try t.env.db.query("SELECT content FROM document_segments")
        XCTAssertFalse(String(decoding: raw[0].data("content")!, as: UTF8.self).contains("secretphrase"))
        let bodies = try t.env.db.query("SELECT body FROM search_index")
        XCTAssertTrue(bodies.allSatisfy { $0.string("body") == nil }, "contentless index stores no readable text")
    }

    func testQuerySyntaxCannotInjectFTSOperators() throws {
        let t = TestEnv()
        let id = UUID()
        try t.env.search.replace(itemID: id, kind: .localFile, title: "x.txt", segments: [
            DocumentSegment(id: UUID(), assetID: id, sourceKind: .localFile, tabID: nil, sourceVersion: nil, heading: nil, startIndex: nil, endIndex: nil, ordinal: 0, text: "alpha beta")])
        XCTAssertEqual(t.env.search.search("alpha\" OR NOT *").count, 1)
        XCTAssertTrue(t.env.search.search("\"\"").isEmpty)
        XCTAssertEqual(t.env.search.search("alp").count, 1, "prefix search")
    }

    func testFilenameTokenization() {
        XCTAssertTrue(SearchIndex.tokenizeFilename("LitReview_draft-v2.docx").contains("Review"))
    }

    func testSegmentationBoundsLength() {
        let long = String(repeating: "word ", count: 2_000)
        let segs = SearchIndex.segment([ExtractedSection(heading: "H", text: long, locator: nil)], assetID: UUID(), kind: .localFile, version: nil)
        XCTAssertTrue(segs.count > 3)
        XCTAssertTrue(segs.allSatisfy { $0.text.count <= 1_600 })
    }
}

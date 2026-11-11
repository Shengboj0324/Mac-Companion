import XCTest
@testable import CompanionCore

final class GoogleTests: XCTestCase {
    func testPKCEMatchesRFC7636Vector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = PKCE()
        XCTAssertGreaterThanOrEqual(fresh.verifier.count, 43)
        XCTAssertNotEqual(fresh.state, PKCE().state)
    }

    func testAuthorizationURLUsesPKCEAndSelectedScope() {
        let p = PKCE(verifier: "v".padding(toLength: 50, withPad: "v", startingAt: 0), state: "st")
        let url = p.authorizationURL(config: GoogleConfig(clientID: "abc.apps.googleusercontent.com"), redirectURI: "http://127.0.0.1:5555",
                                     scopes: GoogleAccessMode.selectedDocuments.scopes)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "st")
        XCTAssertTrue(q["scope"]!.contains("drive.file"))
        XCTAssertFalse(q["scope"]!.contains("drive.readonly"), "broad access is never requested by default")
    }

    func testConfigDetection() {
        XCTAssertFalse(GoogleConfig(clientID: "").isConfigured)
        XCTAssertFalse(GoogleConfig(clientID: "$(GOOGLE_CLIENT_ID)").isConfigured)
        XCTAssertTrue(GoogleConfig(clientID: "123-abc.apps.googleusercontent.com").isConfigured)
    }

    func testLinkParsingIsLocatorOnly() {
        XCTAssertEqual(GoogleLink.fileID(from: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit?tab=t.0"),
                       "1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789")
        XCTAssertEqual(GoogleLink.fileID(from: "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQrStUvWxYz012"), "1AbCdEfGhIjKlMnOpQrStUvWxYz012")
        XCTAssertNil(GoogleLink.fileID(from: "https://example.com/doc"))
    }

    func testLoopbackParsingValidatesState() {
        XCTAssertEqual(try LoopbackReceiver.parse(request: "GET /?code=abc&state=ok HTTP/1.1\r\n", expectedState: "ok")?.get(), "abc")
        XCTAssertThrowsError(try LoopbackReceiver.parse(request: "GET /?code=abc&state=bad HTTP/1.1\r\n", expectedState: "ok")?.get())
        XCTAssertThrowsError(try LoopbackReceiver.parse(request: "GET /?error=access_denied&state=ok HTTP/1.1\r\n", expectedState: "ok")?.get()) {
            XCTAssertEqual($0 as? CompanionError, .cancelled)
        }
        XCTAssertNil(LoopbackReceiver.parse(request: "GET /favicon.ico HTTP/1.1\r\n", expectedState: "ok"))
    }

    func testLoopbackReceiverEndToEnd() async throws {
        let r = LoopbackReceiver(expectedState: "xyz")
        try await r.start()
        XCTAssertGreaterThan(r.port, 0)
        async let code = r.waitForCode(timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(r.redirectURI)/?code=the-code&state=xyz")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("connected"))
        let value = try await code
        XCTAssertEqual(value, "the-code")
    }

    func testDocsParserReadsAllTabsTablesLinksAndCoverage() throws {
        let t = TestEnv()
        let doc = try JSON.object(Data(contentsOf: t.fixture("google_doc.json")))
        let parsed = GoogleDocParser().parse(doc)
        XCTAssertEqual(parsed.tabs.map(\.id), ["t.0", "t.1", "t.2"], "nested tabs are traversed, not only the first")
        XCTAssertEqual(parsed.coverage.tabsTotal, 3)
        XCTAssertEqual(parsed.coverage.tabsRead, 3)
        XCTAssertEqual(parsed.coverage.tables, 1)
        XCTAssertEqual(parsed.coverage.links, 1)
        XCTAssertTrue(parsed.coverage.omissions.contains("1 image/drawing"))
        XCTAssertTrue(parsed.coverage.omissions.contains("1 equation"))
        XCTAssertFalse(parsed.coverage.isComplete)
        XCTAssertEqual(parsed.revisionID, "rev-1")
        let draft = parsed.tabs[0].paragraphs
        XCTAssertEqual(draft.first?.headingLevel, 1)
        XCTAssertTrue(draft.contains { $0.isListItem && $0.text.contains("(https://example.org/paper)") })
        XCTAssertTrue(draft.contains { $0.inTable && $0.text.contains("Study A | Accuracy 80%") })
        XCTAssertEqual(parsed.text(tabID: "t.0", start: 14, end: 25), "Translation")
        let segments = parsed.segments(assetID: UUID(), version: "rev-1")
        XCTAssertTrue(segments.contains { $0.tabID == "t.1" && $0.text.contains("Nested tab") })
        XCTAssertTrue(segments.contains { $0.heading?.contains("Introduction") == true })
    }

    // MARK: Account + cloud flows against a scripted Google

    private func connectedEnv() throws -> (TestEnv, ConnectorAccount) {
        let t = TestEnv()
        let claims = PKCE.base64URL(try JSON.data(["sub": "1234567890", "email": "student@example.edu"]))
        let tokens = GoogleAuthService.TokenResponse(accessToken: "ya29.test", expiresIn: 3600, refreshToken: "1//refresh",
                                                     idToken: "h.\(claims).s", scope: GoogleAccessMode.selectedDocuments.scopes.joined(separator: " "))
        let account = try t.env.googleAuth.storeAccount(tokens: tokens, requestedScopes: GoogleAccessMode.selectedDocuments.scopes)
        return (t, account)
    }

    func testAccountBoundByStableSubjectAndSingleAccountAlpha() throws {
        let (t, account) = try connectedEnv()
        XCTAssertEqual(account.subject, "1234567890")
        XCTAssertEqual(account.displayIdentity, "student@example.edu")
        XCTAssertEqual(t.secrets.string(account.keychainRef), "1//refresh")
        XCTAssertEqual(try t.env.db.scalarInt("SELECT COUNT(*) FROM connector_accounts WHERE scopes LIKE '%1//refresh%'"), 0, "no raw credentials in DB")
        let other = PKCE.base64URL(try JSON.data(["sub": "999", "email": "other@example.com"]))
        XCTAssertThrowsError(try t.env.googleAuth.storeAccount(tokens: .init(accessToken: "a", expiresIn: 10, refreshToken: "r", idToken: "h.\(other).s", scope: nil),
                                                               requestedScopes: []))
    }

    func testAddDocumentIndexesContentAndRespectsAccessLoss() async throws {
        let (t, account) = try connectedEnv()
        let doc = try Data(contentsOf: t.fixture("google_doc.json"))
        var accessRevoked = false
        t.transport.handler = { req in
            let url = req.url!.absoluteString
            XCTAssertTrue(GoogleConfig.allowedHosts.contains(req.url!.host!))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.test")
            if accessRevoked { return .init(status: 404, lines: ["{}"]) }
            if url.contains("docs.googleapis.com") { return .init(status: 200, lines: [String(decoding: doc, as: UTF8.self)]) }
            if url.contains("/drive/v3/files/doc123doc123doc123doc123") {
                return .init(status: 200, lines: [#"{"id":"doc123doc123doc123doc123","name":"Literature Review Draft","mimeType":"application/vnd.google-apps.document","version":"7","webViewLink":"https://docs.google.com/document/d/doc123/edit","modifiedTime":"2026-11-10T10:00:00.000Z"}"#])
            }
            return .init(status: 404, lines: ["{}"])
        }
        let asset = try await t.env.cloudDocs.addDocument(accountID: account.id, locator: "https://docs.google.com/document/d/doc123doc123doc123doc123/edit")
        XCTAssertEqual(asset.freshness, .current)
        XCTAssertEqual(asset.coverage?.tabsRead, 3)
        XCTAssertEqual(t.env.search.search("synthesis matrix").first?.itemID, asset.id)

        accessRevoked = true
        let f = try await t.env.cloudDocs.refreshContent(asset.id)
        XCTAssertEqual(f, .unavailable)
        XCTAssertTrue(t.env.search.search("synthesis matrix").isEmpty, "permission loss excludes content immediately")
        XCTAssertNil(t.env.retrieval.describe(itemID: asset.id, kind: .googleDoc, projectID: nil))
    }

    func testUnauthorizedLinkRoutesToSelection() async throws {
        let (t, account) = try connectedEnv()
        t.transport.handler = { _ in .init(status: 404, lines: ["{}"]) }
        await XCTAssertThrowsAsync(try await t.env.cloudDocs.addDocument(accountID: account.id, locator: "1AbCdEfGhIjKlMnOpQrStUvWxYz012")) {
            guard case .permissionDenied(let m)? = $0 as? CompanionError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("Choose from Google Drive"))
        }
    }

    func testDisconnectPurgesTokensAndCaches() async throws {
        let (t, account) = try connectedEnv()
        try t.env.db.execute("INSERT INTO cloud_assets(id, account_id, provider_file_id, name, mime_type) VALUES(?,?,?,?,?)",
                             [UUID(), account.id, "f1", "Doc", "application/vnd.google-apps.document"])
        var revoked = false
        t.transport.handler = { req in if req.url!.absoluteString.contains("revoke") { revoked = true }; return .init(status: 200, lines: ["{}"]) }
        try await t.env.googleAuth.disconnect(account.id, revoke: true, purge: { try t.env.cloudDocs.purge(accountID: $0) })
        XCTAssertTrue(revoked)
        XCTAssertNil(t.secrets.string(account.keychainRef))
        XCTAssertTrue(t.env.cloudDocs.assets().isEmpty)
        XCTAssertTrue(t.env.googleAuth.accounts().isEmpty)
    }

    func testDocsEditRejectsStaleRevisionAndNeverBlindlyRetriesWrites() async throws {
        let (t, account) = try connectedEnv()
        let docJSON = String(decoding: try Data(contentsOf: t.fixture("google_doc.json")), as: UTF8.self)
        var batchCalls = 0
        t.transport.handler = { req in
            if req.httpMethod == "POST", req.url!.absoluteString.contains(":batchUpdate") { batchCalls += 1; return .init(status: 503, lines: ["{}"]) }
            return .init(status: 200, lines: [docJSON])
        }
        let performer = GoogleDocsPerformer(db: t.env.db, clock: t.clock, drive: GoogleDrive(api: t.env.googleAPI), docs: t.env.cloudDocs, cipher: t.env.cipher)
        let edit = DocsTextEdit(tabID: "t.0", startIndex: 14, endIndex: 25, before: "Translation", after: "Interpretation")
        let stale = PlannedOperation(kind: .docsEdit, docs: DocsOperationSpec(accountID: account.id, accountIdentity: account.displayIdentity, documentID: "doc123",
                                                                              documentTitle: "Lit", requiredRevisionID: "rev-OLD", edits: [edit]))
        await XCTAssertThrowsAsync(try await performer.validate(stale)) { guard case .staleSource? = $0 as? CompanionError else { return XCTFail("\($0)") } }

        let mismatch = PlannedOperation(kind: .docsEdit, docs: DocsOperationSpec(accountID: account.id, accountIdentity: "", documentID: "doc123", documentTitle: "Lit",
            requiredRevisionID: "rev-1", edits: [DocsTextEdit(tabID: "t.0", startIndex: 14, endIndex: 25, before: "Somethingelse", after: "x")]))
        await XCTAssertThrowsAsync(try await performer.validate(mismatch))

        let good = PlannedOperation(kind: .docsEdit, docs: DocsOperationSpec(accountID: account.id, accountIdentity: "", documentID: "doc123", documentTitle: "Lit",
                                                                             requiredRevisionID: "rev-1", edits: [edit]))
        try await performer.validate(good)
        await XCTAssertThrowsAsync(try await performer.perform(good, actionID: UUID(), index: 0)) {
            guard case .outcomeUnknown? = $0 as? CompanionError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(batchCalls, 1, "a write that may have succeeded is never blindly retried")
        let reconciled = await performer.reconcile(good, actionID: UUID(), index: 0)
        XCTAssertEqual(reconciled?.status, .failed, "same revision after timeout → edit not applied")
    }

    func testFormEncodingAndJWT() {
        XCTAssertEqual(GoogleAuthService.formEncode(["b": "x y", "a": "1/2"]), "a=1%2F2&b=x%20y")
        let payload = PKCE.base64URL(Data(#"{"sub":"42"}"#.utf8))
        XCTAssertEqual(GoogleAuthService.decodeJWTClaims("a.\(payload).c")?["sub"] as? String, "42")
    }
}

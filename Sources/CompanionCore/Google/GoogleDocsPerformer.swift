import Foundation

/// Executes approved Google Docs operations: create, server-side copy, and
/// bounded text edits with `requiredRevisionId`. Stale revisions are rejected,
/// never silently rebased; timeouts are reconciled, never blindly retried (spec §6).
public final class GoogleDocsPerformer: ExternalOperationPerformer, @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let drive: GoogleDrive
    private let docs: CloudDocumentService
    private let cipher: ContentCipher

    public init(db: SQLiteDatabase, clock: Clock, drive: GoogleDrive, docs: CloudDocumentService, cipher: ContentCipher) {
        self.db = db; self.clock = clock; self.drive = drive; self.docs = docs; self.cipher = cipher
    }

    public func handles(_ kind: OperationKind) -> Bool { kind.isCloud }

    static func marker(_ actionID: UUID, _ index: Int) -> String { "\(actionID.uuidString)-\(index)" }

    public func validate(_ op: PlannedOperation) async throws {
        guard let spec = op.docs else { throw CompanionError.invalidArgument("Missing document details") }
        switch op.kind {
        case .docsEdit:
            guard let docID = spec.documentID, let rev = spec.requiredRevisionID else { throw CompanionError.invalidArgument("Missing revision") }
            guard !spec.edits.isEmpty, spec.edits.count <= 20 else { throw CompanionError.policyViolation("1–20 passages per approval") }
            let parsed = GoogleDocParser().parse(try await drive.document(docID, accountID: spec.accountID))
            guard parsed.revisionID == rev else {
                throw CompanionError.staleSource("“\(spec.documentTitle)” was edited after review — regenerate the comparison")
            }
            for e in spec.edits {
                guard e.endIndex > e.startIndex, let current = parsed.text(tabID: e.tabID, start: e.startIndex, end: e.endIndex) else {
                    throw CompanionError.unsupported("Edit spans an unsupported structure; edit manually in Docs")
                }
                guard current == e.before else { throw CompanionError.staleSource("Reviewed text no longer matches the document") }
                if let p = parsed.paragraph(containing: e.startIndex, tabID: e.tabID), p.inTable {
                    throw CompanionError.unsupported("Table edits stay read-only until tested")
                }
            }
        case .docsCopy, .docsCreate:
            if let folder = spec.destinationFolderID {
                // Block when destination visibility cannot be assessed (spec §15).
                guard let visibility = await drive.visibility(folderID: folder, accountID: spec.accountID) else {
                    throw CompanionError.policyViolation("Destination folder visibility could not be checked; choose My Drive instead")
                }
                guard visibility == spec.destinationVisibility else {
                    throw CompanionError.staleSource("Destination visibility changed (now \(visibility))")
                }
            }
        default: throw CompanionError.unsupported(op.kind.verb)
        }
    }

    public func perform(_ op: PlannedOperation, actionID: UUID, index: Int) async throws -> OperationResult {
        guard let spec = op.docs else { throw CompanionError.invalidArgument("Missing document details") }
        let marker = Self.marker(actionID, index)
        switch op.kind {
        case .docsCreate:
            let file = try await drive.createDocument(name: spec.documentTitle, parent: spec.destinationFolderID, marker: marker, accountID: spec.accountID)
            let readBack = try await drive.file(file.id, accountID: spec.accountID)
            let ok = readBack.name == spec.documentTitle && readBack.mimeType == "application/vnd.google-apps.document"
            _ = try? await docs.addDocument(accountID: spec.accountID, locator: file.id)
            return OperationResult(index: index, status: .succeeded, verified: ok, detail: readBack.webViewLink, externalID: file.id)

        case .docsCopy:
            guard let src = spec.documentID else { throw CompanionError.invalidArgument("Missing source document") }
            let name = "Copy of \(spec.documentTitle)"
            let file = try await drive.copy(fileID: src, name: name, parent: spec.destinationFolderID, marker: marker, accountID: spec.accountID)
            let readBack = try await drive.file(file.id, accountID: spec.accountID)
            _ = try? await docs.addDocument(accountID: spec.accountID, locator: file.id)
            return OperationResult(index: index, status: .succeeded, verified: readBack.id == file.id && readBack.name == name,
                                   detail: "Copied; comments, history and sharing may not be preserved", externalID: file.id)

        case .docsEdit:
            guard let docID = spec.documentID, let rev = spec.requiredRevisionID else { throw CompanionError.invalidArgument("Missing revision") }
            // Recovery record of the verified affected content (not a full revision-history restore).
            let before = try JSON.encode(spec.edits)
            try db.execute("""
                INSERT INTO recovery_records(id, action_id, operation_index, kind, cloud_payload, coverage, created_at)
                VALUES(?,?,?,?,?,?,?)
                """, [UUID(), actionID, index, "docsEdit", try cipher.sealString(before), "affected passages only", clock.now()])
            // Apply from the end of the document backwards so earlier indexes stay valid.
            var requests: [[String: Any]] = []
            for e in spec.edits.sorted(by: { $0.startIndex > $1.startIndex }) {
                var range: [String: Any] = ["startIndex": e.startIndex, "endIndex": e.endIndex]
                var location: [String: Any] = ["index": e.startIndex]
                if let t = e.tabID { range["tabId"] = t; location["tabId"] = t }
                requests.append(["deleteContentRange": ["range": range]])
                if !e.after.isEmpty { requests.append(["insertText": ["location": location, "text": e.after]]) }
            }
            do {
                _ = try await drive.batchUpdate(docID, requests: requests, requiredRevisionID: rev, accountID: spec.accountID)
            } catch GoogleAPIClient.APIError.preconditionFailed(let m) {
                throw CompanionError.staleSource(m)
            }
            // Read back and verify each passage now reads as approved.
            let parsed = GoogleDocParser().parse(try await drive.document(docID, accountID: spec.accountID))
            var verified = true
            var shift = 0
            for e in spec.edits.sorted(by: { $0.startIndex < $1.startIndex }) {
                let start = e.startIndex + shift
                let end = start + e.after.utf16.count
                if parsed.text(tabID: e.tabID, start: start, end: end) != e.after { verified = false }
                shift += e.after.utf16.count - (e.endIndex - e.startIndex)
            }
            if let asset = docs.asset(accountID: spec.accountID, fileID: docID) { _ = try? await docs.refreshContent(asset.id, force: true) }
            return OperationResult(index: index, status: .succeeded, verified: verified,
                                   detail: verified ? "New revision \(parsed.revisionID ?? "?")" : "Read-back did not match the approved text",
                                   externalID: parsed.revisionID)
        default:
            throw CompanionError.unsupported(op.kind.verb)
        }
    }

    public func reconcile(_ op: PlannedOperation, actionID: UUID, index: Int) async -> OperationResult? {
        guard let spec = op.docs else { return nil }
        switch op.kind {
        case .docsCreate, .docsCopy:
            guard let found = try? await drive.findByMarker(Self.marker(actionID, index), accountID: spec.accountID) else {
                return OperationResult(index: index, status: .outcomeUnknown, verified: false, detail: "Could not reach Google to reconcile")
            }
            if let f = found.first {
                return OperationResult(index: index, status: .succeeded, verified: true, detail: "Found after reconciliation", externalID: f.id)
            }
            return OperationResult(index: index, status: .failed, verified: false, detail: "Not created")
        case .docsEdit:
            guard let docID = spec.documentID, let doc = try? await drive.document(docID, accountID: spec.accountID) else {
                return OperationResult(index: index, status: .outcomeUnknown, verified: false, detail: "Could not reach Google to reconcile")
            }
            let parsed = GoogleDocParser().parse(doc)
            if parsed.revisionID == spec.requiredRevisionID {
                return OperationResult(index: index, status: .failed, verified: false, detail: "Edit was not applied")
            }
            return OperationResult(index: index, status: .outcomeUnknown, verified: false,
                                   detail: "Document changed; review it in Google Docs before retrying")
        default: return nil
        }
    }
}

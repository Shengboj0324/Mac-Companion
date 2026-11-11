import Foundation

public enum SearchKind: String, Codable, CaseIterable, Sendable {
    case localFile, googleDoc, memory, checkpoint, event
    public var label: String {
        switch self {
        case .localFile: return "Local file"
        case .googleDoc: return "Google Doc"
        case .memory: return "Memory"
        case .checkpoint: return "Checkpoint"
        case .event: return "Event"
        }
    }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { "\(itemID.uuidString)#\(segmentID?.uuidString ?? "-")" }
    public let itemID: UUID
    public let kind: SearchKind
    public let segmentID: UUID?
    public let title: String
    public let snippet: String
    public let heading: String?
    public let score: Double
}

public struct SearchFilter: Sendable {
    public var kinds: Set<SearchKind>?
    public var itemIDs: Set<UUID>?
    public var limit: Int
    public init(kinds: Set<SearchKind>? = nil, itemIDs: Set<UUID>? = nil, limit: Int = 50) {
        self.kinds = kinds; self.itemIDs = itemIDs; self.limit = limit
    }
}

/// Local full-text search. Uses a contentless FTS5 index (tokens only) and
/// encrypted segment bodies; snippets are produced after decryption.
public final class SearchIndex: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let cipher: ContentCipher

    public init(db: SQLiteDatabase, cipher: ContentCipher) { self.db = db; self.cipher = cipher }

    /// Replaces all indexed content for `itemID`.
    public func replace(itemID: UUID, kind: SearchKind, title: String, segments: [DocumentSegment]) throws {
        try db.transaction {
            try remove(itemID: itemID)
            // Title-only row so filename search works even without content.
            try insertRow(itemID: itemID, kind: kind, segmentID: nil, title: title, body: Self.tokenizeFilename(title))
            for segment in segments {
                let sealed = try cipher.sealString(segment.text)
                try db.execute("""
                    INSERT INTO document_segments(id, asset_id, source_kind, tab_id, source_version, heading,
                        start_index, end_index, ordinal, content, encrypted)
                    VALUES(?,?,?,?,?,?,?,?,?,?,1)
                    """, [segment.id, itemID, segment.sourceKind.rawValue, segment.tabID, segment.sourceVersion,
                          segment.heading, segment.startIndex, segment.endIndex, segment.ordinal, sealed])
                try insertRow(itemID: itemID, kind: kind, segmentID: segment.id, title: title,
                              body: [segment.heading, segment.text].compactMap { $0 }.joined(separator: "\n"))
            }
        }
    }

    public func remove(itemID: UUID) throws {
        try db.transaction {
            let rows = try db.query("SELECT rowid FROM search_docs WHERE item_id = ?", [itemID])
            for r in rows { if let rid = r.int("rowid") { try db.execute("DELETE FROM search_index WHERE rowid = ?", [rid]) } }
            try db.execute("DELETE FROM search_docs WHERE item_id = ?", [itemID])
            try db.execute("DELETE FROM document_segments WHERE asset_id = ?", [itemID])
        }
    }

    public func kind(of itemID: UUID) -> SearchKind? {
        (try? db.queryOne("SELECT kind FROM search_docs WHERE item_id = ? LIMIT 1", [itemID]))?.string("kind").flatMap(SearchKind.init(rawValue:))
    }

    public func segments(for itemID: UUID) -> [DocumentSegment] {
        let rows = (try? db.query("SELECT * FROM document_segments WHERE asset_id = ? ORDER BY ordinal", [itemID])) ?? []
        return rows.compactMap(decodeSegment)
    }

    public func segment(_ id: UUID) -> DocumentSegment? {
        guard let r = try? db.queryOne("SELECT * FROM document_segments WHERE id = ?", [id]) else { return nil }
        return decodeSegment(r)
    }

    public func search(_ query: String, filter: SearchFilter = .init()) -> [SearchHit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
        var sql = """
            SELECT d.item_id, d.kind, d.segment_id, d.title, bm25(search_index, 4.0, 1.0) AS score
            FROM search_index JOIN search_docs d ON d.rowid = search_index.rowid
            WHERE search_index MATCH ?
            """
        var params: [SQLConvertible] = [match]
        if let kinds = filter.kinds, !kinds.isEmpty {
            sql += " AND d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            params += kinds.map { $0.rawValue }
        }
        if let ids = filter.itemIDs {
            if ids.isEmpty { return [] }
            sql += " AND d.item_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            params += ids.map { $0.uuidString }
        }
        sql += " ORDER BY score LIMIT ?"
        params.append(filter.limit * 4)
        guard let rows = try? db.query(sql, params) else { return [] }

        var seen = Set<UUID>()
        var hits: [SearchHit] = []
        for r in rows {
            guard let itemID = r.uuid("item_id"), let kind = SearchKind(rawValue: r.string("kind") ?? "") else { continue }
            // One best hit per item keeps results readable.
            if seen.contains(itemID) { continue }
            seen.insert(itemID)
            let segmentID = r.uuid("segment_id")
            let seg = segmentID.flatMap(segment)
            let snippet = seg.map { Self.snippet(from: $0.text, terms: terms) } ?? ""
            hits.append(SearchHit(itemID: itemID, kind: kind, segmentID: segmentID, title: r.string("title") ?? "",
                                  snippet: snippet, heading: seg?.heading, score: -(r.double("score") ?? 0)))
            if hits.count >= filter.limit { break }
        }
        return hits
    }

    // MARK: Helpers

    private func insertRow(itemID: UUID, kind: SearchKind, segmentID: UUID?, title: String, body: String) throws {
        try db.execute("INSERT INTO search_docs(item_id, kind, segment_id, title) VALUES(?,?,?,?)",
                       [itemID, kind.rawValue, segmentID, title])
        let rowid = try db.scalarInt("SELECT last_insert_rowid()")
        try db.execute("INSERT INTO search_index(rowid, title, body) VALUES(?,?,?)", [rowid, title, body])
    }

    private func decodeSegment(_ r: SQLRow) -> DocumentSegment? {
        guard let id = r.uuid("id"), let asset = r.uuid("asset_id"), let blob = r.data("content") else { return nil }
        let text = r.bool("encrypted") ? ((try? cipher.openString(blob)) ?? "") : String(decoding: blob, as: UTF8.self)
        return DocumentSegment(id: id, assetID: asset, sourceKind: SourceRef.Kind(rawValue: r.string("source_kind") ?? "") ?? .localFile,
                               tabID: r.string("tab_id"), sourceVersion: r.string("source_version"), heading: r.string("heading"),
                               startIndex: r.int("start_index"), endIndex: r.int("end_index"), ordinal: r.int("ordinal") ?? 0, text: text)
    }

    /// Extracts safe search terms; FTS syntax characters are stripped so user
    /// input can never change query semantics.
    static func terms(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["and", "or", "not", "near"].contains($0) }
            .prefix(12)
            .map { String($0) }
    }

    static func tokenizeFilename(_ name: String) -> String {
        // "LitReview_draft-v2.docx" → "LitReview draft v2 docx Lit Review"
        var words = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let camel = words.flatMap { w -> [String] in
            var parts: [String] = []; var cur = ""
            for ch in w {
                if ch.isUppercase, let last = cur.last, last.isLowercase { parts.append(cur); cur = "" }
                cur.append(ch)
            }
            parts.append(cur)
            return parts.count > 1 ? parts : []
        }
        words += camel
        return words.joined(separator: " ")
    }

    static func snippet(from text: String, terms: [String], radius: Int = 110) -> String {
        let lower = text.lowercased()
        var best: String.Index?
        for t in terms { if let r = lower.range(of: t) { best = r.lowerBound; break } }
        let collapsed: (Substring) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let hit = best else { return collapsed(text.prefix(radius * 2)) }
        let start = lower.index(hit, offsetBy: -radius, limitedBy: lower.startIndex) ?? lower.startIndex
        let end = lower.index(hit, offsetBy: radius, limitedBy: lower.endIndex) ?? lower.endIndex
        let s = String(text[start..<end])
        return (start > text.startIndex ? "…" : "") + collapsed(Substring(s)) + (end < text.endIndex ? "…" : "")
    }

    /// Splits long sections into bounded segments for retrieval.
    public static func segment(_ sections: [ExtractedSection], assetID: UUID, kind: SourceRef.Kind,
                               version: String?, tabID: String? = nil, maxChars: Int = 1_600) -> [DocumentSegment] {
        var out: [DocumentSegment] = []
        var ordinal = 0
        for section in sections {
            let paragraphs = section.text.components(separatedBy: "\n")
            var buffer = ""
            func emit() {
                let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                out.append(DocumentSegment(id: UUID(), assetID: assetID, sourceKind: kind, tabID: tabID, sourceVersion: version,
                                           heading: section.heading, startIndex: nil, endIndex: nil, ordinal: ordinal, text: t))
                ordinal += 1
                buffer = ""
            }
            for p in paragraphs {
                if buffer.count + p.count > maxChars, !buffer.isEmpty { emit() }
                if p.count > maxChars {
                    var rest = Substring(p)
                    while !rest.isEmpty { buffer = String(rest.prefix(maxChars)); rest = rest.dropFirst(maxChars); emit() }
                } else {
                    buffer += (buffer.isEmpty ? "" : "\n") + p
                }
            }
            emit()
            if section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let h = section.heading {
                out.append(DocumentSegment(id: UUID(), assetID: assetID, sourceKind: kind, tabID: tabID, sourceVersion: version,
                                           heading: h, startIndex: nil, endIndex: nil, ordinal: ordinal, text: h))
                ordinal += 1
            }
        }
        return out
    }
}

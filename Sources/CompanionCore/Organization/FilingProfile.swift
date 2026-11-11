import Foundation

/// Learns the user's actual organization within approved roots and keeps it as
/// an inspectable, editable rule list. Inferred rules are candidates until the
/// user confirms them; silence is never acceptance (spec §7).
public final class FilingProfileService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let indexing: IndexingService

    public init(db: SQLiteDatabase, clock: Clock, indexing: IndexingService) {
        self.db = db; self.clock = clock; self.indexing = indexing
    }

    // MARK: Rules

    public func rules(includeInactive: Bool = false) -> [OrganizationRule] {
        let sql = includeInactive ? "SELECT * FROM organization_rules ORDER BY field, created_at"
                                  : "SELECT * FROM organization_rules WHERE status IN ('candidate','explicit') ORDER BY field, created_at"
        return ((try? db.query(sql)) ?? []).compactMap(Self.decode)
    }

    @discardableResult
    public func addExplicit(field: ProfileField, scope: String, statement: String, evidence: [String] = []) throws -> OrganizationRule {
        try insert(OrganizationRule(id: UUID(), scope: scope, field: field, statement: statement, status: .explicit, evidence: evidence,
                                    observationCount: evidence.count, exceptions: [], confirmedAt: clock.now(), supersededBy: nil, createdAt: clock.now()))
    }

    public func confirm(_ id: UUID) throws {
        try db.execute("UPDATE organization_rules SET status='explicit', confirmed_at=? WHERE id=?", [clock.now(), id])
    }

    public func reject(_ id: UUID) throws { try db.execute("UPDATE organization_rules SET status='rejected' WHERE id=?", [id]) }

    public func edit(_ id: UUID, statement: String) throws {
        // Editing creates a new explicit version and keeps the prior one for reference.
        guard let old = rules(includeInactive: true).first(where: { $0.id == id }) else { return }
        let new = try addExplicit(field: old.field, scope: old.scope, statement: statement, evidence: old.evidence)
        try db.execute("UPDATE organization_rules SET status='superseded', superseded_by=? WHERE id=?", [new.id, id])
    }

    public func addException(_ id: UUID, _ exception: String) throws {
        guard var r = rules(includeInactive: true).first(where: { $0.id == id }) else { return }
        r.exceptions.append(exception)
        try db.execute("UPDATE organization_rules SET exceptions=? WHERE id=?", [try JSON.encode(r.exceptions), id])
    }

    /// Reset the profile for one scope (or everything).
    public func reset(scope: String? = nil) throws {
        if let scope { try db.execute("DELETE FROM organization_rules WHERE scope=?", [scope]) }
        else { try db.execute("DELETE FROM organization_rules") }
    }

    public func export() throws -> Data { try JSON.prettyEncoder.encode(rules(includeInactive: true)) }

    // MARK: Learning

    /// Analyzes folder hierarchy, naming patterns and placement within roots.
    /// Produces candidate rules with evidence; never touches Finder.
    @discardableResult
    public func learn() throws -> [OrganizationRule] {
        var created: [OrganizationRule] = []
        let existing = rules(includeInactive: true)
        func known(_ statement: String) -> Bool { existing.contains { $0.statement == statement } }

        for root in indexing.roots() where root.enabled {
            let assets = indexing.assets(rootID: root.id).filter { !$0.isManagedCopy }
            guard assets.count >= 3 else { continue }
            let rootName = root.url.lastPathComponent
            let analysis = FilingAnalyzer.analyze(paths: assets.map { String($0.path.dropFirst(root.path.count + 1)) })
            for finding in analysis where !known(finding.statement) {
                let r = OrganizationRule(id: UUID(), scope: rootName, field: finding.field, statement: finding.statement, status: .candidate,
                                         evidence: Array(finding.evidence.prefix(5)), observationCount: finding.count, exceptions: [],
                                         confirmedAt: nil, supersededBy: nil, createdAt: clock.now())
                try insert(r)
                created.append(r)
            }
            if root.isProtected {
                let s = "Never suggest changes inside \(rootName)"
                if !known(s) { created.append(try addExplicit(field: .protection, scope: rootName, statement: s)) }
            }
        }
        return created
    }

    // MARK: Feedback

    public enum FeedbackOutcome: String, Sendable { case accepted, notNow, wrongLocation, chosenOther }

    /// Dismissal means "not now" unless the user says the location is wrong.
    public func recordFeedback(filePath: String, suggested: String, outcome: FeedbackOutcome, chosen: String? = nil) {
        try? db.execute("INSERT INTO placement_feedback(id, file_path, suggested, outcome, chosen, created_at) VALUES(?,?,?,?,?,?)",
                        [UUID(), filePath, suggested, outcome.rawValue, chosen, clock.now()])
    }

    public func feedback() -> [(suggested: String, outcome: String, chosen: String?)] {
        ((try? db.query("SELECT suggested, outcome, chosen FROM placement_feedback ORDER BY created_at DESC LIMIT 500")) ?? [])
            .map { ($0.string("suggested") ?? "", $0.string("outcome") ?? "", $0.string("chosen")) }
    }

    // MARK: Internals

    @discardableResult
    private func insert(_ r: OrganizationRule) throws -> OrganizationRule {
        try db.execute("""
            INSERT INTO organization_rules(id, scope, field, statement, status, evidence, observation_count, exceptions, confirmed_at, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [r.id, r.scope, r.field.rawValue, r.statement, r.status.rawValue, try JSON.encode(r.evidence), r.observationCount,
                  try JSON.encode(r.exceptions), r.confirmedAt, r.createdAt])
        return r
    }

    static func decode(_ r: SQLRow) -> OrganizationRule? {
        guard let id = r.uuid("id"), let field = ProfileField(rawValue: r.string("field") ?? ""),
              let status = RuleStatus(rawValue: r.string("status") ?? ""), let created = r.date("created_at") else { return nil }
        return OrganizationRule(id: id, scope: r.string("scope") ?? "", field: field, statement: r.string("statement") ?? "", status: status,
                                evidence: r.json("evidence", as: [String].self) ?? [], observationCount: r.int("observation_count") ?? 0,
                                exceptions: r.json("exceptions", as: [String].self) ?? [], confirmedAt: r.date("confirmed_at"),
                                supersededBy: r.uuid("superseded_by"), createdAt: created)
    }
}

/// Pure analysis of relative paths → candidate findings. Deterministic and testable.
public enum FilingAnalyzer {
    public struct Finding: Equatable, Sendable {
        public let field: ProfileField
        public let statement: String
        public let evidence: [String]
        public let count: Int
    }

    static let datePrefix = try! NSRegularExpression(pattern: #"^(19|20)\d{2}[-_.]?\d{2}([-_.]?\d{2})?[ _-]"#)
    static let draftSuffix = try! NSRegularExpression(pattern: #"(?i)[ _-](draft|v\d+|final|rev\d*)$"#)
    static let yearFolder = try! NSRegularExpression(pattern: #"^(19|20)\d{2}$"#)

    public static func analyze(paths: [String]) -> [Finding] {
        var findings: [Finding] = []
        let total = paths.count
        guard total > 0 else { return [] }
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let stems = names.map { ($0 as NSString).deletingPathExtension }

        func matches(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

        // Naming: date prefix.
        let dated = zip(paths, stems).filter { matches(datePrefix, $0.1) }.map(\.0)
        if Double(dated.count) / Double(total) >= 0.3 && dated.count >= 3 {
            findings.append(Finding(field: .naming, statement: "Filenames often start with a date (e.g. 2026-11-10 …)", evidence: dated, count: dated.count))
        }
        // Naming: draft/version suffix.
        let drafts = zip(paths, stems).filter { matches(draftSuffix, $0.1) }.map(\.0)
        if drafts.count >= 3 {
            findings.append(Finding(field: .naming, statement: "Drafts are marked with a suffix such as “draft”, “v2” or “final”", evidence: drafts, count: drafts.count))
        }
        // Naming: separator style.
        let underscore = stems.filter { $0.contains("_") && !$0.contains(" ") }.count
        let spaced = stems.filter { $0.contains(" ") }.count
        let hyphen = stems.filter { $0.contains("-") && !$0.contains(" ") && !$0.contains("_") }.count
        let style = [("underscores", underscore), ("spaces", spaced), ("hyphens", hyphen)].max { $0.1 < $1.1 }!
        if style.1 >= 5 && Double(style.1) / Double(total) >= 0.5 {
            findings.append(Finding(field: .naming, statement: "Words in filenames are usually separated by \(style.0)",
                                    evidence: zip(paths, stems).filter { style.0 == "spaces" ? $0.1.contains(" ") : $0.1.contains(style.0 == "underscores" ? "_" : "-") }.map(\.0),
                                    count: style.1))
        }
        // Hierarchy: years at the top level, or years inside a top-level folder.
        let comps = paths.map { $0.split(separator: "/").map(String.init) }
        let topLevel = Set(comps.filter { $0.count > 1 }.map { $0[0] })
        if topLevel.count >= 2, Double(topLevel.filter { matches(yearFolder, $0) }.count) / Double(topLevel.count) >= 0.6 {
            findings.append(Finding(field: .hierarchy, statement: "Top-level folders are years", evidence: topLevel.sorted(), count: topLevel.count))
        }
        for top in topLevel.sorted() {
            let children = Set(comps.filter { $0.count > 2 && $0[0] == top }.map { $0[1] })
            let years = children.filter { matches(yearFolder, $0) }
            if children.count >= 2, Double(years.count) / Double(children.count) >= 0.6 {
                findings.append(Finding(field: .hierarchy, statement: "Within “\(top)”, work is organized by year",
                                        evidence: years.sorted().map { "\(top)/\($0)" }, count: years.count))
            }
        }
        // Placement: subfolders that consistently hold one kind of file (e.g. Readings → PDFs, Drafts → docx).
        var byFolder: [String: [String]] = [:]
        for c in comps where c.count >= 2 { byFolder[c[c.count - 2], default: []].append(c.joined(separator: "/")) }
        for (folder, files) in byFolder.sorted(by: { $0.key < $1.key }) where files.count >= 3 {
            let exts = files.map { ($0 as NSString).pathExtension.lowercased() }
            let top = Dictionary(grouping: exts, by: { $0 }).max { $0.value.count < $1.value.count }!
            if !top.key.isEmpty, Double(top.value.count) / Double(files.count) >= 0.8 {
                let siblingsWithSameName = byFolder.keys.filter { $0.lowercased() == folder.lowercased() }.count
                findings.append(Finding(field: .placement,
                                        statement: "“\(folder)” folders hold .\(top.key) files\(siblingsWithSameName > 1 ? " across projects" : "")",
                                        evidence: files, count: files.count))
            }
        }
        // Placement: separate drafts and readings/sources folders.
        let folderNames = Set(byFolder.keys.map { $0.lowercased() })
        let draftLike = folderNames.filter { ["drafts", "draft", "writing"].contains($0) }
        let sourceLike = folderNames.filter { ["readings", "sources", "papers", "references", "literature"].contains($0) }
        if !draftLike.isEmpty && !sourceLike.isEmpty {
            findings.append(Finding(field: .placement, statement: "Drafts and source readings are kept in separate subfolders",
                                    evidence: Array((draftLike.union(sourceLike)).sorted()), count: draftLike.count + sourceLike.count))
        }
        return findings
    }
}

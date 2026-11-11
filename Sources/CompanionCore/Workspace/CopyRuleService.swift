import Foundation

/// Optional copy-only rules: off by default, copy newly added matching files once
/// into one approved destination under a file-count and storage quota. Never
/// renames, moves, overwrites or deletes originals (spec §5).
public final class CopyRuleService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let copies: WorkingCopyService
    private let activity: ActivityLog

    public init(db: SQLiteDatabase, clock: Clock, copies: WorkingCopyService, activity: ActivityLog) {
        self.db = db; self.clock = clock; self.copies = copies; self.activity = activity
    }

    /// Rules are always created disabled; enabling is a separate explicit step.
    @discardableResult
    public func create(rootID: UUID, pattern: String, destination: URL, maxFiles: Int = 25,
                       maxBytes: Int = 200 << 20, expiresAt: Date? = nil) throws -> CopyRule {
        guard maxFiles > 0, maxFiles <= 500, maxBytes > 0 else { throw CompanionError.invalidArgument("Quota out of range") }
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { throw CompanionError.invalidArgument("Empty pattern") }
        let rule = CopyRule(id: UUID(), rootID: rootID, pattern: pattern, destination: PathGuard.canonical(destination).path,
                            maxFiles: maxFiles, maxBytes: maxBytes, copiedFiles: 0, copiedBytes: 0, enabled: false,
                            expiresAt: expiresAt, createdAt: clock.now())
        try db.execute("""
            INSERT INTO copy_rules(id, root_id, pattern, destination, max_files, max_bytes, enabled, expires_at, created_at)
            VALUES(?,?,?,?,?,?,0,?,?)
            """, [rule.id, rootID, pattern, rule.destination, maxFiles, maxBytes, expiresAt, rule.createdAt])
        return rule
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        try db.execute("UPDATE copy_rules SET enabled=? WHERE id=?", [enabled, id])
        activity.record(kind: "copyRule", summary: enabled ? "Enabled a copy-only rule" : "Disabled a copy-only rule (pending copies cancelled)")
    }

    public func delete(_ id: UUID) throws { try db.execute("DELETE FROM copy_rules WHERE id=?", [id]) }

    public func all() -> [CopyRule] {
        ((try? db.query("SELECT * FROM copy_rules ORDER BY created_at")) ?? []).compactMap(Self.decode)
    }

    /// Applies enabled rules to newly added assets. Each file is copied at most once per rule.
    @discardableResult
    public func apply(newAssets: [FileAsset]) -> [WorkingCopy] {
        var made: [WorkingCopy] = []
        let now = clock.now()
        for var rule in all() where rule.enabled {
            if let exp = rule.expiresAt, exp < now { try? setEnabled(rule.id, false); continue }
            for asset in newAssets where asset.rootID == rule.rootID && !asset.isManagedCopy {
                guard Self.matches(asset.name, pattern: rule.pattern) else { continue }
                let already = ((try? db.scalarInt("SELECT COUNT(*) FROM working_copies WHERE rule_id=? AND source_path=?",
                                                  [rule.id, asset.path])) ?? 0) > 0
                if already { continue }
                guard rule.copiedFiles + 1 <= rule.maxFiles, rule.copiedBytes + asset.size <= rule.maxBytes else {
                    activity.record(kind: "copyRule", initiator: "copy rule", summary: "Copy rule quota reached; no further copies")
                    break
                }
                // Re-check the rule is still enabled immediately before each copy.
                guard (try? db.queryOne("SELECT enabled FROM copy_rules WHERE id=?", [rule.id]))?.bool("enabled") == true else { break }
                if let wc = try? copies.createCopy(of: asset.url, into: URL(fileURLWithPath: rule.destination), projectID: nil, ruleID: rule.id) {
                    rule.copiedFiles += 1; rule.copiedBytes += asset.size
                    try? db.execute("UPDATE copy_rules SET copied_files=?, copied_bytes=? WHERE id=?", [rule.copiedFiles, rule.copiedBytes, rule.id])
                    made.append(wc)
                }
            }
        }
        return made
    }

    /// Glob-style match supporting `*` and `?`, case-insensitive.
    public static func matches(_ name: String, pattern: String) -> Bool {
        fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }

    static func decode(_ r: SQLRow) -> CopyRule? {
        guard let id = r.uuid("id"), let root = r.uuid("root_id"), let created = r.date("created_at") else { return nil }
        return CopyRule(id: id, rootID: root, pattern: r.string("pattern") ?? "", destination: r.string("destination") ?? "",
                        maxFiles: r.int("max_files") ?? 0, maxBytes: r.int("max_bytes") ?? 0, copiedFiles: r.int("copied_files") ?? 0,
                        copiedBytes: r.int("copied_bytes") ?? 0, enabled: r.bool("enabled"), expiresAt: r.date("expires_at"),
                        createdAt: created)
    }
}

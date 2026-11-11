import Foundation

public struct ApprovalGrant: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let planHash: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let policyVersion: Int
}

/// Issues single-use, short-lived authorizations bound to an exact plan hash.
/// Only the trusted review UI calls `issue`; it is not reachable from any model
/// tool, chat text or document content (spec §15).
public final class ApprovalAuthority: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore
    private let lock = NSLock()

    public init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore) {
        self.db = db; self.clock = clock; self.settings = settings
    }

    public var policyVersion: Int { settings.get(Settings.policyVersion) }

    /// Any policy change (pause, revoked source, settings) invalidates outstanding grants.
    public func bumpPolicyVersion() {
        settings.set(Settings.policyVersion, policyVersion + 1)
    }

    /// Called from the review sheet when the user presses the Apply button.
    public func issue(for plan: ActionPlan, userConfirmedAt: Date) -> ApprovalGrant {
        lock.lock(); defer { lock.unlock() }
        let ttl = settings.get(Settings.approvalTTLSeconds)
        let grant = ApprovalGrant(id: UUID(), planHash: plan.hash, issuedAt: userConfirmedAt,
                                  expiresAt: userConfirmedAt.addingTimeInterval(ttl), policyVersion: policyVersion)
        try? db.execute("INSERT INTO approval_grants(id, plan_hash, issued_at, expires_at, used, policy_version) VALUES(?,?,?,?,0,?)",
                        [grant.id, grant.planHash, grant.issuedAt, grant.expiresAt, grant.policyVersion])
        return grant
    }

    /// Validates and consumes a grant atomically. Throws if forged, reused,
    /// expired, bound to a different plan, or issued under an older policy.
    public func consume(_ grant: ApprovalGrant, for plan: ActionPlan) throws {
        lock.lock(); defer { lock.unlock() }
        guard let row = try db.queryOne("SELECT * FROM approval_grants WHERE id=?", [grant.id]) else {
            throw CompanionError.approvalInvalid("Unknown approval")
        }
        guard row.string("plan_hash") == grant.planHash, grant.planHash == plan.hash else {
            throw CompanionError.approvalInvalid("The plan changed after it was approved")
        }
        guard !row.bool("used") else { throw CompanionError.approvalInvalid("Approval was already used") }
        guard let expires = row.date("expires_at"), clock.now() <= expires else {
            throw CompanionError.approvalInvalid("Approval expired — review the plan again")
        }
        guard row.int("policy_version") == policyVersion else {
            throw CompanionError.approvalInvalid("Settings or permissions changed since approval")
        }
        try db.execute("UPDATE approval_grants SET used=1 WHERE id=?", [grant.id])
    }

    public func pruneExpired() {
        try? db.execute("DELETE FROM approval_grants WHERE expires_at < ?", [clock.now().addingTimeInterval(-86_400)])
    }
}

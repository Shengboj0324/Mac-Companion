import Foundation

/// Backend-specific executor for non-local operations (Google Docs, calendar).
/// Each backend implements its own validation, read-back and reconciliation;
/// local operation IDs do not manufacture server-side idempotency (spec §13).
public protocol ExternalOperationPerformer: AnyObject, Sendable {
    func handles(_ kind: OperationKind) -> Bool
    /// Re-check preconditions immediately before execution (revision, conflicts, visibility).
    func validate(_ op: PlannedOperation) async throws
    /// Perform once and read back. Throw `.outcomeUnknown` on ambiguous timeouts — never blindly retry.
    func perform(_ op: PlannedOperation, actionID: UUID, index: Int) async throws -> OperationResult
    /// After a crash/timeout: determine what actually happened from external state.
    func reconcile(_ op: PlannedOperation, actionID: UUID, index: Int) async -> OperationResult?
}

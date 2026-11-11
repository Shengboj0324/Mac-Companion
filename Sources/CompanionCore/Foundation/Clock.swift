import Foundation

/// Injectable time source so policy expiry, freshness and budgets are testable.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Manually advanced clock for tests and deterministic replays.
public final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}

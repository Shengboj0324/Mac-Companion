import Foundation

public struct PriceRate: Codable, Hashable, Sendable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double
}

/// Price table is configuration with a recorded version/date. Provider invoices
/// remain authoritative; these are estimates (spec §14).
public struct PriceTable: Codable, Hashable, Sendable {
    public var version: String
    public var rates: [String: PriceRate]
    /// Conservative fallback for unknown models so reservations never under-estimate badly.
    public var fallback: PriceRate

    public static let `default` = PriceTable(
        version: "2026-11-03 (editable estimate)",
        rates: [
            "anthropic/claude-opus-5-5": .init(inputPerMillion: 4, outputPerMillion: 20),
            "anthropic/claude-sonnet-5-5": .init(inputPerMillion: 2, outputPerMillion: 10),
            "anthropic/claude-haiku-5-5": .init(inputPerMillion: 0.10, outputPerMillion: 0.50),
            "anthropic/claude-fable-5-2": .init(inputPerMillion: 8, outputPerMillion: 40),
            "openai/gpt-5.1": .init(inputPerMillion: 1.25, outputPerMillion: 10),
            "deepseek/deepseek-chat": .init(inputPerMillion: 0.27, outputPerMillion: 1.10),
            "deepseek/deepseek-reasoner": .init(inputPerMillion: 0.55, outputPerMillion: 2.19),
        ],
        fallback: .init(inputPerMillion: 10, outputPerMillion: 50))

    public func rate(_ provider: ProviderID, _ model: String) -> (PriceRate, known: Bool) {
        if let r = rates["\(provider.rawValue)/\(model)"] { return (r, true) }
        return (fallback, false)
    }

    public func cost(_ provider: ProviderID, _ model: String, input: Int, output: Int) -> (Double, known: Bool) {
        let (r, known) = rate(provider, model)
        return (Double(input) / 1_000_000 * r.inputPerMillion + Double(output) / 1_000_000 * r.outputPerMillion, known)
    }
}

public struct BudgetStatus: Sendable, Equatable {
    public let limit: Double
    public let spent: Double
    public let reserved: Double
    public let warnFraction: Double
    public var remaining: Double { max(0, limit - spent - reserved) }
    public var fraction: Double { limit > 0 ? (spent + reserved) / limit : 1 }
    public var isWarning: Bool { fraction >= warnFraction }
    public var isExhausted: Bool { spent + reserved >= limit }
}

public final class BudgetService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let settings: SettingsStore
    public var prices: PriceTable
    private let lock = NSLock()

    public init(db: SQLiteDatabase, clock: Clock, settings: SettingsStore, prices: PriceTable = .default) {
        self.db = db; self.clock = clock; self.settings = settings; self.prices = prices
    }

    private var monthStart: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: cal.dateComponents([.year, .month], from: clock.now())) ?? clock.now()
    }

    public func status() -> BudgetStatus {
        let spent = (try? db.queryOne("SELECT COALESCE(SUM(estimated_cost),0) AS s FROM usage_entries WHERE created_at >= ?", [monthStart]))?.double("s") ?? 0
        // Reservations older than an hour are stale (crashed request) and released.
        try? db.execute("DELETE FROM budget_reservations WHERE created_at < ?", [clock.now().addingTimeInterval(-3_600)])
        let reserved = (try? db.queryOne("SELECT COALESCE(SUM(amount),0) AS s FROM budget_reservations"))?.double("s") ?? 0
        return BudgetStatus(limit: settings.get(Settings.monthlyBudgetUSD), spent: spent, reserved: reserved,
                            warnFraction: settings.get(Settings.budgetWarnFraction))
    }

    /// Reserves the estimated maximum cost before a request; refuses at the limit.
    public func reserve(provider: ProviderID, model: String, estimatedInput: Int, maxOutput: Int) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let (amount, _) = prices.cost(provider, model, input: estimatedInput, output: maxOutput)
        let s = status()
        guard s.spent + s.reserved + amount <= s.limit else {
            throw CompanionError.budgetExceeded(String(format: "This request could cost up to $%.2f; $%.2f of $%.2f remains this month.",
                                                       amount, s.remaining, s.limit))
        }
        let id = UUID()
        try db.execute("INSERT INTO budget_reservations(id, amount, created_at) VALUES(?,?,?)", [id, amount, clock.now()])
        return id
    }

    /// Records actual usage and releases the reservation. Missing usage → estimate flagged.
    @discardableResult
    public func settle(reservation: UUID, provider: ProviderID, model: String, requestID: String?,
                       inputTokens: Int?, outputTokens: Int?, estimatedInput: Int) -> UsageEntry {
        lock.lock(); defer { lock.unlock() }
        let isEstimate = inputTokens == nil || outputTokens == nil
        let input = inputTokens ?? estimatedInput
        let output = outputTokens ?? 0
        let (cost, known) = prices.cost(provider, model, input: input, output: output)
        let entry = UsageEntry(id: UUID(), provider: provider, model: model, requestID: requestID, inputTokens: input,
                               outputTokens: output, priceVersion: prices.version, estimatedCost: cost,
                               isEstimate: isEstimate || !known, createdAt: clock.now())
        try? db.execute("""
            INSERT INTO usage_entries(id, provider, model, request_id, input_tokens, output_tokens, price_version, estimated_cost, is_estimate, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [entry.id, provider.rawValue, model, requestID, input, output, entry.priceVersion, cost, entry.isEstimate, entry.createdAt])
        try? db.execute("DELETE FROM budget_reservations WHERE id=?", [reservation])
        return entry
    }

    public func release(_ reservation: UUID) { try? db.execute("DELETE FROM budget_reservations WHERE id=?", [reservation]) }

    public func usage(limit: Int = 200) -> [UsageEntry] {
        ((try? db.query("SELECT * FROM usage_entries ORDER BY created_at DESC LIMIT ?", [limit])) ?? []).compactMap { r in
            guard let id = r.uuid("id"), let p = ProviderID(rawValue: r.string("provider") ?? ""), let d = r.date("created_at") else { return nil }
            return UsageEntry(id: id, provider: p, model: r.string("model") ?? "", requestID: r.string("request_id"),
                              inputTokens: r.int("input_tokens") ?? 0, outputTokens: r.int("output_tokens") ?? 0,
                              priceVersion: r.string("price_version") ?? "", estimatedCost: r.double("estimated_cost") ?? 0,
                              isEstimate: r.bool("is_estimate"), createdAt: d)
        }
    }
}

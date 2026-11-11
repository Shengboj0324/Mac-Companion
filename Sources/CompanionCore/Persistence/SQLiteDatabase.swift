import Foundation
import SQLite3

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLConvertible {
    var sqlValue: SQLValue { get }
}

extension String: SQLConvertible { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLConvertible { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLConvertible { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLConvertible { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLConvertible { public var sqlValue: SQLValue { .blob(self) } }
extension UUID: SQLConvertible { public var sqlValue: SQLValue { .text(uuidString) } }
extension Date: SQLConvertible { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension SQLValue: SQLConvertible { public var sqlValue: SQLValue { self } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLRow: Sendable {
    public let columns: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { columns[name] ?? .null }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }
    public func int(_ name: String) -> Int? {
        switch self[name] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        default: return nil
        }
    }
    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
    public func data(_ name: String) -> Data? {
        if case .blob(let d) = self[name] { return d }
        if case .text(let s) = self[name] { return Data(s.utf8) }
        return nil
    }
    public func uuid(_ name: String) -> UUID? { string(name).flatMap(UUID.init(uuidString:)) }
    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }
    public func json<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let s = string(name) else { return nil }
        return try? JSON.decode(type, from: s)
    }
}

/// Thread-safe SQLite connection with a single serialized write path.
/// All access goes through a recursive lock so `transaction` bodies may call
/// `execute`/`query` re-entrantly.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String
    private var transactionDepth = 0

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw CompanionError.database(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { sqlite3_close_v2(handle) }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        sqlite3_close_v2(handle)
        handle = nil
    }

    // MARK: Execution

    public func execute(_ sql: String, _ params: [SQLConvertible] = []) throws {
        lock.lock(); defer { lock.unlock() }
        if params.isEmpty, !sql.contains("?") {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? lastError
                sqlite3_free(err)
                throw CompanionError.database(message)
            }
            return
        }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw CompanionError.database(lastError) }
    }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLConvertible] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw CompanionError.database(lastError) }
            var columns: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: columns[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: columns[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: columns[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    if let ptr = sqlite3_column_blob(stmt, i), count > 0 {
                        columns[name] = .blob(Data(bytes: ptr, count: count))
                    } else { columns[name] = .blob(Data()) }
                default: columns[name] = .null
                }
            }
            rows.append(SQLRow(columns: columns))
        }
        return rows
    }

    public func queryOne(_ sql: String, _ params: [SQLConvertible] = []) throws -> SQLRow? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLConvertible] = []) throws -> Int {
        guard let row = try queryOne(sql, params), let first = row.columns.values.first else { return 0 }
        switch first {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return 0
        }
    }

    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(sqlite3_changes(handle))
    }

    /// Runs `body` atomically. Nested calls use savepoints.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let savepoint = "sp\(transactionDepth)"
        try execute(transactionDepth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            try execute(transactionDepth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 { try? execute("ROLLBACK") }
            else { try? execute("ROLLBACK TO \(savepoint)"); try? execute("RELEASE \(savepoint)") }
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }

    /// Online backup to another file (used before migrations and for exports).
    public func backup(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        var dest: OpaquePointer?
        guard sqlite3_open(destination.path, &dest) == SQLITE_OK else {
            sqlite3_close(dest)
            throw CompanionError.database("Cannot open backup destination")
        }
        defer { sqlite3_close(dest) }
        guard let backup = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw CompanionError.database("Backup init failed")
        }
        sqlite3_backup_step(backup, -1)
        guard sqlite3_backup_finish(backup) == SQLITE_OK else {
            throw CompanionError.database("Backup failed")
        }
    }

    // MARK: Private

    private var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ params: [SQLConvertible]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CompanionError.database("\(lastError) in: \(sql.prefix(120))")
        }
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            switch param.sqlValue {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, i, buf.baseAddress, Int32(v.count), Self.transient)
                }
            }
        }
        return stmt
    }
}

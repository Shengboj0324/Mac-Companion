import Foundation
import Security

/// Credential storage abstraction. Production uses the macOS Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func set(_ secret: Data, for account: String) throws
    func get(_ account: String) throws -> Data?
    func delete(_ account: String) throws
}

public extension SecretStore {
    func setString(_ s: String, for account: String) throws { try set(Data(s.utf8), for: account) }
    func string(_ account: String) -> String? {
        (try? get(account)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }
}

public final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.companion.mac") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func set(_ secret: Data, for account: String) throws {
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: secret]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = secret
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CompanionError.keychain("status \(status)") }
    }

    public func get(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CompanionError.keychain("status \(status)") }
        return out as? Data
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionError.keychain("status \(status)")
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func set(_ secret: Data, for account: String) throws { lock.lock(); items[account] = secret; lock.unlock() }
    public func get(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func delete(_ account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    public var allAccounts: [String] { lock.lock(); defer { lock.unlock() }; return Array(items.keys) }
}

public enum SecretAccounts {
    public static func providerKey(_ p: ProviderID) -> String { "provider.\(p.rawValue).apiKey" }
    public static func googleRefresh(_ accountID: UUID) -> String { "google.\(accountID.uuidString).refresh" }
    public static let contentKey = "storage.contentKey"
}

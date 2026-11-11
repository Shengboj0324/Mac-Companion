import Foundation
import CryptoKit

/// AES-GCM encryption for cached cloud excerpts and recovery payloads. The key
/// lives in the Keychain; plain SQLite is not encrypted merely because it is local.
public final class ContentCipher: @unchecked Sendable {
    private let key: SymmetricKey

    public init(secrets: SecretStore) throws {
        if let existing = try secrets.get(SecretAccounts.contentKey), existing.count == 32 {
            key = SymmetricKey(data: existing)
        } else {
            let fresh = SymmetricKey(size: .bits256)
            try secrets.set(fresh.withUnsafeBytes { Data($0) }, for: SecretAccounts.contentKey)
            key = fresh
        }
    }

    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CompanionError.database("Encryption failed")
        }
        return combined
    }

    public func open(_ ciphertext: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }

    public func sealString(_ s: String) throws -> Data { try seal(Data(s.utf8)) }
    public func openString(_ d: Data) throws -> String { String(decoding: try open(d), as: UTF8.self) }
}

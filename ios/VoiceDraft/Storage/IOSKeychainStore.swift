import Foundation
import Security
import VoiceDraftCore

/// Where provider keys and sync secrets live. The app uses the Keychain; tests and previews use memory.
protocol CredentialStore: AnyObject {
    func read(_ account: String) throws -> String
    func contains(_ account: String) throws -> Bool
    /// An empty value deletes the item.
    func write(_ value: String, account: String) throws
}

enum CredentialAccount {
    static let syncToken = "sync-token"
    static let syncPassphrase = "sync-passphrase"
    /// Provider keys are stored under the profile ID, like on the Mac, so sync snapshots map one to one.
    static func profile(_ id: UUID) -> String { id.uuidString }
}

/// Generic-password Keychain items, readable only while this device is unlocked and never migrated.
final class IOSKeychainStore: CredentialStore {
    static let service = "com.voicedraft.ios.credentials"

    func contains(_ account: String) throws -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service, kSecAttrAccount as String: account,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw VoiceDraftError.message("Could not check the saved API key (\(status)).")
        }
        return true
    }

    func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VoiceDraftError.message("Keychain access failed (\(status)).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw VoiceDraftError.message("Could not remove a Keychain item (\(status)).")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VoiceDraftError.message("Could not save to Keychain (\(status)).") }
    }
}

/// Process-local credentials for tests and SwiftUI previews.
final class InMemoryCredentialStore: CredentialStore {
    private(set) var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func read(_ account: String) throws -> String { values[account] ?? "" }
    func contains(_ account: String) throws -> Bool { values[account] != nil }
    func write(_ value: String, account: String) throws { values[account] = value.isEmpty ? nil : value }
}

import Foundation
import Security
import VoiceDraftCore

enum KeychainStore {
    static let service = "com.voicedraft.mac.credentials"
    static func contains(_ account: String) throws -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw VoiceDraftError.message("Could not check the saved API key (\(status)).")
        }
        return true
    }

    static func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VoiceDraftError.message("Keychain access failed (\(status)).")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw VoiceDraftError.message("Could not remove a Keychain item (\(status)).")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query.merging(attributes) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VoiceDraftError.message("Could not save to Keychain (\(status)).") }
    }
}

final class LocalStore {
    let directory: URL
    init() throws {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDraft", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    func read<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let url = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let url = directory.appendingPathComponent(name + ".json")
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension LocalStore {
    /// Monthly model usage logs (`usage-YYYY-MM.jsonl`); see UsageLog.
    var usageDirectory: URL { directory.appendingPathComponent("Usage", isDirectory: true) }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent(id.uuidString + ".wav") }
    func saveAudio(_ data: Data) throws -> UUID {
        _ = try WaveAudio.decode(data)
        let id = UUID(), url = audioURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }
    func deleteAudio(_ id: UUID) throws {
        let url = audioURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

extension LocalStore {
    func removeOrphanedAudio(referenced: Set<UUID>) throws {
        let audioDirectory = directory.appendingPathComponent("Audio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: audioDirectory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "wav", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

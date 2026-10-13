import Foundation
import CryptoKit
import CommonCrypto

public struct SyncSnapshot: Codable, Equatable {
    public var settings: SharedSettings
    public var credentials: [String: String]
    public init(settings: SharedSettings, credentials: [String: String]) {
        self.settings = settings; self.credentials = credentials
    }
    public func validate() throws {
        try settings.validate()
        guard Set(credentials.keys).isSubset(of: Set(settings.profiles.map { $0.id.uuidString })),
              credentials.values.allSatisfy({ $0.utf8.count <= 64_000 }) else {
            throw VoiceDraftError.message("Invalid credential set in synchronized configuration.")
        }
    }
}

public struct EncryptedEnvelope: Codable, Equatable {
    public var version: Int
    public var algorithm: String
    public var iterations: Int
    public var salt: String
    public var ciphertext: String
}

public enum SyncCrypto {
    private static let aad = Data("VoiceDraft.sync.v1".utf8)
    private static let rounds = 600_000
    private static func key(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard passphrase.count >= 12, passphrase.utf8.count <= 1024 else {
            throw VoiceDraftError.message("Use a sync passphrase of at least 12 characters (up to 1024 bytes).")
        }
        var output = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.utf8)
        let status = password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    p.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw VoiceDraftError.message("Could not derive the encryption key.") }
        return SymmetricKey(data: output)
    }

    public static func encrypt(_ snapshot: SyncSnapshot, passphrase: String) throws -> EncryptedEnvelope {
        try snapshot.validate()
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VoiceDraftError.message("Could not generate encryption randomness.") }
        let secret = try key(passphrase: passphrase, salt: salt, iterations: rounds)
        let plaintext = try JSONEncoder().encode(snapshot)
        guard plaintext.count <= 700_000 else { throw VoiceDraftError.message("The configuration is too large to sync. Reduce vocabulary or advanced parameter data before syncing.") }
        let sealed = try AES.GCM.seal(plaintext, using: secret, authenticating: aad)
        return EncryptedEnvelope(version: 1, algorithm: "PBKDF2-SHA256+AES-256-GCM", iterations: rounds,
                                 salt: salt.base64EncodedString(), ciphertext: sealed.combined!.base64EncodedString())
    }

    public static func decrypt(_ envelope: EncryptedEnvelope, passphrase: String) throws -> SyncSnapshot {
        guard envelope.version == 1, envelope.algorithm == "PBKDF2-SHA256+AES-256-GCM",
              envelope.iterations == rounds, let salt = Data(base64Encoded: envelope.salt), salt.count == 16,
              let cipher = Data(base64Encoded: envelope.ciphertext), cipher.count >= 28, cipher.count <= 1_000_000 else {
            throw VoiceDraftError.message("Unsupported or damaged sync envelope.")
        }
        let secret = try key(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        let data: Data
        do { data = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: secret, authenticating: aad) }
        catch { throw VoiceDraftError.message("Cannot decrypt. Check the sync passphrase; local settings were preserved.") }
        let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }
}

public struct SyncRecord: Codable {
    public var revision: Int
    public var payload: EncryptedEnvelope?
}

public final class SyncClient {
    private let base: URL
    private let token: String
    private let transport = HTTPTransport()
    public init(baseURL: String, token: String) throws {
        base = try Endpoint.validate(baseURL)
        guard token.count >= 32, !token.contains(where: \.isWhitespace) else {
            throw VoiceDraftError.message("Use the server's sync access token (at least 32 characters).")
        }
        self.token = token
    }
    private func request(_ method: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("v1/sync"), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func decode(_ data: Data, response: HTTPURLResponse) throws -> SyncRecord {
        if response.statusCode == 409 { throw VoiceDraftError.message("Sync conflict: another device saved changes. Download the server version before uploading; local edits are still here.") }
        if response.statusCode == 401 { throw VoiceDraftError.message("Sync access token was rejected.") }
        guard response.statusCode == 200 else { throw VoiceDraftError.message("Sync failed (HTTP \(response.statusCode)).") }
        let record = try JSONDecoder().decode(SyncRecord.self, from: data)
        guard record.revision >= 0, (record.revision == 0) == (record.payload == nil) else {
            throw VoiceDraftError.message("Invalid sync revision.")
        }
        return record
    }
    public func fetch() async throws -> SyncRecord {
        let (data, response) = try await transport.send(request("GET"))
        return try decode(data, response: response)
    }
    public func upload(_ envelope: EncryptedEnvelope, revision: Int) async throws -> SyncRecord {
        var request = request("PUT")
        request.httpBody = try JSONEncoder().encode(SyncRecord(revision: revision, payload: envelope))
        let (data, response) = try await transport.send(request)
        return try decode(data, response: response)
    }
}

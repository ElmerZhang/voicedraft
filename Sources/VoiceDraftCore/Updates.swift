import Foundation
import CryptoKit

public struct UpdateRelease: Codable, Equatable {
    public var version: String
    public var build: Int
    public var architecture: String
    public var minimumSystemVersion: String
    public var url: String
    public var sha256: String
    public var size: Int
    public var notes: String
    public init(version: String, build: Int, architecture: String, minimumSystemVersion: String, url: String, sha256: String, size: Int, notes: String) {
        self.version = version; self.build = build; self.architecture = architecture; self.minimumSystemVersion = minimumSystemVersion
        self.url = url; self.sha256 = sha256; self.size = size; self.notes = notes
    }
}

public enum UpdateVerifier {
    public struct Envelope: Codable { public let payload: String; public let signature: String }
    public static func verify(_ data: Data, publicKey: String, architecture: String, systemVersion: String) throws -> UpdateRelease {
        guard data.count <= 100_000, let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)), keyData.count == 32 else { throw FeatureError("Enter a valid Ed25519 update public key.") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature),
              try Curve25519.Signing.PublicKey(rawRepresentation: keyData).isValidSignature(signature, for: payload) else { throw FeatureError("The update manifest signature is invalid.") }
        let release = try JSONDecoder().decode(UpdateRelease.self, from: payload)
        let url = try Endpoint.validate(release.url)
        guard url.scheme == "https", release.build > 0, release.size > 0, release.size <= 200_000_000,
              release.version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil,
              release.minimumSystemVersion.range(of: #"^[0-9]+(?:\.[0-9]+){0,2}$"#, options: .regularExpression) != nil,
              release.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              release.notes.utf8.count <= 20_000 else { throw FeatureError("Invalid update metadata.") }
        guard [architecture, "universal"].contains(release.architecture) else { throw FeatureError("This update is for another Mac architecture.") }
        guard systemVersion.compare(release.minimumSystemVersion, options: .numeric) != .orderedAscending else { throw FeatureError("This update requires a newer macOS version.") }
        return release
    }
    public static func verifyPackage(_ data: Data, release: UpdateRelease) throws {
        guard data.count == release.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == release.sha256 else { throw FeatureError("The update package checksum or size is incorrect.") }
        try UpdateArchive.validate(data)
    }
}

public enum UpdateArchive {
    /// Validate the central directory before extraction. Our app packages contain no symlinks.
    public static func validate(_ data: Data) throws {
        let b = [UInt8](data)
        func n(_ i: Int, _ length: Int) -> Int { (0..<length).reduce(0) { $0 | Int(b[i + $1]) << ($1 * 8) } }
        guard b.count >= 22 else { throw FeatureError("Invalid update ZIP.") }
        guard let end = stride(from: b.count - 22, through: max(0, b.count - 65557), by: -1).first(where: { n($0, 4) == 0x06054b50 && $0 + 22 + n($0 + 20, 2) == b.count }),
              n(end + 4, 2) == 0, n(end + 6, 2) == 0, n(end + 8, 2) == n(end + 10, 2),
              n(end + 10, 2) > 0, n(end + 10, 2) <= 20_000 else { throw FeatureError("Unsupported update ZIP format.") }
        var offset = n(end + 16, 4), total = 0, paths = Set<String>()
        guard offset < end, offset + n(end + 12, 4) == end else { throw FeatureError("Invalid ZIP directory.") }
        for _ in 0..<n(end + 10, 2) {
            guard offset + 46 <= end, n(offset, 4) == 0x02014b50 else { throw FeatureError("Invalid ZIP entry.") }
            let nameSize = n(offset + 28, 2), extra = n(offset + 30, 2), comment = n(offset + 32, 2)
            guard offset + 46 + nameSize + extra + comment <= end,
                  let path = String(bytes: b[(offset + 46)..<(offset + 46 + nameSize)], encoding: .utf8) else { throw FeatureError("Invalid ZIP filename.") }
            let mode = n(offset + 38, 4) >> 16, fileType = mode & 0xf000
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("VoiceDraft.app/"), !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !components.contains(".."), !components.contains("."), !components.dropLast().contains(""),
                  paths.insert(path.lowercased()).inserted, [0, 0x8000, 0x4000].contains(fileType),
                  n(offset + 8, 2) & 1 == 0, [0, 8].contains(n(offset + 10, 2)) else { throw FeatureError("Unsafe update archive entry.") }
            let local = n(offset + 42, 4)
            guard local + 30 <= end, n(local, 4) == 0x04034b50 else { throw FeatureError("Invalid ZIP local header.") }
            let localNameSize = n(local + 26, 2), localExtraSize = n(local + 28, 2)
            guard local + 30 + localNameSize + localExtraSize <= end,
                  Data(b[(local + 30)..<(local + 30 + localNameSize)]) == Data(path.utf8) else { throw FeatureError("ZIP filenames disagree.") }
            total += n(offset + 24, 4)
            guard total <= 500_000_000 else { throw FeatureError("Expanded update is too large.") }
            offset += 46 + nameSize + extra + comment
        }
        guard offset == end, paths.contains("voicedraft.app/contents/info.plist"), paths.contains("voicedraft.app/contents/macos/voicedraft") else { throw FeatureError("The ZIP does not contain VoiceDraft.app.") }
    }
}

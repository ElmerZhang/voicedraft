import XCTest
import CryptoKit
@testable import VoiceDraftCore

final class UpdateTests: XCTestCase {
    func testSignedUpdateRejectsTamperingWrongArchitectureAndOldOS() throws {
        let key = Curve25519.Signing.PrivateKey()
        let release = UpdateRelease(version: "0.2.0", build: 2, architecture: "arm64", minimumSystemVersion: "13.0", url: "https://fixture.invalid/VoiceDraft.zip", sha256: String(repeating: "a", count: 64), size: 100, notes: "Fixture")
        let payload = try JSONEncoder().encode(release)
        let data = try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(try UpdateVerifier.verify(data, publicKey: publicKey, architecture: "arm64", systemVersion: "14.0"), release)
        XCTAssertThrowsError(try UpdateVerifier.verify(data, publicKey: publicKey, architecture: "x86_64", systemVersion: "14.0"))
        XCTAssertThrowsError(try UpdateVerifier.verify(data, publicKey: publicKey, architecture: "arm64", systemVersion: "12.0"))
        XCTAssertThrowsError(try UpdateVerifier.verify(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), architecture: "arm64", systemVersion: "14.0"))
        let tampered = try JSONSerialization.data(withJSONObject: ["payload": (payload + Data([32])).base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
        XCTAssertThrowsError(try UpdateVerifier.verify(tampered, publicKey: publicKey, architecture: "arm64", systemVersion: "14.0"))
    }
    func testZipTraversalSymlinksCollisionsAndChecksums() throws {
        let valid = zip([("VoiceDraft.app/Contents/Info.plist", 0x8000), ("VoiceDraft.app/Contents/MacOS/VoiceDraft", 0x8000)])
        try UpdateArchive.validate(valid)
        for path in ["VoiceDraft.app/../escape", "/tmp/escape", "VoiceDraft.app/a\\b", "VoiceDraft.app/./bad"] {
            XCTAssertThrowsError(try UpdateArchive.validate(zip([(path, 0x8000)])))
        }
        XCTAssertThrowsError(try UpdateArchive.validate(zip([("VoiceDraft.app/link", 0xa000)])))
        XCTAssertThrowsError(try UpdateArchive.validate(zip([("VoiceDraft.app/A",0x8000),("VoiceDraft.app/a",0x8000)])))
        var release = UpdateRelease(version: "0.2.0", build: 2, architecture: "arm64", minimumSystemVersion: "13.0", url: "https://fixture.invalid/update.zip", sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(), size: valid.count, notes: "Fixture")
        try UpdateVerifier.verifyPackage(valid, release: release)
        release.size += 1; XCTAssertThrowsError(try UpdateVerifier.verifyPackage(valid, release: release))
    }
    /// Tiny uncompressed central-directory fixture, never executed or extracted.
    private func zip(_ entries: [(String, Int)]) -> Data {
        var local = Data(), directory = Data()
        func field(_ data: inout Data, _ value: Int, _ count: Int) { for i in 0..<count { data.append(UInt8((value >> (8 * i)) & 255)) } }
        for (path, mode) in entries {
            let name = Data(path.utf8), start = local.count
            field(&local, 0x04034b50, 4); field(&local, 20, 2); local.append(Data(repeating: 0, count: 20))
            field(&local, name.count, 2); field(&local, 0, 2); local.append(name)
            field(&directory, 0x02014b50, 4); field(&directory, 0x314, 2); field(&directory, 20, 2)
            directory.append(Data(repeating: 0, count: 20)); field(&directory, name.count, 2)
            directory.append(Data(repeating: 0, count: 8)); field(&directory, mode << 16, 4); field(&directory, start, 4); directory.append(name)
        }
        var end = Data(); field(&end, 0x06054b50, 4); end.append(Data(repeating: 0, count: 4))
        field(&end, entries.count, 2); field(&end, entries.count, 2); field(&end, directory.count, 4); field(&end, local.count, 4); field(&end, 0, 2)
        return local + directory + end
    }
}

extension UpdateTests {
    func testPackagedReleaseProducedByPublishingTool() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEDRAFT_TEST_RELEASE_DIRECTORY"] else { throw XCTSkip("Set VOICEDRAFT_TEST_RELEASE_DIRECTORY to verify a generated local release.") }
        let directory = URL(fileURLWithPath: path)
        let key = try String(contentsOf: directory.appendingPathComponent("public-key.txt"), encoding: .utf8)
        let release = try UpdateVerifier.verify(Data(contentsOf: directory.appendingPathComponent("update.json")), publicKey: key, architecture: "arm64", systemVersion: "26.0")
        try UpdateVerifier.verifyPackage(Data(contentsOf: directory.appendingPathComponent("VoiceDraft.zip")), release: release)
    }
}

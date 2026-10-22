import XCTest
@testable import VoiceDraftCore

final class SyncPairingLinkTests: XCTestCase {
    private let token = String(repeating: "t", count: 40)
    private let server = "https://sync.example.test/base"

    func testRoundTripKeepsReservedAndNonASCIICharacters() throws {
        let passphrase = "a+b & c=d %20 中文 /?#"
        let url = try SyncPairingLink.build(serverURL: server, token: token, passphrase: passphrase)
        XCTAssertEqual(url.scheme, "voicedraft")
        XCTAssertEqual(url.host, "sync")
        XCTAssertFalse(url.absoluteString.contains("中"))
        let pairing = try SyncPairingLink.parse(url)
        XCTAssertEqual(pairing, SyncPairing(serverURL: server, token: token, passphrase: passphrase))
    }

    func testRoundTripThroughText() throws {
        let url = try SyncPairingLink.build(serverURL: server, token: token, passphrase: "correct horse battery")
        let reparsed = try XCTUnwrap(URL(string: url.absoluteString))
        XCTAssertEqual(try SyncPairingLink.parse(reparsed).passphrase, "correct horse battery")
    }

    func testBuildRejectsInvalidValues() {
        XCTAssertThrowsError(try SyncPairingLink.build(serverURL: "http://192.0.2.10:8080", token: token, passphrase: "long enough phrase"))
        XCTAssertThrowsError(try SyncPairingLink.build(serverURL: server, token: "short", passphrase: "long enough phrase"))
        XCTAssertThrowsError(try SyncPairingLink.build(serverURL: server, token: token, passphrase: "short"))
    }

    func testParseRejectsMalformedLinks() throws {
        let valid = try SyncPairingLink.build(serverURL: server, token: token, passphrase: "long enough phrase").absoluteString
        let rejected = [
            valid.replacingOccurrences(of: "voicedraft://", with: "https://"),
            valid.replacingOccurrences(of: "://sync?", with: "://other?"),
            "voicedraft://sync",
            "voicedraft://sync?url=\(server)&token=\(token)",
            valid + "&token=\(token)",
            "voicedraft://sync?url=http%3A%2F%2F192.0.2.10&token=\(token)&passphrase=long%20enough%20phrase",
            "voicedraft://sync?url=https%3A%2F%2Fa.test&token=has%20space%20" + token + "&passphrase=long%20enough%20phrase",
            "voicedraft://sync?url=https%3A%2F%2Fa.test&token=\(token)&passphrase=short",
        ]
        for text in rejected {
            let url = try XCTUnwrap(URL(string: text), text)
            XCTAssertThrowsError(try SyncPairingLink.parse(url), text)
        }
    }

    func testLocalhostHTTPIsAllowedLikeManualSetup() throws {
        let url = try SyncPairingLink.build(serverURL: "http://localhost:8787", token: token, passphrase: "long enough phrase")
        XCTAssertEqual(try SyncPairingLink.parse(url).serverURL, "http://localhost:8787")
    }
}

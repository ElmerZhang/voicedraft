import XCTest
import VoiceDraftCore
@testable import VoiceDraft

/// Pairing-link handling with in-memory credentials and temporary files. Nothing contacts a server:
/// these tests stop before `downloadSync`.
@MainActor
final class SyncPairingTests: XCTestCase {
    private var directory: URL!
    private var credentials: InMemoryCredentialStore!
    // Placeholder values, never sent anywhere.
    private let pairing = SyncPairing(serverURL: "https://sync.example.test", token: String(repeating: "t", count: 40),
                                      passphrase: "placeholder passphrase")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString)")
        credentials = InMemoryCredentialStore()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func makeModel() throws -> AppModel {
        AppModel(dependencies: .init(
            store: try IOSLocalStore(directory: directory), credentials: credentials,
            statusStore: AppStatusStore(fileURL: directory.appendingPathComponent("status.json")),
            resultStore: SharedResultStore(fileURL: directory.appendingPathComponent("result.json")),
            presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent("presence.json")),
            audio: SilentAudioCapture(), keepAlive: SilentStandbyKeepAlive(), usageLog: IOSUsageLog(directory: nil), post: { _ in }, observeKeyboard: false))
    }

    func testConfigureFromParsedLinkStoresConnectionAndResetsRevision() throws {
        let model = try makeModel()
        model.updateDevice { $0.syncRevision = 7; $0.syncIdentity = "previous-server" }
        let link = try SyncPairingLink.build(serverURL: pairing.serverURL, token: pairing.token, passphrase: pairing.passphrase)
        model.receivePairingLink(link)
        let pending = try XCTUnwrap(model.pendingPairing)
        XCTAssertEqual(pending, pairing)

        XCTAssertTrue(model.configurePairing(pending))
        XCTAssertEqual(credentials.values[CredentialAccount.syncToken], pairing.token)
        XCTAssertEqual(credentials.values[CredentialAccount.syncPassphrase], pairing.passphrase)
        XCTAssertEqual(model.device.serverURL, pairing.serverURL)
        XCTAssertEqual(model.device.syncRevision, 0)
        XCTAssertTrue(model.errorMessage.isEmpty)
    }

    func testInvalidLinkShowsErrorAndChangesNothing() throws {
        let model = try makeModel()
        model.receivePairingLink(try XCTUnwrap(URL(string: "voicedraft://sync?url=https%3A%2F%2Fa.test&token=short&passphrase=x")))
        XCTAssertNil(model.pendingPairing)
        XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertNil(credentials.values[CredentialAccount.syncToken])
        XCTAssertEqual(model.device.serverURL, "")
    }

    func testPastedTextMustBeAPairingLink() throws {
        let model = try makeModel()
        model.receivePairingText("https://sync.example.test")
        XCTAssertNil(model.pendingPairing)
        XCTAssertEqual(model.errorMessage.key, "The clipboard does not contain a VoiceDraft pairing link.")

        model.errorMessage = ""
        let link = try SyncPairingLink.build(serverURL: pairing.serverURL, token: pairing.token, passphrase: pairing.passphrase)
        model.receivePairingText("  \(link.absoluteString)\n")
        XCTAssertEqual(model.pendingPairing, pairing)
    }
}

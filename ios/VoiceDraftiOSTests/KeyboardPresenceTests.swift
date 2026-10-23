import XCTest
@testable import VoiceDraft

final class KeyboardPresenceTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("presence-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testRoundTrip() throws {
        let store = KeyboardPresenceStore(fileURL: url)
        // ISO 8601 keeps whole seconds, so use a whole-second date.
        let presence = KeyboardPresence(seenAt: Date(timeIntervalSince1970: 1_800_000_000), fullAccess: true, version: "0.1.0")
        try store.write(presence)
        XCTAssertEqual(store.read(), presence)
    }

    func testMissingFileReadsNil() {
        XCTAssertNil(KeyboardPresenceStore(fileURL: url).read())
    }

    func testMalformedFileReadsNil() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(KeyboardPresenceStore(fileURL: url).read())
        try Data(#"{"seenAt":"2026-01-01T00:00:00Z"}"#.utf8).write(to: url)
        XCTAssertNil(KeyboardPresenceStore(fileURL: url).read())
    }

    func testStatusFollowsMarker() {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(KeyboardSetupStatus(presence: nil), .notSetUp)
        XCTAssertEqual(KeyboardSetupStatus(presence: .init(seenAt: seen, fullAccess: false, version: "1")), .notSetUp)
        XCTAssertEqual(KeyboardSetupStatus(presence: .init(seenAt: seen, fullAccess: true, version: "1")), .enabled(lastSeen: seen))
    }

    func testHomeBannerVisibility() {
        let notSetUp = KeyboardSetupStatus.notSetUp
        let enabled = KeyboardSetupStatus.enabled(lastSeen: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(notSetUp.showsHomeBanner(dismissed: false))
        XCTAssertFalse(notSetUp.showsHomeBanner(dismissed: true))
        XCTAssertFalse(enabled.showsHomeBanner(dismissed: false))
        XCTAssertFalse(enabled.showsHomeBanner(dismissed: true))
    }
}

import XCTest
@testable import VoiceDraft

final class AppStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testIdleIsNeverAvailable() {
        XCTAssertFalse(AppStatus(state: .idle, expiresAt: now.addingTimeInterval(600)).isAvailable(at: now))
    }

    func testActiveStatesAreAvailableUntilExpiry() {
        for state in [AppStatus.State.listening, .recording, .processing] {
            let status = AppStatus(state: state, expiresAt: now.addingTimeInterval(60))
            XCTAssertTrue(status.isAvailable(at: now), "\(state)")
            XCTAssertFalse(status.isAvailable(at: now.addingTimeInterval(60)), "\(state) at expiry")
            XCTAssertFalse(status.isAvailable(at: now.addingTimeInterval(61)), "\(state) after expiry")
        }
    }

    func testPolicyLeasesOnlyWhileListening() {
        let listening = AppStatusPolicy.status(take: .idle, listening: true, now: now)
        XCTAssertEqual(listening.state, .listening)
        XCTAssertEqual(listening.expiresAt, now.addingTimeInterval(AppStatusPolicy.lease))
        XCTAssertTrue(listening.isAvailable(at: now))

        let idle = AppStatusPolicy.status(take: .idle, listening: false, now: now)
        XCTAssertEqual(idle.state, .idle)
        XCTAssertFalse(idle.isAvailable(at: now))

        // An in-app take without a listening session is visible but not available to the keyboard.
        let inApp = AppStatusPolicy.status(take: .recording, listening: false, now: now)
        XCTAssertEqual(inApp.state, .recording)
        XCTAssertFalse(inApp.isAvailable(at: now))
    }

    func testPolicyReportsTakePhaseDuringListening() {
        XCTAssertEqual(AppStatusPolicy.status(take: .recording, listening: true, now: now).state, .recording)
        XCTAssertEqual(AppStatusPolicy.status(take: .processing, listening: true, now: now).state, .processing)
        XCTAssertTrue(AppStatusPolicy.status(take: .processing, listening: true, now: now).isAvailable(at: now))
    }

    func testStatusStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppStatusStore(fileURL: url)
        XCTAssertNil(store.read())
        XCTAssertFalse(store.isAppAvailable(at: now))
        let status = AppStatus(state: .listening, expiresAt: now.addingTimeInterval(900), updatedAt: now)
        try store.write(status)
        XCTAssertEqual(store.read(), status)
        XCTAssertTrue(store.isAppAvailable(at: now))
        XCTAssertFalse(store.isAppAvailable(at: now.addingTimeInterval(901)))
    }
}

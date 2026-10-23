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

final class RecordingMeterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.125)

    func testSampleRejectsOldTakeStaleAndFutureInput() {
        let id = UUID()
        let sample = RecordingMeterSample(takeID: id, level: 0.7, sampledAt: now)
        XCTAssertEqual(sample.usableLevel(for: id, after: now, at: now.addingTimeInterval(0.2)), 0.7)
        XCTAssertEqual(sample.usableLevel(for: nil, after: now, at: now), 0.7)
        XCTAssertNil(sample.usableLevel(for: UUID(), after: now, at: now))
        XCTAssertNil(sample.usableLevel(for: nil, after: now.addingTimeInterval(0.01), at: now))
        XCTAssertNil(sample.usableLevel(for: id, after: now, at: now.addingTimeInterval(0.5)))
        XCTAssertNil(sample.usableLevel(for: id, after: now, at: now.addingTimeInterval(-0.1)))
        XCTAssertNil(RecordingMeterSample(takeID: id, level: .nan, sampledAt: now)
            .usableLevel(for: id, after: now, at: now))
    }

    func testPCMDeterminesAmplitudeAndDoesNotRefreshWithoutNewSamples() throws {
        let router = PCMRouter()
        let id = UUID()
        router.begin(feed: nil, maxSeconds: 1)
        XCTAssertNil(router.recordingMeter(takeID: id))
        router.accept(Data(repeating: 0, count: 320), at: now)
        XCTAssertEqual(router.recordingMeter(takeID: id)?.level, 0)
        // Synthetic 16-bit samples of 4096 produce normalized RMS 0.125, scaled by the shared meter to 0.625.
        router.accept(Data([0, 16, 0, 16]), at: now.addingTimeInterval(0.1))
        let measured = try XCTUnwrap(router.recordingMeter(takeID: id))
        XCTAssertEqual(measured.level, 0.625, accuracy: 0.0001)
        XCTAssertEqual(measured.sampledAt, now.addingTimeInterval(0.1).timeIntervalSince1970)
        XCTAssertNil(measured.usableLevel(for: id, after: now, at: now.addingTimeInterval(1)))
        router.accept(Data([1]), at: now.addingTimeInterval(0.2))
        XCTAssertEqual(router.recordingMeter(takeID: id), measured, "incomplete samples cannot refresh the meter")
        _ = router.end()
        XCTAssertNil(router.recordingMeter(takeID: id))
        router.begin(feed: nil, maxSeconds: 1)
        XCTAssertNil(router.recordingMeter(takeID: id), "a new take cannot inherit the preceding level")
        router.accept(Data([0, 16]), at: now)
        router.cancel()
        XCTAssertNil(router.recordingMeter(takeID: id))
    }

    func testStoreRoundTripPreservesSubsecondTimeAndClears() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecordingMeterStore(fileURL: url)
        let sample = RecordingMeterSample(takeID: UUID(), level: 0.8, sampledAt: now)
        try store.write(sample)
        XCTAssertEqual(store.read(), sample)
        try Data("invalid".utf8).write(to: url)
        XCTAssertNil(store.read())
        try store.write(sample)
        store.clear()
        XCTAssertNil(store.read())
    }
}

@MainActor
final class KeyboardAppCheckTests: XCTestCase {
    private var directory: URL!
    private var store: KeyboardAppCheckStore { KeyboardAppCheckStore(directory: directory) }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testForceQuitWithAnUnexpiredStandbyFileAndOldReplyTimesOut() async throws {
        let status = AppStatusStore(fileURL: directory.appendingPathComponent("app-status.json"))
        try status.write(AppStatus(state: .listening, expiresAt: Date().addingTimeInterval(900)))
        XCTAssertTrue(status.isAppAvailable(), "this reproduces the stale-file false positive")
        try store.writeReply(.init(requestID: UUID(), state: .ready, takeID: nil))
        var replies: [KeyboardAppCheckReply?] = []
        var posts: [String] = []
        let check = KeyboardAppCheck(store: store, post: { posts.append($0) })
        check.start(timeout: 0.02) { replies.append($0) }
        check.receiveReply() // A dead process cannot replace the old reply with this challenge's ID.
        XCTAssertTrue(replies.isEmpty)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(replies.count, 1)
        XCTAssertNil(replies.first!)
        XCTAssertFalse(check.isChecking)
        XCTAssertEqual(posts, [KeyboardBridge.appCheckRequested], "the check never starts the microphone")
        check.receiveReply()
        XCTAssertEqual(replies.count, 1, "a late notification cannot complete the timed-out check again")
    }

    func testOnlyCurrentChallengeCanCompleteAndCancellationDropsLateReplies() async throws {
        let check = KeyboardAppCheck(store: store, post: { _ in })
        var completions = 0
        check.start(timeout: 0.02) { _ in XCTFail("replaced check must not complete") }
        let old = try XCTUnwrap(store.readRequest())
        check.start(timeout: 0.02) { reply in
            XCTAssertEqual(reply?.state, .ready)
            completions += 1
        }
        let current = try XCTUnwrap(store.readRequest())
        XCTAssertNotEqual(old.id, current.id)
        try store.writeReply(.init(requestID: old.id, state: .ready, takeID: nil))
        check.receiveReply()
        XCTAssertEqual(completions, 0)
        try store.writeReply(.init(requestID: current.id, state: .ready, takeID: nil))
        check.receiveReply()
        XCTAssertEqual(completions, 1)
        check.start(timeout: 0.02) { _ in XCTFail("leaving the keyboard must cancel a pending start") }
        let cancelled = try XCTUnwrap(store.readRequest())
        check.cancel()
        try store.writeReply(.init(requestID: cancelled.id, state: .ready, takeID: nil))
        check.receiveReply()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(check.isChecking)
    }

    func testOldAndFutureRequestsAreNotFresh() {
        let now = Date()
        var request = KeyboardAppCheckRequest()
        request.createdAt = now.timeIntervalSince1970
        XCTAssertTrue(request.isFresh(at: now))
        XCTAssertFalse(request.isFresh(at: now.addingTimeInterval(4)))
        XCTAssertFalse(request.isFresh(at: now.addingTimeInterval(-1)))
    }
}

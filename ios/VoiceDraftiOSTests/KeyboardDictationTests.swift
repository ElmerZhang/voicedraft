import XCTest
import VoiceDraftCore
@testable import VoiceDraft

/// The pending-take marker, the keyboard's resume decision, the record link and standby deadlines.
final class KeyboardDictationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testPendingTakeStoreRoundTripAndClear() throws {
        let store = PendingTakeStore(fileURL: url)
        XCTAssertNil(store.read())
        // ISO 8601 keeps whole seconds, so use a whole-second date.
        let take = PendingTake(id: UUID(), startedAt: now, source: "keyboard")
        try store.write(take)
        XCTAssertEqual(store.read(), take)
        store.clear()
        XCTAssertNil(store.read())
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(store.read())
    }

    func testPendingTakeStaleness() {
        let take = PendingTake(startedAt: now)
        XCTAssertFalse(take.isStale(at: now.addingTimeInterval(PendingTake.maxAge)))
        XCTAssertTrue(take.isStale(at: now.addingTimeInterval(PendingTake.maxAge + 1)))
    }

    func testResumeDecision() {
        let take = PendingTake(startedAt: now)
        let other = SharedResult(text: "older", createdAt: now)
        let mine = SharedResult(id: take.id, text: "hello", createdAt: now)
        let working = AppStatus(state: .recording, expiresAt: now, updatedAt: now, takeID: take.id)
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: nil, latest: mine, status: working, now: now), .none)
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: take, latest: nil, status: working, now: now), .resume(take))
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: take, latest: other, status: working, now: now), .resume(take))
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: take, latest: mine, status: nil, now: now), .insert(mine))
        let late = now.addingTimeInterval(PendingTake.maxAge + 1)
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: take, latest: other, status: working, now: late), .clear)
        // A result that did arrive still wins over staleness.
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: take, latest: mine, status: nil, now: late), .insert(mine))
    }

    func testResumeRequiresTheAppToBeWorkingOnTheTake() {
        let take = PendingTake(startedAt: now)
        func decide(_ status: AppStatus?) -> KeyboardResumeDecision {
            KeyboardResumeDecision.decide(pending: take, latest: nil, status: status, now: now.addingTimeInterval(10))
        }
        XCTAssertEqual(decide(nil), .notStarted, "no status file: the app never started")
        for state in [AppStatus.State.idle, .listening] {
            XCTAssertEqual(decide(AppStatus(state: state, expiresAt: now.addingTimeInterval(600), updatedAt: now)),
                           .notStarted, "\(state)")
        }
        XCTAssertEqual(decide(AppStatus(state: .processing, expiresAt: now, updatedAt: now, takeID: take.id)), .resume(take))
        XCTAssertEqual(decide(AppStatus(state: .recording, expiresAt: now, updatedAt: now)), .resume(take),
                       "a status without takeID (older app) still counts")
        XCTAssertEqual(decide(AppStatus(state: .recording, expiresAt: now, updatedAt: now, takeID: UUID())), .notStarted,
                       "the app records another take")
        let old = now.addingTimeInterval(10 - AppStatus.liveTakeWindow - 1)
        XCTAssertEqual(decide(AppStatus(state: .recording, expiresAt: now, updatedAt: old, takeID: take.id)), .notStarted,
                       "status older than two minutes")
        let edge = now.addingTimeInterval(10 - AppStatus.liveTakeWindow)
        XCTAssertEqual(decide(AppStatus(state: .recording, expiresAt: now, updatedAt: edge, takeID: take.id)), .resume(take))
    }

    func testAppStatusTakeIDDecodesFromOlderFilesAndFollowsTheTake() throws {
        let json = #"{"state":"recording","expiresAt":"2027-01-15T08:00:00Z","updatedAt":"2027-01-15T08:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(AppStatus.self, from: Data(json.utf8)).takeID)
        let id = UUID()
        XCTAssertEqual(AppStatusPolicy.status(take: .recording, listening: false, takeID: id, now: now).takeID, id)
        XCTAssertEqual(AppStatusPolicy.status(take: .processing, listening: true, takeID: id, now: now).takeID, id)
        XCTAssertNil(AppStatusPolicy.status(take: .idle, listening: true, takeID: id, now: now).takeID)
        let store = AppStatusStore(fileURL: url)
        try store.write(AppStatus(state: .recording, expiresAt: now, updatedAt: now, takeID: id))
        XCTAssertEqual(store.read()?.takeID, id)
    }

    func testRecordLinkRoundTrip() throws {
        let take = PendingTake()
        let link = try XCTUnwrap(KeyboardRecordLink.url(for: take))
        XCTAssertEqual(link.scheme, "voicedraft")
        XCTAssertEqual(link.host, "record")
        XCTAssertEqual(KeyboardRecordLink.takeID(from: link), take.id)
        for text in ["voicedraft://record?take=nope&source=keyboard", "voicedraft://record?take=\(take.id.uuidString)",
                     "voicedraft://sync?take=\(take.id.uuidString)&source=keyboard"] {
            XCTAssertNil(KeyboardRecordLink.takeID(from: try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testStandbyDeadlines() {
        XCTAssertNil(StandbyPolicy.deadline(extending: nil, minutes: 0, now: now), "0 disables standby")
        let existing = now.addingTimeInterval(120)
        XCTAssertEqual(StandbyPolicy.deadline(extending: existing, minutes: 0, now: now), existing)
        XCTAssertEqual(StandbyPolicy.deadline(extending: nil, minutes: 15, now: now), now.addingTimeInterval(900))
        XCTAssertEqual(StandbyPolicy.deadline(extending: existing, minutes: 5, now: now), now.addingTimeInterval(300))
        let later = now.addingTimeInterval(3_600)
        XCTAssertEqual(StandbyPolicy.deadline(extending: later, minutes: 5, now: now), later, "standby never shrinks")
        XCTAssertEqual(StandbyPolicy.manualDeadline(minutes: 0, now: now), now.addingTimeInterval(900))
        XCTAssertEqual(StandbyPolicy.manualDeadline(minutes: 30, now: now), now.addingTimeInterval(1_800))
    }

    func testStatusLeaseEndsAtStandbyDeadline() {
        let deadline = now.addingTimeInterval(300)
        let status = AppStatusPolicy.status(take: .idle, listening: true, until: deadline, now: now)
        XCTAssertEqual(status.expiresAt, deadline)
        XCTAssertTrue(status.isAvailable(at: now))
        XCTAssertFalse(status.isAvailable(at: deadline))
        XCTAssertEqual(AppStatusPolicy.status(take: .idle, listening: true, until: now.addingTimeInterval(7_200), now: now).expiresAt,
                       now.addingTimeInterval(AppStatusPolicy.lease))
    }
}

/// `voicedraft://record` handling with silent audio, placeholder keys and temporary files. No take reaches a
/// provider: the take is stopped after a few milliseconds and fails as too short.
@MainActor
final class KeyboardRecordLinkModelTests: XCTestCase {
    private var directory: URL!
    private var credentials: InMemoryCredentialStore!
    private var audio: SilentAudioCapture!
    private var returnedHosts: [String?] = []
    private var foregroundActive = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-\(UUID().uuidString)")
        credentials = InMemoryCredentialStore()
        audio = SilentAudioCapture()
        keepAlive.ready = true
        keepAlive.prepared = nil
        returnedHosts = []
        foregroundActive = true
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private var resultStore: SharedResultStore { SharedResultStore(fileURL: directory.appendingPathComponent("result.json")) }
    private var statusStore: AppStatusStore { AppStatusStore(fileURL: directory.appendingPathComponent("status.json")) }
    private var pendingStore: PendingTakeStore { PendingTakeStore(fileURL: directory.appendingPathComponent("pending.json")) }
    private let keepAlive = SilentStandbyKeepAlive()

    private func makeModel(withKeys: Bool) throws -> AppModel {
        let store = try IOSLocalStore(directory: directory)
        let settings = try store.loadSettings()
        try store.saveSettings(settings)
        if withKeys {
            // Placeholder strings, never sent anywhere.
            try credentials.write("placeholder-speech", account: CredentialAccount.profile(settings.speechID))
            try credentials.write("placeholder-writing", account: CredentialAccount.profile(settings.writingID))
        }
        return AppModel(dependencies: .init(
            store: store, credentials: credentials, statusStore: statusStore, resultStore: resultStore,
            presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent("presence.json")),
            audio: audio, keepAlive: keepAlive, usageLog: IOSUsageLog(directory: nil), post: { _ in }, observeKeyboard: false,
            pendingTakeStore: pendingStore,
            returnToHost: { [weak self] host in self?.returnedHosts.append(host); return "test.accepted" },
            isForegroundActive: { [weak self] in self?.foregroundActive == true }))
    }

    func testReturnWaitsForMicrophoneAndPictureInPicturePreparation() async throws {
        let model = try makeModel(withKeys: true)
        keepAlive.ready = false
        let take = PendingTake(hostBundleIdentifier: "example.host")
        try pendingStore.write(take)
        model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: take)))
        await waitUntil { self.audio.isRunning && model.listening }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(returnedHosts.isEmpty)
        keepAlive.prepared = true
        await waitUntil { !self.returnedHosts.isEmpty }
        XCTAssertEqual(returnedHosts, ["example.host"])
        XCTAssertFalse(keepAlive.isReadyForBackground, "didStart may arrive only after returning; do not deadlock the hand-off")
        model.cancelTake()
        model.endListening()
    }

    func testCancelledTakeCannotReturnAfterPiPBecomesReady() async throws {
        let model = try makeModel(withKeys: true)
        keepAlive.ready = false
        let take = PendingTake(hostBundleIdentifier: "example.host")
        try pendingStore.write(take)
        model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: take)))
        await waitUntil { self.audio.isRunning && model.listening }
        model.cancelTake()
        keepAlive.ready = true
        keepAlive.send(.readinessChanged)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(returnedHosts.isEmpty)
        model.endListening()
    }

    func testReturnRequiresFreshMatchingKeyboardMarker() throws {
        let now = Date()
        let take = PendingTake(startedAt: now)
        XCTAssertTrue(take.permitsAutomaticReturn(for: take.id, now: now))
        XCTAssertFalse(take.permitsAutomaticReturn(for: UUID(), now: now))
        XCTAssertFalse(take.permitsAutomaticReturn(for: take.id, now: now.addingTimeInterval(16)))
        XCTAssertFalse(take.permitsAutomaticReturn(for: take.id, now: now.addingTimeInterval(-10)))
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","startedAt":"2026-10-23T00:00:00Z","source":"keyboard"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(PendingTake.self, from: Data(old.utf8)).hostBundleIdentifier)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testRecordLinkStartsKeyboardTakeWithItsIDAndStartsStandby() async throws {
        let model = try makeModel(withKeys: true)
        let take = PendingTake()
        XCTAssertTrue(model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: take))))
        XCTAssertEqual(model.keyboardTakeID, take.id)
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertEqual(model.takeSource, .keyboard)

        await waitUntil { model.listening }
        XCTAssertTrue(model.listening, "a keyboard take starts standby")
        let deadline = try XCTUnwrap(model.listeningEndsAt)
        XCTAssertEqual(deadline.timeIntervalSinceNow, 15 * 60, accuracy: 5)
        XCTAssertEqual(statusStore.read()?.expiresAt.timeIntervalSince1970 ?? 0, deadline.timeIntervalSince1970, accuracy: 1)

        model.keyboardRequestedStop()
        await waitUntil { model.takeState == .idle }
        XCTAssertEqual(model.takeState, .idle)
        let result = try XCTUnwrap(resultStore.read())
        XCTAssertEqual(result.id, take.id, "the keyboard matches the result by the take id")
        XCTAssertEqual(result.text, "", "a too-short take finishes the keyboard's wait with an empty result")
        XCTAssertFalse(audio.isRunning, "standby closes the microphone after the take")
        XCTAssertTrue(keepAlive.isRunning, "the keep-alive keeps the app resident until the deadline")

        model.endListening()
        XCTAssertFalse(audio.isRunning)
        XCTAssertFalse(keepAlive.isRunning)
    }

    func testRecordLinkWithoutKeysDeliversEmptyResultWithItsID() throws {
        let model = try makeModel(withKeys: false)
        let take = PendingTake()
        XCTAssertTrue(model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: take))))
        XCTAssertEqual(model.takeState, .idle)
        XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertEqual(resultStore.read()?.id, take.id)
        XCTAssertFalse(model.listening)
    }

    func testStandbyOffStartsNoStandby() async throws {
        let model = try makeModel(withKeys: true)
        model.setKeyboardStandby(minutes: 0)
        model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: PendingTake())))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.listening)
        model.dismissKeyboardTake()
        XCTAssertEqual(model.takeState, .idle)
        XCTAssertNil(model.keyboardTakeID)
    }

    func testOtherURLsAreNotRecordLinks() throws {
        let model = try makeModel(withKeys: true)
        XCTAssertFalse(model.receiveRecordLink(try XCTUnwrap(URL(string: "voicedraft://sync?url=x"))))
        XCTAssertEqual(model.takeState, .idle)
    }
}

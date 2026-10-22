import XCTest
import VoiceDraftCore
@testable import VoiceDraft

final class TakeMachineTests: XCTestCase {
    func testHappyPath() {
        var machine = TakeMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(machine.handle(.start))
        XCTAssertEqual(machine.state, .recording)
        XCTAssertTrue(machine.handle(.stop))
        XCTAssertEqual(machine.state, .processing)
        XCTAssertTrue(machine.handle(.complete))
        XCTAssertEqual(machine.state, .idle)
    }

    func testFailureAndCancelReturnToIdle() {
        for event in [TakeMachine.Event.fail, .cancel] {
            var recording = TakeMachine()
            recording.handle(.start)
            XCTAssertTrue(recording.handle(event))
            XCTAssertEqual(recording.state, .idle)

            var processing = TakeMachine()
            processing.handle(.start)
            processing.handle(.stop)
            XCTAssertTrue(processing.handle(event))
            XCTAssertEqual(processing.state, .idle)
        }
    }

    func testInvalidEventsAreIgnored() {
        var machine = TakeMachine()
        for event in [TakeMachine.Event.stop, .complete, .fail, .cancel] {
            XCTAssertFalse(machine.handle(event), "\(event) while idle")
            XCTAssertEqual(machine.state, .idle)
        }
        machine.handle(.start)
        XCTAssertFalse(machine.handle(.start), "a second start while recording")
        XCTAssertFalse(machine.handle(.complete), "complete before stop")
        XCTAssertEqual(machine.state, .recording)
        machine.handle(.stop)
        XCTAssertFalse(machine.handle(.start))
        XCTAssertFalse(machine.handle(.stop))
        XCTAssertEqual(machine.state, .processing)
    }
}

/// Drives AppModel takes with silent audio, in-memory credentials and temporary files. No take reaches a
/// provider: every take here fails or is cancelled before recognition.
@MainActor
final class AppModelTakeTests: XCTestCase {
    private var directory: URL!
    private var credentials: InMemoryCredentialStore!
    private var audio: SilentAudioCapture!
    private var posted: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        credentials = InMemoryCredentialStore()
        audio = SilentAudioCapture()
        posted = []
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private var statusStore: AppStatusStore { AppStatusStore(fileURL: directory.appendingPathComponent("status.json")) }
    private var resultStore: SharedResultStore { SharedResultStore(fileURL: directory.appendingPathComponent("result.json")) }

    private func makeModel(withKeys: Bool) throws -> AppModel {
        let store = try IOSLocalStore(directory: directory)
        let settings = try store.loadSettings()
        try store.saveSettings(settings)
        if withKeys {
            // Placeholder strings, never sent anywhere.
            try credentials.write("placeholder-speech", account: CredentialAccount.profile(settings.speechID))
            try credentials.write("placeholder-writing", account: CredentialAccount.profile(settings.writingID))
        }
        return AppModel(dependencies: .init(store: store, credentials: credentials, statusStore: statusStore,
                                            resultStore: resultStore, audio: audio, usageLog: IOSUsageLog(directory: nil),
                                            post: { [weak self] name in self?.posted.append(name) }, observeKeyboard: false))
    }

    private func waitUntilIdle(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where model.takeState != .idle {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.takeState, .idle, file: file, line: line)
    }

    func testFirstLaunchPersistsDefaultProfiles() throws {
        let store = try IOSLocalStore(directory: directory)
        let first = AppModel(dependencies: .init(store: store, credentials: credentials, statusStore: statusStore,
                                                 resultStore: resultStore, audio: audio, usageLog: IOSUsageLog(directory: nil),
                                                 post: { _ in }, observeKeyboard: false))
        let second = AppModel(dependencies: first.dependencies)
        XCTAssertEqual(first.settings.speechID, second.settings.speechID)
        XCTAssertEqual(first.settings.writingID, second.settings.writingID)
    }

    func testStartWithoutKeysStaysIdleAndExplains() throws {
        let model = try makeModel(withKeys: false)
        XCTAssertFalse(model.startTake())
        XCTAssertEqual(model.takeState, .idle)
        XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertFalse(audio.isRunning)
    }

    func testInAppTakeRecordsThenCancels() async throws {
        let model = try makeModel(withKeys: true)
        XCTAssertTrue(model.startTake())
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertEqual(statusStore.read()?.state, .recording)
        XCTAssertTrue(posted.contains(KeyboardBridge.statusUpdated))
        XCTAssertFalse(model.startTake(), "a second start is ignored")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(audio.isRunning)

        model.cancelTake()
        XCTAssertEqual(model.takeState, .idle)
        XCTAssertFalse(audio.isRunning, "the microphone closes after an in-app take")
        XCTAssertEqual(statusStore.read()?.state, .idle)
        XCTAssertNil(resultStore.read(), "in-app cancellation writes no keyboard result")
    }

    func testTooShortTakeFailsBeforeRecognition() async throws {
        let model = try makeModel(withKeys: true)
        model.startTake()
        model.stopTake()
        XCTAssertEqual(model.takeState, .processing)
        XCTAssertEqual(statusStore.read()?.state, .processing)
        await waitUntilIdle(model)
        XCTAssertEqual(model.errorMessage.key, "The recording was too short. Try again.")
        XCTAssertTrue(model.history.isEmpty)
    }

    func testKeyboardTriggersRequireListening() async throws {
        let model = try makeModel(withKeys: true)
        model.keyboardRequestedStart()
        XCTAssertEqual(model.takeState, .idle, "no listening session, no keyboard take")

        await model.setListening(true)
        XCTAssertTrue(model.listening)
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(statusStore.read()?.state, .listening)
        XCTAssertTrue(statusStore.isAppAvailable())

        model.keyboardRequestedStart()
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertEqual(model.takeSource, .keyboard)
        XCTAssertTrue(statusStore.isAppAvailable())

        model.keyboardRequestedStop()
        await waitUntilIdle(model)
        // A failed keyboard take still finishes the keyboard's wait with an empty result.
        XCTAssertEqual(resultStore.read()?.text, "")
        XCTAssertTrue(posted.contains(KeyboardBridge.resultUpdated))
        XCTAssertTrue(audio.isRunning, "the listening session keeps the microphone open")
        XCTAssertEqual(statusStore.read()?.state, .listening)

        model.endListening()
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(statusStore.read()?.state, .idle)
        XCTAssertFalse(statusStore.isAppAvailable())
    }

    func testKeyboardTakeWithoutKeysDeliversEmptyResult() async throws {
        let model = try makeModel(withKeys: false)
        await model.setListening(true)
        model.keyboardRequestedStart()
        XCTAssertEqual(model.takeState, .idle)
        XCTAssertEqual(resultStore.read()?.text, "")
        model.endListening()
    }
}

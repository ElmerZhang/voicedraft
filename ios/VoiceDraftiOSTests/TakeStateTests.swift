import AVFoundation
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
    private var keepAlive: SilentStandbyKeepAlive!
    private var posted: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        credentials = InMemoryCredentialStore()
        audio = SilentAudioCapture()
        keepAlive = SilentStandbyKeepAlive()
        posted = []
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private var statusStore: AppStatusStore { AppStatusStore(fileURL: directory.appendingPathComponent("status.json")) }
    private var resultStore: SharedResultStore { SharedResultStore(fileURL: directory.appendingPathComponent("result.json")) }
    private var meterStore: RecordingMeterStore { RecordingMeterStore(fileURL: directory.appendingPathComponent("meter.json")) }
    private var appCheckStore: KeyboardAppCheckStore { KeyboardAppCheckStore(directory: directory) }

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
                                            resultStore: resultStore,
                                            presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent("presence.json")),
                                            audio: audio, keepAlive: keepAlive, usageLog: IOSUsageLog(directory: nil),
                                            post: { [weak self] name in self?.posted.append(name) }, observeKeyboard: false,
                                            meterStore: meterStore, appCheckStore: appCheckStore))
    }

    func testLiveAppAnswersFreshChallengeWithoutStartingAudio() async throws {
        let model = try makeModel(withKeys: true)
        var request = KeyboardAppCheckRequest()
        try appCheckStore.writeRequest(request)
        model.replyToKeyboardAppCheck()
        XCTAssertEqual(appCheckStore.readReply()?.state, .unavailable)
        XCTAssertFalse(audio.isRunning)

        await model.setListening(true)
        defer { model.endListening() }
        XCTAssertFalse(audio.isRunning, "standby preparation has already closed the microphone")
        let starts = audio.startCount
        request = KeyboardAppCheckRequest()
        try appCheckStore.writeRequest(request)
        model.replyToKeyboardAppCheck()
        XCTAssertEqual(appCheckStore.readReply(), .init(requestID: request.id, state: .ready, takeID: nil))
        XCTAssertEqual(audio.startCount, starts)
        XCTAssertTrue(posted.contains(KeyboardBridge.appCheckReplied))

        let takeID = UUID()
        XCTAssertTrue(model.startTake(source: .keyboard, id: takeID))
        request = KeyboardAppCheckRequest()
        try appCheckStore.writeRequest(request)
        model.replyToKeyboardAppCheck()
        XCTAssertEqual(appCheckStore.readReply(), .init(requestID: request.id, state: .busy, takeID: takeID))
        model.cancelTake()

        let reply = appCheckStore.readReply()
        request = KeyboardAppCheckRequest()
        request.createdAt -= 5
        try appCheckStore.writeRequest(request)
        model.replyToKeyboardAppCheck()
        XCTAssertEqual(appCheckStore.readReply(), reply, "a delayed notification must not revive an expired challenge")
    }

    func testKeyboardMeterPublishesMeasuredPCMAndClearsOnCancelAndStop() async throws {
        let model = try makeModel(withKeys: true)
        let id = UUID()
        let start = Date()
        XCTAssertTrue(model.startTake(source: .keyboard, id: id))
        defer { model.cancelTake() }
        for _ in 0..<100 where !audio.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(audio.isRunning)
        XCTAssertNil(meterStore.read(), "opening the microphone does not invent an input level")
        audio.onPCM?(Data([0, 16, 0, 16]))
        for _ in 0..<100 where meterStore.read() == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let measured = try XCTUnwrap(meterStore.read())
        XCTAssertEqual(measured.takeID, id)
        XCTAssertEqual(measured.usableLevel(for: id, after: start), 0.625)
        let timestamp = measured.sampledAt
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(meterStore.read()?.sampledAt, timestamp, "timer ticks do not make old PCM fresh")
        XCTAssertNil(meterStore.read()?.usableLevel(for: id, after: start))
        audio.onPCM?(Data(repeating: 0, count: 320))
        for _ in 0..<100 where meterStore.read()?.level != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(meterStore.read()?.level, 0)
        model.cancelTake()
        XCTAssertNil(meterStore.read())

        XCTAssertTrue(model.startTake(source: .keyboard))
        for _ in 0..<100 where !audio.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        audio.onPCM?(Data([0, 16, 0, 16]))
        for _ in 0..<100 where meterStore.read() == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(meterStore.read())
        model.stopTake()
        XCTAssertNil(meterStore.read(), "processing must not retain a recording meter")
        await waitUntilIdle(model) // Too-short synthetic input fails before any provider request.
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
                                                 resultStore: resultStore,
                                                 presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent("presence.json")),
                                                 audio: audio, keepAlive: keepAlive, usageLog: IOSUsageLog(directory: nil),
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

        // The fallback that keeps the microphone open for the whole standby window.
        await model.setStandbyKeepsMicrophoneOpen(true)
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

    // MARK: Standby audio (Picture in Picture keep-alive, microphone only during a take)

    func testStandbyIsUnavailableUntilPictureInPictureActuallyStarts() async throws {
        let model = try makeModel(withKeys: true)
        keepAlive.ready = false
        await model.setListening(true)
        XCTAssertTrue(model.listening)
        XCTAssertFalse(statusStore.isAppAvailable(), "creating a PiP controller does not keep the app resident")
        keepAlive.ready = true
        keepAlive.send(.readinessChanged)
        XCTAssertTrue(statusStore.isAppAvailable())
        keepAlive.ready = false
        keepAlive.send(.readinessChanged)
        XCTAssertFalse(statusStore.isAppAvailable(), "stop advertising immediately when PiP stops")
        keepAlive.send(.keepAliveFailed("startup timed out"))
        XCTAssertFalse(model.listening)
    }

    private func waitForMicrophone(_ running: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where audio.isRunning != running {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(audio.isRunning, running, file: file, line: line)
    }

    func testStandbyKeepAliveRunsThroughTakes() async throws {
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        XCTAssertTrue(model.listening)
        XCTAssertTrue(keepAlive.isRunning, "standby keeps the app resident with the keep-alive")
        XCTAssertFalse(audio.isRunning, "the microphone is closed between takes")
        XCTAssertTrue(statusStore.isAppAvailable())

        model.keyboardRequestedStart()
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertTrue(keepAlive.recording, "the window shows the take")
        await waitForMicrophone(true)
        XCTAssertTrue(keepAlive.isRunning, "the Picture in Picture window stays up during the take")

        model.keyboardRequestedStop()
        XCTAssertFalse(keepAlive.recording)
        await waitUntilIdle(model)
        XCTAssertEqual(resultStore.read()?.text, "", "the keyboard's wait ends with a result")
        XCTAssertFalse(audio.isRunning)
        XCTAssertTrue(audio.lastStopKeptSession, "the session stays active between standby takes")
        XCTAssertTrue(keepAlive.isRunning, "still resident until the deadline")
        XCTAssertEqual(keepAlive.startCount, 1, "started once for the whole standby")
        XCTAssertEqual(statusStore.read()?.state, .listening)

        model.endListening()
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertTrue(keepAlive.lastStopDeactivated)
        XCTAssertFalse(audio.isRunning)
        XCTAssertFalse(statusStore.isAppAvailable())
    }

    func testStandbyAudioOrderAndStepNamedErrors() async throws {
        let journal = AudioJournal()
        audio.journal = journal
        keepAlive.journal = journal
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        for _ in 0..<2 {
            model.keyboardRequestedStart()
            await waitForMicrophone(true)
            model.keyboardRequestedStop()
            await waitUntilIdle(model)
        }
        model.endListening()
        // The keep-alive runs from standby start to standby end; each take builds and discards a microphone engine
        // and the session stays active until standby ends.
        XCTAssertEqual(journal.entries, ["mic.start", "keepalive.start", "mic.stop(keep)",
                                         "mic.start", "mic.stop(keep)",
                                         "mic.start", "mic.stop(keep)",
                                         "keepalive.stop(deactivate)"])
        XCTAssertEqual(audio.startCount, 3, "one foreground preparation plus one microphone start per take")

        // 560557684 is '!int' (cannotInterruptOthers): on iOS 27.0.1 a category change from the background.
        let error = AudioStepError(step: "session: setCategory(playAndRecord)",
                                   underlying: NSError(domain: NSOSStatusErrorDomain, code: 560_557_684))
        XCTAssertEqual(error.errorDescription, "session: setCategory(playAndRecord) failed: OSStatus 560557684 '!int'")
        XCTAssertTrue(AppModel.backgroundStartMessage(error).contains("session: setCategory(playAndRecord) failed"))
        XCTAssertNil(AudioStepError.fourCharacterCode(-50))
    }

    func testKeyboardTakeStartingStandbyStartsTheKeepAlive() async throws {
        let journal = AudioJournal()
        audio.journal = journal
        keepAlive.journal = journal
        let model = try makeModel(withKeys: true)
        // A keyboard take opened through `voicedraft://record` (app in the foreground) starts standby while recording.
        XCTAssertTrue(model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: PendingTake()))))
        await waitForMicrophone(true)
        for _ in 0..<200 where !model.listening { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.listening)
        XCTAssertTrue(keepAlive.isRunning, "created while VoiceDraft is still in the foreground")
        model.cancelTake()
        XCTAssertFalse(audio.isRunning)
        XCTAssertTrue(audio.lastStopKeptSession)
        XCTAssertTrue(keepAlive.isRunning)
        model.endListening()
        XCTAssertEqual(journal.entries.last, "keepalive.stop(deactivate)")
    }

    func testKeepAliveEndedEndsStandbyAndPublishesStatus() async throws {
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        posted.removeAll()
        keepAlive.send(.keepAliveEnded)
        XCTAssertFalse(model.listening, "closing the window ends standby")
        XCTAssertTrue(keepAlive.lastStopDeactivated, "the session is deactivated once nothing needs it")
        XCTAssertFalse(statusStore.isAppAvailable(), "the keyboard stops offering hold-to-talk")
        XCTAssertNil(statusStore.read()?.lastError, "closing the window is not an error")
        XCTAssertTrue(posted.contains(KeyboardBridge.statusUpdated), "published immediately")

        await model.setListening(true)
        keepAlive.send(.keepAliveFailed("standby: picture in picture failed: OSStatus 1"))
        XCTAssertFalse(model.listening)
        XCTAssertTrue(statusStore.read()?.lastError?.contains("picture in picture") == true,
                      statusStore.read()?.lastError ?? "nil")
    }

    func testKeepAliveEndingDuringATakeLetsTheTakeFinish() async throws {
        let journal = AudioJournal()
        audio.journal = journal
        keepAlive.journal = journal
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        model.keyboardRequestedStart()
        await waitForMicrophone(true)
        keepAlive.send(.keepAliveEnded)
        XCTAssertFalse(model.listening)
        XCTAssertEqual(model.takeState, .recording, "the take in progress continues")
        XCTAssertTrue(audio.isRunning)
        XCTAssertTrue(statusStore.isAppAvailable(), "a take in progress must remain finishable after PiP closes")
        model.keyboardRequestedStop()
        await waitUntilIdle(model)
        XCTAssertFalse(audio.isRunning)
        XCTAssertTrue(journal.entries.contains("mic.stop(deactivate)"), "the session is deactivated after the take")
        XCTAssertEqual(journal.entries.filter { $0 == "mic.stop(keep)" }.count, 1, "only the foreground preparation kept the session")
    }

    func testInAppTakeDeactivatesTheSession() async throws {
        let model = try makeModel(withKeys: true)
        model.startTake()
        await waitForMicrophone(true)
        XCTAssertTrue(statusStore.isAppAvailable(), "real input readiness must publish without waiting for the status timer")
        model.cancelTake()
        XCTAssertFalse(audio.lastStopKeptSession, "without standby the session is deactivated as before")
        XCTAssertEqual(keepAlive.startCount, 0)
    }

    func testDeadlineEndsStandbyButNotATakeInProgress() async throws {
        let model = try makeModel(withKeys: true)
        // 0 minutes: a keyboard take keeps the existing deadline instead of extending it.
        model.setKeyboardStandby(minutes: 0)
        await model.startStandby(until: Date().addingTimeInterval(0.2))
        model.keyboardRequestedStart()
        await waitForMicrophone(true)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.listening, "the deadline waits for the take")
        XCTAssertEqual(model.takeState, .recording)

        model.keyboardRequestedStop()
        await waitUntilIdle(model)
        XCTAssertFalse(model.listening, "standby past its deadline ends when the take finishes")
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertFalse(audio.isRunning)

        await model.setListening(true)
        model.standbyDeadlinePassed()
        XCTAssertFalse(model.listening)
        XCTAssertFalse(keepAlive.isRunning, "the deadline ends everything")
    }

    func testInterruptionAndResetReactivateTheSession() async throws {
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        keepAlive.send(.interruptionBegan)
        XCTAssertTrue(keepAlive.isRunning, "the window stays up during an interruption")
        XCTAssertTrue(model.listening, "an interruption does not end standby")
        keepAlive.send(.interruptionEnded)
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertEqual(keepAlive.startCount, 2, "the session is activated again")
        keepAlive.send(.mediaServicesReset)
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertEqual(keepAlive.startCount, 3)

        keepAlive.startError = NSError(domain: NSOSStatusErrorDomain, code: 1)
        keepAlive.send(.interruptionBegan)
        keepAlive.send(.interruptionEnded)
        XCTAssertFalse(model.listening, "standby ends when the session cannot be activated again")
        XCTAssertNotNil(statusStore.read()?.lastError)

        keepAlive.startError = nil
        keepAlive.send(.interruptionEnded)
        XCTAssertFalse(keepAlive.isRunning, "no keep-alive outside standby")
    }

    func testBackgroundRecordingRefusalEndsStandbyAndTellsTheKeyboard() async throws {
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        audio.startError = NSError(domain: NSOSStatusErrorDomain,
                                   code: AVAudioSession.ErrorCode.cannotStartRecording.rawValue)
        model.keyboardRequestedStart()
        await waitUntilIdle(model)
        XCTAssertFalse(model.listening)
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertTrue(keepAlive.lastStopDeactivated)
        let status = try XCTUnwrap(statusStore.read())
        XCTAssertFalse(status.isAvailable(), "the keyboard's next tap opens the app")
        XCTAssertTrue(status.lastError?.contains("!rec") == true, status.lastError ?? "nil")
        XCTAssertEqual(resultStore.read()?.text, "", "the keyboard's wait ends")
        XCTAssertTrue(posted.contains(KeyboardBridge.statusUpdated))

        audio.startError = nil
        await model.setListening(true)
        XCTAssertNil(statusStore.read()?.lastError, "a new standby clears the error")
        model.endListening()
    }

    func testKeepAliveFailureKeepsStandbyOff() async throws {
        let model = try makeModel(withKeys: true)
        keepAlive.startError = NSError(domain: NSOSStatusErrorDomain, code: 1)
        await model.setListening(true)
        XCTAssertFalse(model.listening)
        XCTAssertFalse(audio.isRunning, "failed PiP setup must close the foreground preparation microphone")
        XCTAssertFalse(audio.lastStopKeptSession, "failed standby must deactivate the session")
        XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertFalse(statusStore.isAppAvailable())
    }

    func testSwitchingTheMicrophoneFallbackDuringStandby() async throws {
        let model = try makeModel(withKeys: true)
        await model.setListening(true)
        await model.setStandbyKeepsMicrophoneOpen(true)
        XCTAssertTrue(audio.isRunning)
        XCTAssertFalse(keepAlive.isRunning)
        await model.setStandbyKeepsMicrophoneOpen(false)
        XCTAssertFalse(audio.isRunning)
        XCTAssertTrue(audio.lastStopKeptSession)
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertTrue(model.listening)
        model.endListening()

        let older = #"{"keyboardStandbyMinutes":5}"#
        let decoded = try JSONDecoder().decode(IOSDeviceSettings.self, from: Data(older.utf8))
        XCTAssertFalse(decoded.standbyKeepsMicrophoneOpen, "older settings files default to the Picture in Picture standby")
    }
}

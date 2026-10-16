import XCTest
import CoreMedia
import AudioToolbox
@testable import VoiceDraftCore

private final class LiveFixtureSocket: ASRWebSocket, @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var messages: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var sender: CheckedContinuation<Void, Error>?
    private var closed = false
    private var sent: [String] = []
    private var bytes: [Data] = []
    var acknowledge = true
    var stallUpload = false
    var failUpload = false
    var onStart: (() -> Void)?
    var onAudio: (() -> Void)?
    var onFinish: (() -> Void)?
    var state: (closed: Bool, sent: [String], bytes: [Data]) { lock.withLock { (closed, sent, bytes) } }
    func sendText(_ text: String) async throws {
        let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let action = (root["header"] as! [String: Any])["action"] as! String
        try lock.withLock { if closed { throw CancellationError() }; sent.append(action) }
        if action == "run-task" {
            if acknowledge { publish("task-started") }
            onStart?()
        } else { onFinish?() }
    }
    func sendAudio(_ data: Data) async throws {
        try lock.withLock { if closed { throw CancellationError() }; sent.append("audio"); bytes.append(data) }
        if failUpload { throw VoiceDraftError.message("Synthetic send failure") }
        if stallUpload {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { if closed { return true }; sender = continuation; return false }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                onAudio?()
            }
        } else { onAudio?() }
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<String, Error>? = lock.withLock {
                if closed { return .failure(CancellationError()) }
                if !messages.isEmpty { return .success(messages.removeFirst()) }
                precondition(receiver == nil); receiver = continuation; return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
    func publish(_ event: String, sentence: [String: Any]? = nil) {
        let payload: [String: Any] = sentence.map { ["output": ["sentence": $0]] } ?? [:]
        let data = try! JSONSerialization.data(withJSONObject: ["header": ["event": event, "task_id": id], "payload": payload])
        let message = String(decoding: data, as: UTF8.self)
        let waiting = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard !closed else { return nil }
            if let receiver { self.receiver = nil; return receiver }
            messages.append(message); return nil
        }
        waiting?.resume(returning: message)
    }
    func cancel() {
        let waiters = lock.withLock { () -> (CheckedContinuation<String, Error>?, CheckedContinuation<Void, Error>?) in
            closed = true; defer { receiver = nil; sender = nil }; return (receiver, sender)
        }
        waiters.0?.resume(throwing: CancellationError()); waiters.1?.resume(throwing: CancellationError())
    }
}

final class LiveSpeechTests: XCTestCase {
    private func profile() -> ModelProfile {
        var profile = ModelProfile.qwen(.speech)
        profile.selectModel("qwen-audio-3.1-asr-flash-message")
        return profile
    }
    private func run(_ socket: LiveFixtureSocket, feed: LiveAudioFeed,
                     startTimeout: UInt64 = 2_000_000_000, finishTimeout: UInt64 = 2_000_000_000,
                     totalTimeout: UInt64 = 3_000_000_000,
                     ready: @escaping @Sendable () async throws -> Void = {},
                     update: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> String {
        let start = try MessageASRRequests.start(profile: profile(), vocabulary: AppVocabulary(), taskID: socket.id, live: true)
        return try await MessageASRSession.transcribeLive(socket: socket, start: start, audio: feed.stream, taskID: socket.id,
            startTimeout: startTimeout, finishTimeout: finishTimeout, totalTimeout: totalTimeout, onReady: ready, onUpdate: update)
    }
    private func event(_ type: String, sentence: [String: Any]? = nil) throws -> String {
        let payload: [String: Any] = sentence.map { ["output": ["sentence": $0]] } ?? [:]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["header": ["event": type, "task_id": "test"], "payload": payload]), as: UTF8.self)
    }

    func testLiveRequestUsesPCMAndPreservesSpokenCorrections() throws {
        var profile = profile(); profile.extraJSON = #"{"disfluency_removal_enabled":true,"keep_dialect":true}"#
        let request = try MessageASRRequests.start(profile: profile, vocabulary: AppVocabulary(), taskID: "test", live: true)
        let root = try JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let payload = root["payload"] as! [String: Any], parameters = payload["parameters"] as! [String: Any]
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
        XCTAssertEqual(parameters["intermediate_result_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["heartbeat"] as? Bool, true)
        XCTAssertEqual(parameters["disfluency_removal_enabled"] as? Bool, false)
        XCTAssertEqual(parameters["keep_dialect"] as? Bool, true)
    }
    func testHypothesesReplaceBySentenceAndNeverOverwriteFinals() throws {
        var results = MessageASRResults(taskID: "test")
        try results.accept(event("task-started"))
        try results.accept(event("result-generated", sentence: ["sentence_id": 1, "text": "", "sentence_begin": true]))
        try results.accept(event("result-generated", sentence: ["sentence_id": 1, "text": "Tuesday", "sentence_end": false]))
        XCTAssertEqual(results.preview, "Tuesday")
        try results.accept(event("result-generated", sentence: ["sentence_id": 1, "text": "Thursday", "sentence_end": false]))
        XCTAssertEqual(results.preview, "Thursday")
        try results.accept(event("result-generated", sentence: ["sentence_id": 2, "text": "Second", "sentence_end": false]))
        try results.accept(event("result-generated", sentence: ["sentence_id": 0, "heartbeat": true]))
        XCTAssertEqual(results.preview, "Thursday\nSecond")
        try results.accept(event("result-generated", sentence: ["sentence_id": 1, "text": "Thursday.", "sentence_end": true]))
        try results.accept(event("result-generated", sentence: ["sentence_id": 1, "text": "Late partial", "sentence_end": false]))
        XCTAssertEqual(results.preview, "Thursday.\nSecond")
        try results.accept(event("result-generated", sentence: ["sentence_id": 2, "text": "Second.", "sentence_end": true]))
        try results.accept(event("task-finished"))
        XCTAssertEqual(try results.transcript(), "Thursday.\nSecond.")
    }
    func testMissingFinalTailRejectsOtherwiseValidTranscript() throws {
        var results = MessageASRResults(taskID: "test")
        try results.accept(event("task-started"))
        try results.accept(event("result-generated", sentence: ["sentence_id": 1, "text": "Final first sentence", "sentence_end": true]))
        try results.accept(event("result-generated", sentence: ["sentence_id": 2, "text": "Unfinished correction", "sentence_end": false]))
        try results.accept(event("task-finished"))
        XCTAssertThrowsError(try results.transcript()) { XCTAssertFalse($0 is SpeechRecognitionError) }
    }
    func testSilentLiveTakeFinishesAndClosesSocketWithoutFailure() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
        socket.onFinish = { socket.publish("task-finished") }
        do {
            _ = try await run(socket, feed: feed, ready: {
                try feed.append(Data(repeating: 0, count: 3200))
                try feed.finish()
            })
            XCTFail("Expected the no-speech outcome")
        } catch {
            guard case SpeechRecognitionError.noSpeech = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(socket.state.sent, ["run-task", "audio", "finish-task"])
        XCTAssertTrue(socket.state.closed)
    }
    func testLiveUpdatesBeforeStopAndFlushesExactTailAfterAcknowledgement() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
        socket.acknowledge = false
        let started = expectation(description: "run-task"), first = expectation(description: "partial before stop")
        socket.onStart = { started.fulfill() }
        socket.onAudio = { socket.publish("result-generated", sentence: ["sentence_id": 1, "text": "Meet Tuesday", "sentence_end": false]) }
        socket.onFinish = {
            socket.publish("result-generated", sentence: ["sentence_id": 1, "text": "Meet Tuesday, no, Thursday.", "sentence_end": true])
            socket.publish("task-finished")
        }
        let input = Data((0..<7218).map { UInt8($0 % 251) })
        let operation = Task {
            try await run(socket, feed: feed, ready: { try feed.append(input) }, update: { text in
                if text == "Meet Tuesday" { first.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(socket.state.bytes.isEmpty, "No capture or upload before acknowledgement")
        socket.publish("task-started")
        await fulfillment(of: [first], timeout: 1)
        XCTAssertFalse(socket.state.sent.contains("finish-task"), "Preview must arrive while the microphone feed is open")
        try feed.finish()
        let result = try await operation.value
        XCTAssertEqual(result, "Meet Tuesday, no, Thursday.")
        XCTAssertEqual(socket.state.sent, ["run-task", "audio", "audio", "audio", "finish-task"])
        XCTAssertEqual(socket.state.bytes.map(\.count), [3200, 3200, 818])
        XCTAssertEqual(socket.state.bytes.reduce(Data(), +), input)
        XCTAssertTrue(socket.state.closed)
    }
    func testCancellationUnblocksHandshakeCaptureUploadAndFinalWait() async throws {
        for phase in ["handshake", "capture", "upload", "final"] {
            let socket = LiveFixtureSocket(), feed = LiveAudioFeed(), waiting = expectation(description: phase)
            socket.acknowledge = phase != "handshake"; socket.stallUpload = phase == "upload"
            if phase == "handshake" { socket.onStart = { waiting.fulfill() } }
            if phase == "upload" { socket.onAudio = { waiting.fulfill() } }
            if phase == "final" { socket.onFinish = { waiting.fulfill() } }
            let operation = Task {
                try await run(socket, feed: feed, ready: {
                    if phase == "capture" { waiting.fulfill() }
                    if phase == "upload" || phase == "final" { try feed.append(Data(repeating: 0, count: 3200)) }
                    if phase == "final" { try feed.finish() }
                })
            }
            await fulfillment(of: [waiting], timeout: 1)
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Cancellation returned success: \(phase)") }
            catch { XCTAssertTrue(error is CancellationError, "\(phase): \(error)") }
            XCTAssertTrue(socket.state.closed)
        }
    }
    func testStartFinalAndStalledUploadDeadlines() async throws {
        for phase in ["handshake", "upload", "final"] {
            let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
            socket.acknowledge = phase != "handshake"; socket.stallUpload = phase == "upload"
            do {
                _ = try await run(socket, feed: feed, startTimeout: 30_000_000, finishTimeout: 30_000_000,
                                  totalTimeout: 150_000_000, ready: {
                    try feed.append(Data(repeating: 0, count: 3200)); try feed.finish()
                })
                XCTFail("Expected timeout: \(phase)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(phase): \(error)") }
            XCTAssertTrue(socket.state.closed)
        }
    }
    func testEarlyFinishDisconnectAndSendFailureCannotCommitText() async throws {
        for phase in ["early", "disconnect", "send"] {
            let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
            socket.failUpload = phase == "send"
            socket.onAudio = {
                socket.publish("result-generated", sentence: ["sentence_id": 1, "text": "Do not insert", "sentence_end": true])
                if phase == "early" { socket.publish("task-finished") }
                if phase == "disconnect" { socket.cancel() }
            }
            do {
                _ = try await run(socket, feed: feed, ready: { try feed.append(Data(repeating: 0, count: 3200)) })
                XCTFail("Expected failure: \(phase)")
            } catch { }
            XCTAssertTrue(socket.state.closed)
            XCTAssertFalse(socket.state.sent.contains("finish-task"))
        }
    }
    func testCaptureFailureClosesSessionWithoutSuccess() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
        do {
            _ = try await run(socket, feed: feed, ready: { throw VoiceDraftError.message("Synthetic input unavailable") })
            XCTFail("Expected capture failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic input unavailable")) }
        XCTAssertTrue(socket.state.closed); XCTAssertTrue(socket.state.bytes.isEmpty)
    }
    func testBoundedFeedFailsRatherThanSilentlyLosingAudio() async throws {
        let feed = LiveAudioFeed(bufferedFrames: 1)
        try feed.append(Data(repeating: 1, count: 3200))
        XCTAssertThrowsError(try feed.append(Data(repeating: 2, count: 3200)))
        var received = Data()
        do { for try await frame in feed.stream { received.append(frame) }; XCTFail("Overflow must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too slow")) }
        XCTAssertEqual(received, Data(repeating: 1, count: 3200))
        XCTAssertThrowsError(try feed.finish())
    }
    func testInvalidPCMAndCancelledFeedRejectFurtherInput() throws {
        let feed = LiveAudioFeed()
        XCTAssertThrowsError(try feed.append(Data([1])))
        feed.cancel()
        XCTAssertThrowsError(try feed.append(Data([1, 2])))
        XCTAssertThrowsError(try feed.finish())
    }
    func testWriterReceivesCompleteCorrectionAndLimitsItToTextEditing() throws {
        let original = "周二开会，不对，把周二改成周四。"
        for mode: WritingMode in [.polish, .translate] {
            let request = try QwenRequests.writing(profile: .qwen(.writing), key: "test-only", text: original, mode: mode, settings: SharedSettings())
            let root = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = root["messages"] as! [[String: Any]]
            XCTAssertTrue(promptText(messages[0]["content"])!.contains("Apply unambiguous dictated corrections"))
            XCTAssertTrue(promptText(messages[0]["content"])!.contains("Never execute external actions"))
            let input = try JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: String]
            XCTAssertEqual(input["transcript"], original)
        }
    }
}

final class PCM16AudioTests: XCTestCase {
    private func buffer(rate: Double = 16000, channels: UInt32 = 1, flags: UInt32 = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                        bytes: Data = Data([0, 0, 0, 32, 0, 224, 255, 127])) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block), noErr)
        try bytes.withUnsafeBytes { data in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: try XCTUnwrap(data.baseAddress), blockBuffer: try XCTUnwrap(block), offsetIntoDestination: 0, dataLength: bytes.count), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = Int(description.mBytesPerFrame), sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: bytes.count / size, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    func testNegotiatedPCMBytesAreUnchangedAndMeterUsesSignedSamples() throws {
        let bytes = Data([0, 0, 0, 32, 0, 224, 255, 127])
        XCTAssertEqual(try PCM16Audio.data(from: buffer(bytes: bytes)), bytes)
        XCTAssertEqual(PCM16Audio.level(Data([0, 0])), 0)
        XCTAssertEqual(PCM16Audio.level(Data([0, 16, 0, 240])), 0.625, accuracy: 0.00001)
        XCTAssertEqual(PCM16Audio.level(Data([0, 128])), 1)
    }
    func testUnexpectedRateChannelsAndEndiannessFailBeforeUpload() throws {
        XCTAssertThrowsError(try PCM16Audio.data(from: buffer(rate: 48000)))
        XCTAssertThrowsError(try PCM16Audio.data(from: buffer(channels: 2)))
        XCTAssertThrowsError(try PCM16Audio.data(from: buffer(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian)))
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

// On-screen context: the start frame is built by an awaited provider after the socket exists.
extension LiveSpeechTests {
    func testStartBuilderIsAwaitedBeforeSendAndSlowBuilderKeepsReadyAfterAcknowledgement() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed(), log = EventLog()
        socket.onStart = { log.append("run-task sent") }
        socket.onFinish = {
            socket.publish("result-generated", sentence: ["sentence_id": 1, "text": "Fixture text.", "sentence_end": true])
            socket.publish("task-finished")
        }
        let profile = profile()
        let text = try await MessageASRSession.transcribeLive(socket: socket, start: {
            log.append("builder start")
            try await Task.sleep(nanoseconds: 50_000_000)
            log.append("builder done")
            return try MessageASRRequests.start(profile: profile, vocabulary: AppVocabulary(), taskID: socket.id, live: true, screenTerms: ["ScreenKit"])
        }, audio: feed.stream, taskID: socket.id, startTimeout: 2_000_000_000, finishTimeout: 2_000_000_000, totalTimeout: 3_000_000_000,
        onReady: {
            log.append("ready")
            try feed.append(Data(repeating: 0, count: 3200)); try feed.finish()
        }, onUpdate: { _ in })
        XCTAssertEqual(text, "Fixture text.")
        XCTAssertEqual(log.all, ["builder start", "builder done", "run-task sent", "ready"])
        XCTAssertEqual(socket.state.sent, ["run-task", "audio", "finish-task"])
    }

    func testCancelledStartBuilderClosesSocketWithoutSending() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed(), entered = expectation(description: "builder")
        let operation = Task {
            try await MessageASRSession.transcribeLive(socket: socket, start: {
                entered.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "unused"
            }, audio: feed.stream, taskID: socket.id, onReady: { XCTFail("Not ready without a start frame") }, onUpdate: { _ in })
        }
        await fulfillment(of: [entered], timeout: 1)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancellation returned success") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(socket.state.closed)
        XCTAssertEqual(socket.state.sent, [])
    }

    func testStartBuilderDeadlineStillApplies() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
        do {
            _ = try await MessageASRSession.transcribeLive(socket: socket, start: {
                try await Task.sleep(nanoseconds: 60_000_000_000); return "unused"
            }, audio: feed.stream, taskID: socket.id, startTimeout: 50_000_000, onUpdate: { _ in })
            XCTFail("Expected the start deadline")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertTrue(socket.state.closed)
        XCTAssertEqual(socket.state.sent, [])
    }
}

// Microphone before handshake: capture starts at t0, so PCM can precede `task-started`.
extension LiveSpeechTests {
    func testFramesCapturedBeforeTaskStartedUploadAfterItInOrder() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed(), log = EventLog()
        socket.acknowledge = false
        let started = expectation(description: "run-task")
        socket.onStart = { started.fulfill() }
        socket.onFinish = {
            socket.publish("result-generated", sentence: ["sentence_id": 1, "text": "First word kept.", "sentence_end": true])
            socket.publish("task-finished")
        }
        // Captured during the handshake: before the session even sends run-task.
        let early = Data((0..<9600).map { UInt8($0 % 251) })
        try feed.append(early)
        let operation = Task {
            try await run(socket, feed: feed, ready: { log.append("ready \(socket.state.bytes.count)") })
        }
        await fulfillment(of: [started], timeout: 1)
        // Still captured while waiting for task-started.
        let late = Data((0..<4800).map { UInt8(($0 + 7) % 239) })
        try feed.append(late)
        XCTAssertTrue(socket.state.bytes.isEmpty, "Nothing is uploaded before task-started")
        socket.publish("task-started")
        try feed.finish()
        let text = try await operation.value
        XCTAssertEqual(text, "First word kept.")
        XCTAssertEqual(log.all, ["ready 0"])
        XCTAssertEqual(socket.state.sent, ["run-task", "audio", "audio", "audio", "audio", "audio", "finish-task"])
        XCTAssertEqual(socket.state.bytes.reduce(Data(), +), early + late)
        XCTAssertTrue(socket.state.closed)
    }
    func testFeedFinishedBeforeTaskStartedStillUploadsAndReturnsFinalText() async throws {
        let socket = LiveFixtureSocket(), feed = LiveAudioFeed()
        socket.acknowledge = false
        let started = expectation(description: "run-task")
        socket.onStart = { started.fulfill() }
        socket.onFinish = {
            socket.publish("result-generated", sentence: ["sentence_id": 1, "text": "Short take.", "sentence_end": true])
            socket.publish("task-finished")
        }
        // The key was released during the handshake: capture stopped and flushed its tail.
        let input = Data((0..<5000).map { UInt8($0 % 241) })
        try feed.append(input); try feed.finish()
        let operation = Task { try await run(socket, feed: feed) }
        await fulfillment(of: [started], timeout: 1)
        socket.publish("task-started")
        let text = try await operation.value
        XCTAssertEqual(text, "Short take.")
        XCTAssertEqual(socket.state.sent, ["run-task", "audio", "audio", "finish-task"])
        XCTAssertEqual(socket.state.bytes.map(\.count), [3200, 1800])
        XCTAssertEqual(socket.state.bytes.reduce(Data(), +), input)
    }
    func testDefaultFeedBuffersTheFifteenSecondStartDeadline() async throws {
        let feed = LiveAudioFeed()
        for index in 0..<150 { try feed.append(Data(repeating: UInt8(index % 256), count: 3200)) }
        XCTAssertThrowsError(try feed.append(Data(repeating: 9, count: 3200))) {
            XCTAssertTrue($0.localizedDescription.contains("too slow"))
        }
        var frames = 0
        do { for try await _ in feed.stream { frames += 1 }; XCTFail("Overflow must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too slow")) }
        XCTAssertEqual(frames, 150)
    }
}

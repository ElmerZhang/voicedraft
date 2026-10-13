import XCTest
@testable import VoiceDraftCore

private func event(_ type: String, taskID: String, sentence: [String: Any]? = nil) -> String {
    var payload: [String: Any] = [:]
    if let sentence { payload["output"] = ["sentence": sentence] }
    let data = try! JSONSerialization.data(withJSONObject: ["header": ["event": type, "task_id": taskID], "payload": payload])
    return String(decoding: data, as: UTF8.self)
}

private final class FixtureSocket: ASRWebSocket, @unchecked Sendable {
    enum Mode { case success, neverStart, failure, disconnect, waitForResult, stalledSend, sendFailure }
    let id: String
    let mode: Mode
    let observed: XCTestExpectation?
    private let lock = NSLock()
    private var queue: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var sending: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var actions: [String] = []
    private var frames: [Data] = []
    init(id: String, mode: Mode = .success, observed: XCTestExpectation? = nil) { self.id = id; self.mode = mode; self.observed = observed }
    var state: (cancelled: Bool, actions: [String], frames: [Data]) { lock.withLock { (cancelled, actions, frames) } }
    func sendText(_ text: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let action = (object["header"] as! [String: Any])["action"] as! String
        try lock.withLock { if cancelled { throw CancellationError() }; actions.append(action) }
        if action == "run-task" {
            if mode == .neverStart { observed?.fulfill(); return }
            if mode == .failure {
                publish(#"{"header":{"event":"task-failed","task_id":"\#(id)","error_code":"CLIENT_ERROR","error_message":"synthetic-key audio-content"},"payload":{}}"#)
            } else { publish(event("task-started", taskID: id)) }
        } else if action == "finish-task" {
            switch mode {
            case .disconnect: cancel()
            case .waitForResult: observed?.fulfill()
            default:
                publish(event("result-generated", taskID: id, sentence: ["sentence_id": 1, "text": "Partial", "sentence_end": false]))
                publish(event("result-generated", taskID: id, sentence: ["sentence_id": 1, "text": "Final sentence.", "sentence_end": true]))
                publish(event("task-finished", taskID: id))
            }
        }
    }
    func sendAudio(_ data: Data) async throws {
        try lock.withLock { if cancelled { throw CancellationError() }; actions.append("audio"); frames.append(data) }
        if mode == .sendFailure { throw VoiceDraftError.message("Simulated send failure") }
        if mode == .stalledSend {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let closed = lock.withLock { if cancelled { return true }; sending = continuation; return false }
                if closed { continuation.resume(throwing: CancellationError()) }
                observed?.fulfill()
            }
        }
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<String, Error>? = lock.withLock {
                if cancelled { return .failure(CancellationError()) }
                if !queue.isEmpty { return .success(queue.removeFirst()) }
                precondition(waiting == nil)
                waiting = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
    private func publish(_ text: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            if let next = waiting { waiting = nil; return next }
            queue.append(text); return nil
        }
        continuation?.resume(returning: text)
    }
    func cancel() {
        let pending = lock.withLock { () -> (CheckedContinuation<String, Error>?, CheckedContinuation<Void, Error>?) in
            cancelled = true
            defer { waiting = nil; sending = nil }
            return (waiting, sending)
        }
        pending.0?.resume(throwing: CancellationError()); pending.1?.resume(throwing: CancellationError())
    }
}

final class MessageASRTests: XCTestCase {
    private func profile() -> ModelProfile {
        var p = ModelProfile.qwen(.speech); p.selectModel("qwen-audio-3.1-asr-flash-message"); return p
    }
    private func run(_ socket: FixtureSocket, timeout: UInt64 = 2_000_000_000) async throws -> String {
        let start = try MessageASRRequests.start(profile: profile(), vocabulary: AppVocabulary(words: "Test"), taskID: socket.id)
        return try await MessageASRSession.transcribe(socket: socket, start: start, wav: Data(repeating: 0, count: 7200), taskID: socket.id, timeoutNanoseconds: timeout)
    }

    func testMessageHandshakeAndEnvelopeUseWebSocketAndModelCapabilities() throws {
        var p = profile()
        var vocabulary = AppVocabulary(words: "Other")
        vocabulary.entries.append(.init(text: "Test", priority: true))
        p.extraJSON = #"{"keep_dialect":true,"disfluency_removal_enabled":false}"#
        let request = try MessageASRRequests.connection(profile: p, key: "synthetic-key\n")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/api-ws/v1/inference")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertNil(request.httpBody)
        let id = UUID().uuidString
        let text = try MessageASRRequests.start(profile: p, vocabulary: vocabulary, taskID: id)
        let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let header = root["header"] as! [String: String]
        XCTAssertEqual(header, ["action": "run-task", "task_id": id, "streaming": "duplex"])
        let payload = root["payload"] as! [String: Any]
        XCTAssertEqual(payload["model"] as? String, p.model)
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        let params = payload["parameters"] as! [String: Any]
        XCTAssertEqual(params["format"] as? String, "wav")
        XCTAssertEqual(params["sample_rate"] as? Int, 16000)
        XCTAssertEqual(params["vocabulary"] as? [String: Int], ["Test": 50, "Other": 3])
        XCTAssertEqual(params["keep_dialect"] as? Bool, true)
        XCTAssertFalse(text.contains("synthetic-key"))
        XCTAssertThrowsError(try QwenRequests.speech(profile: p, key: "synthetic-key", wav: Data([1]), vocabulary: AppVocabulary(words: "")))
    }

    func testFinalSentencesReplaceDuplicatesAndIgnorePartialAndHeartbeatEvents() throws {
        let id = UUID().uuidString
        var results = MessageASRResults(taskID: id)
        try results.accept(event("task-started", taskID: id))
        try results.accept(event("result-generated", taskID: id, sentence: ["sentence_id": 0, "heartbeat": true]))
        try results.accept(event("result-generated", taskID: id, sentence: ["sentence_id": 1, "text": "Hypothesis", "sentence_end": false]))
        try results.accept(event("result-generated", taskID: id, sentence: ["sentence_id": 2, "text": "Second.", "sentence_end": true]))
        try results.accept(event("result-generated", taskID: id, sentence: ["sentence_id": 1, "text": "Old.", "sentence_end": true]))
        try results.accept(event("result-generated", taskID: id, sentence: ["sentence_id": 1, "text": "First.", "sentence_end": true]))
        XCTAssertThrowsError(try results.transcript())
        try results.accept(event("task-finished", taskID: id))
        XCTAssertEqual(try results.transcript(), "First.\nSecond.")
        XCTAssertThrowsError(try results.accept(event("task-started", taskID: id)))
    }

    func testMismatchedTaskAndMissingFinalTextFailClosed() throws {
        let id = UUID().uuidString
        var r = MessageASRResults(taskID: id)
        XCTAssertThrowsError(try r.accept(event("task-started", taskID: UUID().uuidString)))
        XCTAssertThrowsError(try r.accept(event("task-finished", taskID: id)))
        try r.accept(event("task-started", taskID: id))
        try r.accept(event("result-generated", taskID: id, sentence: ["sentence_id": 1, "text": "Only partial", "sentence_end": false]))
        try r.accept(event("task-finished", taskID: id))
        XCTAssertThrowsError(try r.transcript())
    }

    func testSessionSendsAudioOnlyAfterStartAndWaitsForFinalResults() async throws {
        let socket = FixtureSocket(id: UUID().uuidString)
        let text = try await run(socket)
        XCTAssertEqual(text, "Final sentence.")
        XCTAssertEqual(socket.state.actions, ["run-task", "audio", "audio", "audio", "finish-task"])
        XCTAssertEqual(socket.state.frames.map(\.count), [3200, 3200, 800])
        XCTAssertEqual(socket.state.frames.reduce(Data(), +), Data(repeating: 0, count: 7200))
        XCTAssertTrue(socket.state.cancelled)
    }

    func testFailureBeforeAudioReturnsSafeCodeAndClosesConnection() async throws {
        let socket = FixtureSocket(id: UUID().uuidString, mode: .failure)
        do { _ = try await run(socket); XCTFail("Expected provider failure") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("CLIENT_ERROR"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
            XCTAssertFalse(error.localizedDescription.contains("audio-content"))
        }
        XCTAssertTrue(socket.state.cancelled)
        XCTAssertTrue(socket.state.frames.isEmpty)
    }

    func testTimeoutUnblocksReceiveAndClosesSocket() async throws {
        let socket = FixtureSocket(id: UUID().uuidString, mode: .neverStart)
        do { _ = try await run(socket, timeout: 20_000_000); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertTrue(socket.state.cancelled)
        XCTAssertTrue(socket.state.frames.isEmpty)
    }

    func testCancellationDuringStartUploadAndFinalWaitUnblocksEveryOperation() async throws {
        for mode: FixtureSocket.Mode in [.neverStart, .stalledSend, .waitForResult] {
            let waiting = expectation(description: "Suspended operation")
            let socket = FixtureSocket(id: UUID().uuidString, mode: mode, observed: waiting)
            let operation = Task { try await run(socket) }
            await fulfillment(of: [waiting], timeout: 1)
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(socket.state.cancelled)
        }
    }

    func testSendFailureAndDisconnectCannotReturnPartialSuccess() async throws {
        for mode: FixtureSocket.Mode in [.sendFailure, .disconnect] {
            let socket = FixtureSocket(id: UUID().uuidString, mode: mode)
            do { _ = try await run(socket); XCTFail("Expected failure") } catch { }
            XCTAssertTrue(socket.state.cancelled)
        }
    }
}

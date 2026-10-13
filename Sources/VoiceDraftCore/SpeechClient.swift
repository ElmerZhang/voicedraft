import Foundation

public enum SpeechClient {
    public static func transcribe(profile: ModelProfile, key: String, wav: Data, vocabulary: AppVocabulary) async throws -> String {
        try profile.validateForInference()
        switch profile.adapter {
        case .qwenChatSpeech:
            let request = try QwenRequests.speech(profile: profile, key: key, wav: wav, vocabulary: vocabulary)
            return try await HTTPTransport().complete(request)
        case .qwenAudioHTTP:
            let request = try AudioHTTPRequests.speech(profile: profile, key: key, wav: wav, vocabulary: vocabulary)
            let (data, response) = try await HTTPTransport().send(request)
            try ProviderFailure.check(data, response: response)
            return try AudioHTTPRequests.parse(data)
        case .qwenMessageWebSocket:
            let request = try MessageASRRequests.connection(profile: profile, key: key)
            let taskID = UUID().uuidString
            let start = try MessageASRRequests.start(profile: profile, vocabulary: vocabulary, taskID: taskID)
            try QwenRequests.validateAudio(wav)
            let socket = NativeASRWebSocket(request: request)
            return try await MessageASRSession.transcribe(socket: socket, start: start, wav: wav, taskID: taskID)
        default: throw VoiceDraftError.message("Choose a supported speech model in Models.")
        }
    }
}

public enum AudioHTTPRequests {
    public static func speech(profile: ModelProfile, key: String, wav: Data, vocabulary: AppVocabulary) throws -> URLRequest {
        try profile.validateForInference()
        guard profile.adapter == .qwenAudioHTTP else { throw VoiceDraftError.message("This model does not use the Qwen Audio HTTP adapter.") }
        try QwenRequests.validateAudio(wav)
        var parameters = try profile.modelParameters()
        parameters["format"] = "wav"; parameters["sample_rate"] = "16000"
        try vocabulary.validate()
        let words = VocabularyProjection.make(vocabulary, for: profile.vocabularyCapability).weighted
        if !words.isEmpty { parameters["vocabulary"] = words }
        let body: [String: Any] = ["input": ["messages": [["role": "user", "content": [
            ["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64,\(wav.base64EncodedString())"]]
        ]]]], "parameters": parameters]
        var request = try QwenRequests.request(profile: profile, key: key, body: body)
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        return request
    }
    public static func parse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any], let text = output["text"] as? String else {
            throw VoiceDraftError.message("Qwen Audio returned an unexpected response. Check the model and endpoint.")
        }
        return try QwenRequests.nonempty(text)
    }
}

public enum MessageASRRequests {
    public static func connection(profile: ModelProfile, key: String) throws -> URLRequest {
        try profile.validateForInference()
        guard profile.adapter == .qwenMessageWebSocket else { throw VoiceDraftError.message("This model does not use the Message WebSocket adapter.") }
        var request = URLRequest(url: try Endpoint.validate(profile.endpoint, webSocket: true), timeoutInterval: 120)
        request.setValue("Bearer \(try QwenRequests.validKey(key, name: profile.name))", forHTTPHeaderField: "Authorization")
        return request
    }
    public static func start(profile: ModelProfile, vocabulary: AppVocabulary, taskID: String) throws -> String {
        try profile.validateForInference()
        guard profile.adapter == .qwenMessageWebSocket else { throw VoiceDraftError.message("Choose a Message speech model.") }
        var parameters = try profile.modelParameters()
        parameters["format"] = "wav"; parameters["sample_rate"] = 16000
        parameters["intermediate_result_enabled"] = false
        try vocabulary.validate()
        let words = VocabularyProjection.make(vocabulary, for: profile.vocabularyCapability).weighted
        if !words.isEmpty { parameters["vocabulary"] = words }
        return try json([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                        "model": profile.model.trimmingCharacters(in: .whitespacesAndNewlines),
                        "parameters": parameters, "input": [:]]
        ])
    }
    public static func finish(taskID: String) throws -> String {
        try json(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
                  "payload": ["input": [:]]])
    }
    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// Per-task state. Intermediate hypotheses never become committed transcript text.
public struct MessageASRResults {
    let taskID: String
    public private(set) var started = false
    public private(set) var finished = false
    private var sentences: [Int: String] = [:]
    public init(taskID: String) { self.taskID = taskID }
    public mutating func accept(_ text: String) throws {
        guard text.utf8.count <= 1_000_000,
              let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let header = root["header"] as? [String: Any],
              header["task_id"] as? String == taskID,
              let event = header["event"] as? String, !finished else {
            throw VoiceDraftError.message("Unexpected speech event or task ID. Please try again.")
        }
        if event == "task-failed" { throw ProviderFailure.webSocket(header, taskID: taskID) }
        switch event {
        case "task-started":
            guard !started else { throw VoiceDraftError.message("The speech service started the task twice.") }
            started = true
        case "result-generated":
            guard started,
                  let payload = root["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else {
                throw VoiceDraftError.message("Unexpected speech result. Please try again.")
            }
            if sentence["heartbeat"] as? Bool == true { return }
            guard sentence["sentence_end"] as? Bool == true else { return }
            guard let id = sentence["sentence_id"] as? Int, (1...10_000).contains(id),
                  let value = sentence["text"] as? String, value.utf8.count <= 100_000 else {
                throw VoiceDraftError.message("The speech service returned an invalid sentence.")
            }
            sentences[id] = value
        case "task-finished":
            guard started else { throw VoiceDraftError.message("The speech task ended before it started.") }
            finished = true
        default: throw VoiceDraftError.message("The speech service returned an unsupported event.")
        }
    }
    public func transcript() throws -> String {
        guard finished else { throw VoiceDraftError.message("The speech connection ended before the final result.") }
        return try QwenRequests.nonempty(sentences.keys.sorted().compactMap { sentences[$0] }.joined(separator: "\n"))
    }
}

// Injectable boundary: protocol sequencing, cancellation, and failures can be tested without
// credentials, recordings, or a localhost listener.
protocol ASRWebSocket: Sendable {
    func sendText(_ text: String) async throws
    func sendAudio(_ data: Data) async throws
    func receive() async throws -> String
    func cancel()
}

private final class NativeASRWebSocket: ASRWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: HTTPTransport(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_000_000
        socket.resume()
    }
    func sendText(_ text: String) async throws {
        do { try await socket.send(.string(text)) } catch { throw connectionError(error) }
    }
    func sendAudio(_ data: Data) async throws {
        do { try await socket.send(.data(data)) } catch { throw connectionError(error) }
    }
    func receive() async throws -> String {
        do {
            switch try await socket.receive() {
            case .string(let text): return text
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else { throw VoiceDraftError.message("The speech service returned non-text data.") }
                return text
            @unknown default: throw VoiceDraftError.message("Unexpected WebSocket frame.")
            }
        } catch { throw connectionError(error) }
    }
    private func connectionError(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        if let response = socket.response as? HTTPURLResponse, response.statusCode != 101 {
            return ProviderFailure.http(status: response.statusCode)
        }
        return error
    }
    func cancel() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { cancel() }
}

enum MessageASRSession {
    static func transcribe(socket: any ASRWebSocket, start: String, wav: Data, taskID: String,
                           timeoutNanoseconds: UInt64 = 120_000_000_000) async throws -> String {
        try await withTaskCancellationHandler {
            defer { socket.cancel() }
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await exchange(socket: socket, start: start, wav: wav, taskID: taskID) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw VoiceDraftError.message("Speech recognition timed out. Try a shorter recording.")
                }
                defer { group.cancelAll(); socket.cancel() }
                return try await group.next()!
            }
        } onCancel: { socket.cancel() }
    }

    private static func exchange(socket: any ASRWebSocket, start: String, wav: Data, taskID: String) async throws -> String {
        try Task.checkCancellation()
        try await socket.sendText(start)
        var results = MessageASRResults(taskID: taskID)
        try results.accept(await socket.receive())
        guard results.started else { throw VoiceDraftError.message("The speech service did not start the task.") }
        // Full duplex: collect server events while sending the recorded WAV in small binary frames.
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for offset in stride(from: 0, to: wav.count, by: 3200) {
                    try Task.checkCancellation()
                    try await socket.sendAudio(wav.subdata(in: offset..<min(offset + 3200, wav.count)))
                }
                try await socket.sendText(MessageASRRequests.finish(taskID: taskID))
                return nil
            }
            group.addTask {
                var received = results
                while !received.finished {
                    try Task.checkCancellation()
                    try received.accept(await socket.receive())
                }
                return try received.transcript()
            }
            defer { group.cancelAll(); socket.cancel() }
            var transcript: String?
            while let value = try await group.next() {
                if let value { transcript = value }
            }
            // Both the upload (including finish-task) and final result must complete successfully.
            guard let transcript else { throw VoiceDraftError.message("The speech connection closed without a final result.") }
            return transcript
        }
    }
}

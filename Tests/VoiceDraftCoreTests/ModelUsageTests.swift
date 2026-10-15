import XCTest
@testable import VoiceDraftCore

/// Synthetic provider payloads only: no network, audio or credentials.
final class ModelUsageTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func profile(_ adapter: ModelAdapter, endpoint: String? = nil, extraJSON: String = "{}") -> ModelProfile {
        .init(name: "Fixture", role: .writing, endpoint: endpoint ?? "https://fixture.invalid" + adapter.path,
              model: "fixture-model", extraJSON: extraJSON, adapter: adapter)
    }

    // MARK: Parsers

    func testChatCompletionsUsageWithDetails() throws {
        let usage = try XCTUnwrap(ProviderUsage.parse(chatCompletions: json("""
        {"choices":[{"message":{"content":"secret result"}}],
         "usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,
                  "prompt_tokens_details":{"cached_tokens":64,"audio_tokens":90},
                  "completion_tokens_details":{"reasoning_tokens":5}}}
        """)))
        XCTAssertEqual(usage.inputTokens, 120); XCTAssertEqual(usage.outputTokens, 30); XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.cachedInputTokens, 64); XCTAssertEqual(usage.audioTokens, 90)
        XCTAssertEqual(usage.raw["completion_tokens_details.reasoning_tokens"], 5)
        XCTAssertEqual(usage.raw["prompt_tokens_details.audio_tokens"], 90)
        XCTAssertNil(usage.reportedAudioSeconds)
    }

    func testAnthropicStartAndDeltaMerge() throws {
        let start = ProviderUsage.parse(anthropicMessageStart: try json("""
        {"type":"message_start","message":{"id":"m","usage":{"input_tokens":40,"cache_creation_input_tokens":10,
         "cache_read_input_tokens":200,"output_tokens":1}}}
        """))
        XCTAssertEqual(start?.outputTokens, 1)
        let merged = try XCTUnwrap(ProviderUsage.merge(start, anthropicMessageDelta: json("""
        {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":57}}
        """)))
        XCTAssertEqual(merged.inputTokens, 40); XCTAssertEqual(merged.outputTokens, 57); XCTAssertEqual(merged.totalTokens, 97)
        XCTAssertEqual(merged.cachedInputTokens, 200); XCTAssertEqual(merged.raw["cache_creation_input_tokens"], 10)
        // A delta without usage keeps the start counts.
        XCTAssertEqual(ProviderUsage.merge(start, anthropicMessageDelta: try json(#"{"type":"message_delta","delta":{}}"#)), start)
        // A non-streaming message body.
        XCTAssertEqual(ProviderUsage.parse(writing: try json(#"{"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":4}}"#),
                                           adapter: .anthropic)?.totalTokens, 7)
    }

    func testResponsesCompletedEventAndBody() throws {
        let event = try XCTUnwrap(ProviderUsage.parse(responsesCompleted: json("""
        {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":80,"output_tokens":20,
         "total_tokens":100,"input_tokens_details":{"cached_tokens":16},"output_tokens_details":{"reasoning_tokens":0}}}}
        """)))
        XCTAssertEqual(event.inputTokens, 80); XCTAssertEqual(event.outputTokens, 20)
        XCTAssertEqual(event.totalTokens, 100); XCTAssertEqual(event.cachedInputTokens, 16)
        XCTAssertEqual(event.raw["output_tokens_details.reasoning_tokens"], 0)
        let body = ProviderUsage.parse(writing: try json(#"{"status":"completed","usage":{"input_tokens":1,"output_tokens":2}}"#), adapter: .responses)
        XCTAssertEqual(body?.totalTokens, 3)
    }

    func testQwenAudioUsage() throws {
        let usage = try XCTUnwrap(ProviderUsage.parse(qwenAudio: json("""
        {"output":{"text":"secret transcript"},"usage":{"input_tokens":130,"output_tokens":9,
         "input_tokens_details":{"audio_tokens":110,"text_tokens":20},"seconds":4}}
        """)))
        XCTAssertEqual(usage.inputTokens, 130); XCTAssertEqual(usage.outputTokens, 9); XCTAssertEqual(usage.totalTokens, 139)
        XCTAssertEqual(usage.audioTokens, 110); XCTAssertEqual(usage.reportedAudioSeconds, 4)
        XCTAssertEqual(usage.raw["input_tokens_details.text_tokens"], 20)
    }

    func testWhisperDurationAndTokenUsage() throws {
        let duration = try XCTUnwrap(ProviderUsage.parse(whisper: json(#"{"text":"hello","usage":{"type":"duration","seconds":3.5}}"#)))
        XCTAssertEqual(duration.reportedAudioSeconds, 3.5); XCTAssertNil(duration.inputTokens)
        XCTAssertEqual(duration.raw, ["seconds": 3.5], "strings such as type are not numeric fields")
        let tokens = try XCTUnwrap(ProviderUsage.parse(whisper: json("""
        {"text":"hello","usage":{"type":"tokens","input_tokens":14,"output_tokens":45,"total_tokens":59,
         "input_token_details":{"text_tokens":0,"audio_tokens":14}}}
        """)))
        XCTAssertEqual(tokens.audioTokens, 14); XCTAssertEqual(tokens.totalTokens, 59)
    }

    func testMessageASRTaskFinishedUsage() throws {
        var results = MessageASRResults(taskID: "t")
        try results.accept(#"{"header":{"task_id":"t","event":"task-started"},"payload":{}}"#)
        try results.accept(#"{"header":{"task_id":"t","event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"hi","sentence_end":true}}}}"#)
        try results.accept(#"{"header":{"task_id":"t","event":"task-finished"},"payload":{"output":{},"usage":{"duration":7}}}"#)
        XCTAssertEqual(results.usage?.reportedAudioSeconds, 7)
        var silent = MessageASRResults(taskID: "t")
        try silent.accept(#"{"header":{"task_id":"t","event":"task-started"},"payload":{}}"#)
        try silent.accept(#"{"header":{"task_id":"t","event":"task-finished"},"payload":{"output":{}}}"#)
        XCTAssertNil(silent.usage)
    }

    func testAbsentUsageIsNil() throws {
        XCTAssertNil(ProviderUsage.parse(chatCompletions: try json(#"{"choices":[]}"#)))
        XCTAssertNil(ProviderUsage.parse(chatCompletions: try json(#"{"choices":[],"usage":null}"#)))
        XCTAssertNil(ProviderUsage.parse(anthropicMessageStart: try json(#"{"type":"message_start","message":{}}"#)))
        XCTAssertNil(ProviderUsage.parse(responsesCompleted: try json(#"{"type":"response.completed","response":{}}"#)))
        XCTAssertNil(ProviderUsage.parse(qwenAudio: try json(#"{"output":{"text":"x"}}"#)))
        XCTAssertNil(ProviderUsage.parse(whisper: try json(#"{"text":"x"}"#)))
        XCTAssertNil(ProviderUsage.parse(messageASRTaskFinished: try json(#"{"payload":{"usage":{}}}"#)))
        XCTAssertNil(ProviderUsage.parse(writing: Data("not json".utf8), adapter: .chatCompletions))
    }

    func testRawFlatteningSkipsNonNumbersAndIsBounded() throws {
        let raw = ProviderUsage.flatten(try json("""
        {"a":1,"flag":true,"label":"text","nested":{"b":2.5,"deeper":{"c":3}},"list":[{"d":4},5],"none":null}
        """))
        XCTAssertEqual(raw, ["a": 1, "nested.b": 2.5, "nested.deeper.c": 3, "list.0.d": 4, "list.1": 5])
        var many: [String: Any] = [:]
        for index in 0..<200 { many["k\(index)"] = index }
        XCTAssertEqual(ProviderUsage.flatten(many).count, ProviderUsage.maximumRawFields)
    }

    func testAddingSumsChunks() {
        let a = ProviderUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12, reportedAudioSeconds: 1.5, raw: ["input_tokens": 10])
        let b = ProviderUsage(inputTokens: 5, totalTokens: 5, audioTokens: 4, raw: ["input_tokens": 5, "x": 1])
        let sum = a.adding(b)
        XCTAssertEqual(sum.inputTokens, 15); XCTAssertEqual(sum.outputTokens, 2); XCTAssertEqual(sum.totalTokens, 17)
        XCTAssertEqual(sum.audioTokens, 4); XCTAssertEqual(sum.reportedAudioSeconds, 1.5); XCTAssertEqual(sum.raw, ["input_tokens": 15, "x": 1])
        let collector = ProviderUsageCollector()
        collector.sink(a); collector.sink(b)
        XCTAssertEqual(collector.usage, sum)
    }

    // MARK: Streams

    func testStreamParsersCollectUsage() throws {
        var chat = WritingStream(adapter: .chatCompletions)
        try chat.consume(event: "", data: #"{"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}],"usage":null}"#)
        XCTAssertTrue(chat.complete); XCTAssertNil(chat.usage)
        try chat.consume(event: "", data: #"{"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":1,"total_tokens":10}}"#)
        try chat.consume(event: "", data: "[DONE]")
        XCTAssertEqual(chat.usage?.totalTokens, 10); XCTAssertTrue(chat.ended); XCTAssertEqual(try chat.finalText(), "hi")

        var anthropic = WritingStream(adapter: .anthropic)
        try anthropic.consume(event: "message_start", data: #"{"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}"#)
        try anthropic.consume(event: "content_block_delta", data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}"#)
        try anthropic.consume(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":6}}"#)
        try anthropic.consume(event: "message_stop", data: #"{"type":"message_stop"}"#)
        XCTAssertEqual(anthropic.usage?.inputTokens, 12); XCTAssertEqual(anthropic.usage?.outputTokens, 6)

        var responses = WritingStream(adapter: .responses)
        try responses.consume(event: "", data: #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":2},"output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}]}}"#)
        XCTAssertEqual(responses.usage?.totalTokens, 5)
    }

    // MARK: Requests

    func testStreamOptionsOnlyForStreamingChatAdapters() throws {
        func body(_ profile: ModelProfile, stream: Bool, includeUsage: Bool = true) throws -> [String: Any] {
            let original = try QwenRequests.writing(profile: profile, key: "k", text: "hello", mode: .polish, settings: SharedSettings())
            let request = try WritingClient.adapt(original, profile: profile, key: "k", stream: stream, includeUsage: includeUsage)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        for adapter in [ModelAdapter.chatCompletions, .qwenChatWriting] {
            XCTAssertEqual((try body(profile(adapter), stream: true)["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true, adapter.rawValue)
            XCTAssertNil(try body(profile(adapter), stream: false)["stream_options"], adapter.rawValue)
            XCTAssertNil(try body(profile(adapter), stream: true, includeUsage: false)["stream_options"], adapter.rawValue)
            let custom = profile(adapter, extraJSON: #"{"stream_options":{"include_usage":false}}"#)
            XCTAssertEqual((try body(custom, stream: true)["stream_options"] as? [String: Any])?["include_usage"] as? Bool, false, adapter.rawValue)
        }
        for adapter in [ModelAdapter.anthropic, .responses] {
            XCTAssertNil(try body(profile(adapter), stream: true)["stream_options"], adapter.rawValue)
        }
    }

    func testStreamingReportsUsageAndRetriesWithoutRejectedStreamOptions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageFixtureProtocol.self]
        let profile = profile(.chatCompletions, endpoint: "https://usage.invalid/v1/chat/completions")
        let original = try QwenRequests.writing(profile: profile, key: "k", text: "hello", mode: .polish, settings: SharedSettings())
        let first = try WritingClient.adapted(original, profile: profile, key: "k", stream: true, includeUsage: true)
        XCTAssertTrue(first.addedStreamUsage)

        UsageFixtureProtocol.reset(mode: .usage)
        let collector = ProviderUsageCollector()
        let text = try await WritingClient.streamWithUsageFallback(first, original: original, profile: profile, key: "k",
            onUpdate: { _ in }, usage: collector.sink, configuration: configuration)
        XCTAssertEqual(text, "hi"); XCTAssertEqual(collector.usage?.totalTokens, 10)
        XCTAssertEqual(UsageFixtureProtocol.requests, [true])

        UsageFixtureProtocol.reset(mode: .rejectStreamOptions)
        let retried = ProviderUsageCollector()
        let retryText = try await WritingClient.streamWithUsageFallback(first, original: original, profile: profile, key: "k",
            onUpdate: { _ in }, usage: retried.sink, configuration: configuration)
        XCTAssertEqual(retryText, "hi"); XCTAssertNil(retried.usage)
        XCTAssertEqual(UsageFixtureProtocol.requests, [true, false], "one retry, without stream_options")

        // A 400 for another reason is a normal provider failure, carrying the status for the log.
        UsageFixtureProtocol.reset(mode: .badRequest)
        do {
            _ = try await WritingClient.streamWithUsageFallback(first, original: original, profile: profile, key: "k",
                onUpdate: { _ in }, usage: nil, configuration: configuration)
            XCTFail("Expected HTTP 400")
        } catch { XCTAssertEqual(ModelUsageFailure.category(error), "http:400") }
        XCTAssertEqual(UsageFixtureProtocol.requests, [true])
    }

    func testFinishedStreamIsKeptWhenUsageNeverArrives() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageFixtureProtocol.self]
        UsageFixtureProtocol.reset(mode: .holdOpen)
        var request = URLRequest(url: URL(string: "https://usage.invalid/v1/chat/completions")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["stream": true, "stream_options": ["include_usage": true]])
        let collector = ProviderUsageCollector()
        let text = try await WritingClient.stream(request, adapter: .chatCompletions, onUpdate: { _ in }, usage: collector.sink,
                                                  configuration: configuration, usageGraceNanoseconds: 200_000_000)
        XCTAssertEqual(text, "hi"); XCTAssertNil(collector.usage)
    }

    // MARK: Records

    func testRecordRoundTripAndForbiddenContent() throws {
        let profile = profile(.chatCompletions, endpoint: "https://api.fixture.invalid/v1/chat/completions?api_key=synthetic-secret")
        let usage = ProviderUsage(inputTokens: 1, outputTokens: 2, totalTokens: 3, raw: ["prompt_tokens": 1])
        let record = ModelUsageRecord(date: Date(timeIntervalSince1970: 1_760_000_000), kind: .writing, source: .historyRewrite, profile: profile, mode: .polish,
                                      streamed: true, audioSeconds: 1.23456, latencyMs: 812, takeID: UUID(), usage: usage)
        XCTAssertEqual(record.host, "api.fixture.invalid"); XCTAssertEqual(record.audioSeconds, 1.235)
        XCTAssertEqual(record.outcome, .ok); XCTAssertTrue(record.usageAvailable); XCTAssertEqual(record.v, 1)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(record)
        XCTAssertEqual(try decoder.decode(ModelUsageRecord.self, from: data), record)
        let line = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(line.contains(#""source":"history.rewrite""#)); XCTAssertTrue(line.contains(#""kind":"writing""#))
        XCTAssertFalse(line.contains("synthetic-secret")); XCTAssertFalse(line.contains("/chat/completions"))

        let failed = ModelUsageRecord(date: Date(), kind: .speech, source: .dictationLiveSpeech, profile: profile, streamed: false, latencyMs: -5,
                                      failure: ProviderFailure.http(status: 429, code: "Throttling", requestID: nil))
        XCTAssertEqual(failed.outcome, .failed); XCTAssertEqual(failed.failure, "http:429")
        XCTAssertFalse(failed.usageAvailable); XCTAssertEqual(failed.latencyMs, 0)

        let forbidden: Set<String> = ["text", "transcript", "result", "prompt", "key", "authorization", "selection", "endpoint", "url"]
        func keys(_ value: Any) -> [String] {
            if let dictionary = value as? [String: Any] { return dictionary.keys.map { $0.lowercased() } + dictionary.values.flatMap(keys) }
            if let array = value as? [Any] { return array.flatMap(keys) }
            return []
        }
        for value in [record, failed] {
            let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
            XCTAssertTrue(Set(keys(object)).isDisjoint(with: forbidden), "\(keys(object))")
        }
    }

    func testSourceRawValuesAreStable() {
        XCTAssertEqual(ModelUsageSource.allCases.map(\.rawValue), [
            "dictation.liveSpeech", "dictation.speech", "dictation.writing", "studio.writing", "history.transcribeAgain",
            "history.rewrite", "style.applyToSelection", "vocabulary.learning", "vocabulary.agentContextFilter",
            "vocabulary.screenContextFilter", "models.connectionTest"])
    }

    func testFailureCategories() {
        XCTAssertEqual(ModelUsageFailure.category(CancellationError()), "cancelled")
        XCTAssertEqual(ModelUsageFailure.category(URLError(.cancelled)), "cancelled")
        XCTAssertEqual(ModelUsageFailure.category(URLError(.timedOut)), "timeout")
        XCTAssertEqual(ModelUsageFailure.category(URLError(.notConnectedToInternet)), "network")
        XCTAssertEqual(ModelUsageFailure.category(ProviderFailure.http(status: 401)), "http:401")
        XCTAssertEqual(ModelUsageFailure.category(FeatureError("The writing request timed out.")), "timeout")
        XCTAssertEqual(ModelUsageFailure.category(VoiceDraftError.message("Speech recognition timed out. Try a shorter recording.")), "timeout")
        XCTAssertEqual(ModelUsageFailure.category(VoiceDraftError.message("Provider said: synthetic-secret")), "other")
        XCTAssertEqual(ModelUsageFailure.category(SpeechRecognitionError.noSpeech), "other")
    }
}

private final class UsageFixtureProtocol: URLProtocol {
    enum Mode { case usage, rejectStreamOptions, badRequest, holdOpen }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = Mode.usage
    nonisolated(unsafe) private static var seen: [Bool] = []
    static func reset(mode: Mode) { lock.withLock { self.mode = mode; seen = [] } }
    /// Whether each received request carried `stream_options`.
    static var requests: [Bool] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "usage.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        let hasOptions = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["stream_options"] != nil
        let mode = Self.lock.withLock { Self.seen.append(hasOptions); return Self.mode }
        if (mode == .rejectStreamOptions && hasOptions) || mode == .badRequest {
            let message = mode == .badRequest ? "invalid model" : "Unrecognized request argument supplied: stream_options"
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["error": ["message": message, "code": "InvalidParameter"]]))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var events = [#"{"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}"#]
        if mode == .usage { events += [#"{"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":1,"total_tokens":10}}"#, "[DONE]"] }
        if mode == .rejectStreamOptions { events += ["[DONE]"] }
        client?.urlProtocol(self, didLoad: Data(events.map { "data: \($0)\n\n" }.joined().utf8))
        // holdOpen never finishes: the client must stop after its usage grace period.
        if mode != .holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

import XCTest
@testable import VoiceDraftCore

final class WritingProtocolTests: XCTestCase {
    func profile(_ adapter: ModelAdapter) -> ModelProfile {
        .init(name: "Fixture", role: .writing, endpoint: "https://fixture.invalid" + adapter.path, model: "fixture-model", adapter: adapter)
    }
    func testProtocolPayloadsAndHeaders() throws {
        for adapter in [ModelAdapter.chatCompletions, .anthropic, .responses] {
            let profile = profile(adapter)
            let original = try QwenRequests.writing(profile: profile, key: "synthetic-key", text: "hello", mode: .polish, settings: SharedSettings())
            let request = try WritingClient.adapt(original, profile: profile, key: "synthetic-key", stream: true)
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            XCTAssertEqual(body["stream"] as? Bool, true); XCTAssertEqual(body["model"] as? String, "fixture-model")
            if adapter == .anthropic {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
                XCTAssertNotNil(body["system"]); XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
                XCTAssertEqual(body["max_tokens"] as? Int, 4096)
            } else if adapter == .responses {
                XCTAssertNil(body["messages"]); XCTAssertEqual(body["store"] as? Bool, false); XCTAssertNotNil(body["input"])
            }
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-key"))
        }
    }
    func testChatStreamRequiresFinishAndRejectsTruncation() throws {
        var parser = WritingStream(adapter: .chatCompletions)
        try parser.consume(event: "", data: #"{"choices":[{"delta":{"content":"你好"}}]}"#)
        XCTAssertThrowsError(try parser.finalText())
        try parser.consume(event: "", data: #"{"choices":[{"delta":{"content":"。"},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(try parser.finalText(), "你好。")
        var truncated = WritingStream(adapter: .chatCompletions)
        XCTAssertThrowsError(try truncated.consume(event: "", data: #"{"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"#))
        var empty = WritingStream(adapter: .chatCompletions)
        XCTAssertThrowsError(try empty.consume(event: "", data: "[DONE]"))
    }
    func testAnthropicAndResponsesStreams() throws {
        var anthropic = WritingStream(adapter: .anthropic)
        try anthropic.consume(event: "content_block_delta", data: #"{"delta":{"type":"text_delta","text":"hello"}}"#)
        try anthropic.consume(event: "message_delta", data: #"{"delta":{"stop_reason":"end_turn"}}"#)
        try anthropic.consume(event: "message_stop", data: #"{"type":"message_stop"}"#)
        XCTAssertEqual(try anthropic.finalText(), "hello")
        var responses = WritingStream(adapter: .responses)
        try responses.consume(event: "", data: #"{"type":"response.output_text.delta","delta":"hel"}"#)
        try responses.consume(event: "", data: #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"hello"}]}]}}"#)
        XCTAssertEqual(try responses.finalText(), "hello")
        XCTAssertThrowsError(try responses.consume(event: "", data: #"{"type":"response.incomplete"}"#))
    }
    func testDiscoveryPreservesGatewayPrefixAndEscapesPagination() throws {
        var profile = profile(.chatCompletions); profile.endpoint = "https://fixture.invalid/proxy/v1/chat/completions"
        XCTAssertEqual(try ModelDiscovery.request(profile: profile, key: "key").url?.path, "/proxy/v1/models")
        profile = self.profile(.anthropic)
        let request = try ModelDiscovery.request(profile: profile, key: "key", after: "a&secret=x")
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.queryItems?.count, 2); XCTAssertEqual(parts.queryItems?.last?.value, "a&secret=x")
    }
    func testRealHTTPStreamingForEveryProtocol() async throws {
        guard let address = ProcessInfo.processInfo.environment["VOICEDRAFT_TEST_SERVER"] else { throw XCTSkip("Run scripts/test-all.sh for local transport fixtures.") }
        for adapter in [ModelAdapter.chatCompletions, .anthropic, .responses] {
            var profile = profile(adapter); profile.endpoint = address + "/mock/stream/" + adapter.rawValue
            let request = try QwenRequests.writing(profile: profile, key: "test-only-key", text: "fixture", mode: .polish, settings: SharedSettings())
            let collector = StreamCollector()
            let result = try await WritingClient.complete(request, profile: profile, key: "test-only-key") { text in await collector.append(text) }
            XCTAssertEqual(result, "你好 VoiceDraft")
            let updates = await collector.values
            XCTAssertTrue(updates.contains(where: { $0 == "你好" || $0 == "你好 VoiceDraft" }))
        }
        var profile = profile(.chatCompletions); profile.endpoint = address + "/mock/stream/truncated"
        let request = try QwenRequests.writing(profile: profile, key: "test-only-key", text: "fixture", mode: .polish, settings: SharedSettings())
        do { _ = try await WritingClient.complete(request, profile: profile, key: "test-only-key", onUpdate: { _ in }); XCTFail("Incomplete stream must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("before writing completed")) }
    }
}
private actor StreamCollector {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

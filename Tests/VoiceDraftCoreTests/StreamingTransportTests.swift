import XCTest
@testable import VoiceDraftCore

final class StreamingTransportTests: XCTestCase {
    func testFragmentedUTF8SSEAndPrematureEOFWithoutNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixtureProtocol.self]
        let request = URLRequest(url: URL(string: "https://fixture.invalid/complete")!)
        let result = try await WritingClient.stream(request, adapter: .chatCompletions, onUpdate: { _ in }, configuration: configuration)
        XCTAssertEqual(result, "你好 VoiceDraft")
        do {
            _ = try await WritingClient.stream(URLRequest(url: URL(string: "https://fixture.invalid/truncated")!), adapter: .chatCompletions, onUpdate: { _ in }, configuration: configuration)
            XCTFail("Early EOF must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("before writing completed")) }
    }
}
private final class StreamFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var events = [#"{"choices":[{"delta":{"content":"你好"}}]}"#]
        if request.url!.path != "/truncated" { events += [#"{"choices":[{"delta":{"content":" VoiceDraft"},"finish_reason":"stop"}]}"#] }
        let data = Data(events.map { "data: \($0)\n\n" }.joined().utf8)
        for index in stride(from: 0, to: data.count, by: 7) { client?.urlProtocol(self, didLoad: Data(data[index..<min(index + 7, data.count)])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import XCTest
@testable import VoiceDraftCore

final class ContextVocabularyFilterTests: XCTestCase {
    func testRequestSendsOnlyCandidateTermsAndKeepsAllWritingProtocols() throws {
        for adapter in [ModelAdapter.qwenChatWriting, .chatCompletions, .anthropic, .responses] {
            let profile = ModelProfile(name: "Fixture", role: .writing, endpoint: "https://fixture.invalid" + adapter.path, model: "chosen-model", extraJSON: #"{"enable_thinking":false,"tools":[{"name":"unused"}],"response_format":{"type":"unrelated"}}"#, adapter: adapter)
            let candidates = ["PR", "UI", "Readme", "API", "AI", "UncommonProduct", "IGNORE_POLICY_981"]
            let request = try ContextVocabularyFilter.request(candidates: candidates, profile: profile, key: "synthetic-key", projectNames: ["UncommonProduct"])
            let data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "chosen-model")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["enable_thinking"] as? Bool, false)
            XCTAssertNil(body["tools"]); XCTAssertNil(body["response_format"])
            XCTAssertEqual(request.timeoutInterval, 45)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-key"))
            let messages = try XCTUnwrap(body[adapter == .responses ? "input" : "messages"] as? [[String: String]])
            let instruction = try XCTUnwrap(adapter == .anthropic ? body["system"] as? String : messages.first?["content"])
            XCTAssertFalse(instruction.contains("IGNORE_POLICY_981"))
            XCTAssertTrue(instruction.contains("common developer abbreviations"))
            XCTAssertTrue(instruction.contains("incidental code symbols"))
            let user = try XCTUnwrap(messages.last?["content"])
            let input = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any])
            XCTAssertEqual(Set(input.keys), ["candidates"])
            let items = try XCTUnwrap(input["candidates"] as? [[String: Any]])
            XCTAssertEqual(items.compactMap { $0["term"] as? String }, candidates)
            XCTAssertEqual(items.compactMap { $0["id"] as? Int }, Array(candidates.indices))
            XCTAssertEqual(items.compactMap { $0["kind"] as? String }, ["term", "term", "term", "term", "term", "project", "term"])
            XCTAssertTrue(items.allSatisfy { Set($0.keys) == ["id", "term", "kind"] })
            XCTAssertTrue(instruction.contains("lowercase and hyphenated"))
        }
    }
    func testSelectionCanOnlyChooseOriginalSpellingsInModelOrder() throws {
        let candidates = ["PR", "UncommonProduct", "UI", "UnusualName"]
        XCTAssertEqual(try ContextVocabularyFilter.selected(from: #"{"keep":[3,1]}"#, candidates: candidates), ["UnusualName", "UncommonProduct"])
        XCTAssertEqual(try ContextVocabularyFilter.selected(from: #"{"keep":[]}"#, candidates: candidates), [])
    }
    func testMalformedInventedDuplicateAndOversizedSelectionsFail() {
        let candidates = ["UncommonProduct", "UI"]
        for response in [#"{"keep":[2]}"#, #"{"keep":[-1]}"#, #"{"keep":[0,0]}"#, #"{"keep":["InventedTerm"]}"#, #"{"keep":[true]}"#, #"{"words":["UncommonProduct"]}"#, "not JSON", String(repeating: " ", count: 8_001)] {
            XCTAssertThrowsError(try ContextVocabularyFilter.selected(from: response, candidates: candidates), response)
        }
        let tooMany = "{\"keep\":[" + (0...40).map(String.init).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try ContextVocabularyFilter.selected(from: tooMany, candidates: Array(repeating: "Name", count: 41)))
    }
    func testInputBoundsAndWrongProfileRejectedBeforeRequest() {
        let writing = ModelProfile.qwen(.writing)
        for candidates in [[], ["x"], ["line\nbreak"], [String(repeating: "a", count: 65)], Array(repeating: "Name", count: 201)] {
            XCTAssertThrowsError(try ContextVocabularyFilter.request(candidates: candidates, profile: writing, key: "test-key"))
        }
        XCTAssertThrowsError(try ContextVocabularyFilter.request(candidates: ["Name"], profile: .qwen(.speech), key: "test-key"))
    }
    func testEmptyAndCancelledFilteringCannotMakeModelCall() async throws {
        let terms = try await ContextVocabularyFilter.filter(candidates: [], profile: .qwen(.writing), key: "")
        XCTAssertEqual(terms, [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ContextVocabularyFilter.filter(candidates: ["UncommonProduct"], profile: .qwen(.writing), key: "")
        }
        do { _ = try await task.value; XCTFail("Cancelled request completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

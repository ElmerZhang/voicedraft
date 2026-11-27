import XCTest
@testable import VoiceDraftCore

/// Request contract of the Draft window: the long-form Polish variant and the whole-draft Edit.
final class DraftWritingRequestTests: XCTestCase {
    private let passage = DraftWritingContext.passage(before: "FIXTURE_BEFORE_1180", after: "FIXTURE_AFTER_5521")

    private func request(_ mode: WritingMode, selection: String = "sel", draft: DraftWritingContext? = nil,
                         adapter: ModelAdapter = .qwenChatWriting) throws -> URLRequest {
        let profile = ModelProfile(name: "Fixture", role: .writing, endpoint: "https://fixture.invalid" + adapter.path,
                                   model: "fixture-model", adapter: adapter)
        return try QwenRequests.writing(profile: profile, key: "k", text: "嗯然后第二点是水渠在哪儿就种在哪儿", mode: mode,
                                        settings: SharedSettings(), selection: selection, application: "VoiceDraft Draft", draft: draft)
    }

    private func blockA(_ request: URLRequest) throws -> String {
        let blocks = try XCTUnwrap(try writingMessages(request).system["content"] as? [[String: Any]])
        return try XCTUnwrap(blocks.first?["text"] as? String)
    }

    private func userInput(_ request: URLRequest) throws -> [String: Any] {
        let content = try XCTUnwrap(try writingMessages(request).user["content"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    func testPassageBlockIsAppendedToCachedPrefixOnlyForDraftPolish() throws {
        let ordinary = try blockA(request(.polish))
        let draft = try blockA(request(.polish, draft: passage))
        // Ordinary takes keep today's bytes; a draft take's block A is that plus the passage rule.
        XCTAssertFalse(ordinary.contains("one passage of a longer document"))
        XCTAssertEqual(draft, ordinary + QwenRequests.draftPassageRule + "\n")
        XCTAssertTrue(ordinary.hasSuffix(QwenRequests.screenContextRule + "\n"))
        // Byte-identical across draft takes: the context lives in the user payload only.
        let other = try blockA(request(.polish, draft: .passage(before: "something else", after: "")))
        XCTAssertEqual(draft, other)
        XCTAssertFalse(draft.contains("FIXTURE_BEFORE_1180")); XCTAssertFalse(draft.contains("FIXTURE_AFTER_5521"))
        // Other modes ignore a passage context.
        for mode in [WritingMode.translate, .verbatim, .edit] {
            XCTAssertEqual(try blockA(request(mode, draft: passage)), try blockA(request(mode)), mode.rawValue)
        }
    }

    func testPassageFieldsArePresentOnlyForDraftPolish() throws {
        let input = try userInput(request(.polish, draft: passage))
        XCTAssertEqual(input["draft_before_reference_only"] as? String, "FIXTURE_BEFORE_1180")
        XCTAssertEqual(input["draft_after_reference_only"] as? String, "FIXTURE_AFTER_5521")
        XCTAssertEqual(input["application"] as? String, "VoiceDraft Draft")
        for (mode, draft) in [(WritingMode.polish, nil), (.translate, passage), (.verbatim, passage),
                              (.edit, passage), (.edit, DraftWritingContext.wholeDraft), (.polish, .wholeDraft)] as [(WritingMode, DraftWritingContext?)] {
            let fields = try userInput(request(mode, draft: draft))
            XCTAssertNil(fields["draft_before_reference_only"], "\(mode)")
            XCTAssertNil(fields["draft_after_reference_only"], "\(mode)")
        }
        // An empty "after" (caret at the end of the draft) is still sent as an empty string.
        let atEnd = try userInput(request(.polish, draft: .passage(before: "前文", after: "")))
        XCTAssertEqual(atEnd["draft_after_reference_only"] as? String, "")
    }

    func testPassageVariantReachesEveryProtocolAsPlainText() throws {
        for adapter in [ModelAdapter.chatCompletions, .anthropic, .responses] {
            let original = try request(.polish, draft: passage, adapter: adapter)
            let adapted = try WritingClient.adapt(original, profile: ModelProfile(name: "Fixture", role: .writing,
                endpoint: "https://fixture.invalid" + adapter.path, model: "fixture-model", adapter: adapter), key: "k", stream: true)
            let body = String(decoding: try XCTUnwrap(adapted.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("one passage of a longer document"), adapter.rawValue)
            XCTAssertTrue(body.contains("FIXTURE_BEFORE_1180"), adapter.rawValue)
            XCTAssertFalse(body.contains("cache_control"), adapter.rawValue)
        }
    }

    func testWholeDraftEditInstructionOnlyWhenTheSelectionIsTheWholeDraft() throws {
        let whole = try blockA(request(.edit, selection: "第一段。\n\n第二段。", draft: .wholeDraft))
        let selection = try blockA(request(.edit, selection: "第二段。"))
        XCTAssertTrue(whole.contains(QwenRequests.wholeDraftEditRule))
        XCTAssertFalse(selection.contains("complete draft"))
        // Edit's existing instruction is otherwise unchanged.
        XCTAssertEqual(whole.replacingOccurrences(of: " " + QwenRequests.wholeDraftEditRule, with: ""), selection)
        // The rule never reaches other modes, and a passage context does not add it to Edit.
        XCTAssertFalse(try blockA(request(.polish, draft: .wholeDraft)).contains("complete draft"))
        XCTAssertFalse(try blockA(request(.edit, draft: passage)).contains("complete draft"))
        let input = try userInput(request(.edit, selection: "第一段。\n\n第二段。", draft: .wholeDraft))
        XCTAssertEqual(input["selected_text"] as? String, "第一段。\n\n第二段。")
        XCTAssertEqual(input["transcript"] as? String, "嗯然后第二点是水渠在哪儿就种在哪儿", "Edit sends the raw instruction")
    }

    func testDraftPolishKeepsTheCleanupPrepass() throws {
        // The passage variant is still Polish: the deterministic pre-pass runs on the transcript.
        let input = try userInput(request(.polish, draft: passage))
        XCTAssertEqual(input["transcript"] as? String,
                       DictationPrepass.dropRedundantRanhou(DictationPrepass.collapseRestatements("嗯然后第二点是水渠在哪儿就种在哪儿")))
    }

    func testTruncatedDraftResponseIsAnError() throws {
        // A finish_reason of length must never become text that replaces the draft.
        var stream = WritingStream(adapter: .qwenChatWriting)
        try stream.consume(event: "", data: #"{"choices":[{"delta":{"content":"半截"}}]}"#)
        XCTAssertThrowsError(try stream.consume(event: "", data: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#))
        XCTAssertThrowsError(try stream.finalText())
        let body = Data(#"{"choices":[{"message":{"content":"半截"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertThrowsError(try QwenRequests.parse(body))
    }
}

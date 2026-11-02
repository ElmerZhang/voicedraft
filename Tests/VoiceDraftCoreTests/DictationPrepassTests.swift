import XCTest
@testable import VoiceDraftCore

final class DictationPrepassTests: XCTestCase {
    private let exampleTake = "天色还早。我们明天会把那盆花。\n啊，应该说是我明天会把那盆花搬到门廊。"
    private let exampleTakeCollapsed = "天色还早。我明天会把那盆花搬到门廊。"

    func testSyntheticTakeCollapsesToTheRestart() {
        XCTAssertEqual(DictationPrepass.collapseRestatements(exampleTake), exampleTakeCollapsed)
    }

    func testInlineAttemptAfterCommaKeepsTheLeadingClause() {
        XCTAssertEqual(DictationPrepass.collapseRestatements("好的，我们周五会把这个，或者说我周五会把报告发给你。"),
                       "好的，我周五会把报告发给你。")
    }

    func testUnchangedInputs() {
        for text in [
            "请标出花圃，Tulip 不是，是 Lily，直接写，或者说 Label Label 就填 Spring。",
            "这个方案可以。\n应该说是目前最稳的一个方案。",
            "我知道，我知道你的意思。",
            "We will ship the, I mean we will ship the build on Friday.",
            ""
        ] {
            XCTAssertEqual(DictationPrepass.collapseRestatements(text), text)
        }
    }

    func testTwoTanglesInOneTranscriptAreBothCollapsed() {
        let text = "我们周五会把这个，或者说我周五会把报告发给你。我们下周会把那个开发。\n嗯，应该说是我下周会把那个开发交给小王。"
        XCTAssertEqual(DictationPrepass.collapseRestatements(text), "我周五会把报告发给你。我下周会把那个开发交给小王。")
    }

    func testIdempotent() {
        for text in [exampleTake, "好的，我们周五会把这个，或者说我周五会把报告发给你。", "这个方案可以。\n应该说是目前最稳的一个方案。"] {
            let once = DictationPrepass.collapseRestatements(text)
            XCTAssertEqual(DictationPrepass.collapseRestatements(once), once)
        }
    }

    func testCleanupModesSendCollapsedTranscriptAndOtherModesSendRaw() throws {
        func transcript(_ mode: WritingMode) throws -> String? {
            let request = try QwenRequests.writing(profile: .qwen(.writing), key: "k", text: exampleTake, mode: mode,
                                                   settings: SharedSettings(), selection: "sel")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any])
            return object["transcript"] as? String
        }
        XCTAssertEqual(try transcript(.polish), exampleTakeCollapsed)
        XCTAssertEqual(try transcript(.translate), exampleTakeCollapsed)
        for mode in [WritingMode.verbatim, .edit, .ask] {
            XCTAssertEqual(try transcript(mode), exampleTake)
        }
    }
}

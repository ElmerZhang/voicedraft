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

    func testRanhouAfterALinkedClauseIsDropped() {
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("如果拉上这道帘子的话，然后角落就看不清了。"),
                       "如果拉上这道帘子的话，角落就看不清了。")
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("等测试跑完然后我们再看。"), "等测试跑完我们再看。")
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("登录之后、然后跳到首页。"), "登录之后、跳到首页。")
    }

    func testRanhouBeforeATimeWordIsDropped() {
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("盖好时水滴就滑落，然后清洗结束后把杯子收起来。"),
                       "盖好时水滴就滑落，清洗结束后把杯子收起来。")
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("先发测试版，然后三天后上线。"), "先发测试版，三天后上线。")
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("先合并，然后我们发布以后再看。"), "先合并，我们发布以后再看。")
    }

    func testSentenceInitialRanhouBeforeATimeWordIsDropped() {
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("然后上线后记得通知我。"), "上线后记得通知我。")
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou("先备份。然后迁移完成的时候告诉我。\n然后两天后复查。"),
                       "先备份。迁移完成的时候告诉我。\n两天后复查。")
    }

    func testOtherRanhouStay() {
        for text in [
            "先备份数据库的话，然后再执行迁移。",
            "先备份数据库，然后再执行迁移以后看看。",
            "他原话是“然后上线后再说”，请保留。",
            "他原话是\"的话，然后看看\"，请保留。",
            "这是一条小路，然后另外一条通向河边。",
            "打开设置。然后点登录。然后输入密码。",
            "然后后台就挂了。",
            "然后它的花盆也是蓝色的，明天再挑。",
            "结束的话，然後識別結束後再說。",
            "这个接口我们就不动了，看看前端那边。",
            "",
            "然"
        ] {
            XCTAssertEqual(DictationPrepass.dropRedundantRanhou(text), text, text)
        }
    }

    func testRanhouDropIsIdempotent() {
        let text = "我如果拉上这道帘子的话，然后角落就看不清了，然后清洗结束后再说。"
        let once = DictationPrepass.dropRedundantRanhou(text)
        XCTAssertEqual(once, "我如果拉上这道帘子的话，角落就看不清了，清洗结束后再说。")
        XCTAssertEqual(DictationPrepass.dropRedundantRanhou(once), once)
    }

    func testCleanupModesSendRanhouPrepassedTranscriptAndVerbatimSendsRaw() throws {
        let raw = "水滴就滑落，然后清洗结束后把杯子收起来。"
        func transcript(_ mode: WritingMode) throws -> String? {
            let request = try QwenRequests.writing(profile: .qwen(.writing), key: "k", text: raw, mode: mode,
                                                   settings: SharedSettings(), selection: "sel")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any])
            return object["transcript"] as? String
        }
        XCTAssertEqual(try transcript(.polish), "水滴就滑落，清洗结束后把杯子收起来。")
        XCTAssertEqual(try transcript(.translate), "水滴就滑落，清洗结束后把杯子收起来。")
        XCTAssertEqual(try transcript(.verbatim), raw)
    }
}

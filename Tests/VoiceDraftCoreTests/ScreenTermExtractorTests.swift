import XCTest
@testable import VoiceDraftCore

// All text is synthetic.
final class ScreenTermExtractorTests: XCTestCase {
    private func terms(_ text: String) throws -> [String: TermExtractor.Candidate] {
        Dictionary(try TermExtractor.candidates(in: text, options: .screenContext).map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private func collection(_ lines: [(ScreenTextSegment.Kind, String)]) -> ScreenTextCollection {
        ScreenTextCollection(segments: lines.enumerated().map { ScreenTextSegment(kind: $0.element.0, text: $0.element.1, order: $0.offset) })
    }

    func testWorkedChatWindowExample() {
        let lines: [(ScreenTextSegment.Kind, String)] = [
            (.windowTitle, "窗口：VoiceDraft 设计评审"),
            (.body, "章山：把 qwen3-asr-flash 换成 Doubao 试试，参考《语音识别最佳实践》"),
            (.body, "Alice Chen: Let's ship the HUD after the Raspberry Pi demo."),
            (.body, "章山：好的，HUD 改完我发 PR")
        ]
        let result = ScreenTermExtractor.terms(from: collection(lines), excludingKeys: [])
        // "章山：" is a chat sender label, so 章山 is a high-confidence proper name
        // (properName 2 × (1 + log2 2) = 4, tied with VoiceDraft and ordered after it).
        XCTAssertEqual(result.map(\.text), ["VoiceDraft", "章山", "qwen3-asr-flash", "语音识别最佳实践", "HUD", "Doubao", "Alice Chen", "Raspberry Pi"])
        XCTAssertEqual(result.map(\.kind), [.camelCase, .properName, .identifier, .quoted, .acronym, .embeddedLatin, .properName, .properName])
        XCTAssertEqual(result.first { $0.text == "HUD" }?.count, 2)
        XCTAssertEqual(result.first { $0.text == "章山" }?.count, 2)
        XCTAssertEqual(result.first?.score, 4) // camelCase 3 + window title 1
        XCTAssertTrue(result.allSatisfy(\.highConfidence))
    }

    func testChatSenderLabelsAndChineseNameSuffixesAreProperNames() throws {
        let chat = """
        小易老师：明天早上八点到校
        程老师 10:32
        今天的作业已经发到群里了
        高琪爸爸
        上午 10:35
        收到，谢谢程老师
        王总说下午开会，我总是迟到，李哥们都在
        Alice Chen 9:41 AM
        elmer: ok
        elmer: sounds good
        dana: once
        时间：下午三点
        Note: bring laptops
        我和高琪爸爸一起去，各位老师辛苦了
        """
        let found = try terms(chat)
        for name in ["小易老师", "程老师", "高琪爸爸", "王总", "Alice Chen", "elmer"] {
            XCTAssertEqual(found[name]?.kind, .properName, name)
        }
        XCTAssertEqual(found["程老师"]?.count, 2)
        XCTAssertEqual(found["高琪爸爸"]?.count, 2)
        for rejected in ["谢程老师", "谢谢程老师", "各位老师", "位老师", "老师", "我总", "李哥", "时间", "Note", "dana", "爸爸"] {
            XCTAssertNil(found[rejected].map { _ in rejected }, rejected)
        }

        // Ranked output: the names are high-confidence terms.
        let ranked = ScreenTermExtractor.terms(from: collection([(.body, chat)]), excludingKeys: [])
        for name in ["小易老师", "程老师", "高琪爸爸", "王总", "Alice Chen", "elmer"] {
            XCTAssertTrue(ranked.contains { $0.text == name && $0.highConfidence }, name)
        }
    }

    func testSenderButtonsFollowedByTheMessageTimeAreNames() {
        // Slack's AX order: sender button (a control), a permalink, the time, then the message.
        let lines: [(ScreenTextSegment.Kind, String)] = [
            (.windowTitle, "general (Channel) - Example - Slack"),
            (.control, "Jinrui"), (.body, "Today at 10:32:15 AM"), (.body, "10:32 AM"), (.body, "我们下周发版"),
            (.control, "Reply"), (.control, "Add reaction"),
            (.control, "Simon Tsao"), (.body, "Today at 10:40:02 AM"), (.body, "10:40 AM"), (.body, "OK"),
            (.control, "Search"), (.body, "Settings")
        ]
        let result = ScreenTermExtractor.terms(from: collection(lines), excludingKeys: [])
        let jinrui = result.first { $0.text == "Jinrui" }
        XCTAssertEqual(jinrui?.kind, .properName)
        XCTAssertTrue(jinrui?.highConfidence == true)
        XCTAssertEqual(result.first { $0.text == "Simon Tsao" }?.kind, .properName)
        XCTAssertFalse(result.contains { ["Reply", "Search", "Settings", "Add reaction"].contains($0.text) }, "\(result.map(\.text))")
        // Excluded vocabulary stays excluded.
        let excluded = ScreenTermExtractor.terms(from: collection(lines), excludingKeys: [AppVocabulary.automaticTermKey("Jinrui")])
        XCTAssertFalse(excluded.contains { $0.text == "Jinrui" })
    }

    func testRepeatedNameLinesCountAsSenders() throws {
        // OCR of a group chat: the sender's name sits on its own line above each bubble.
        let found = try terms("章小山\n好的我看一下\n刘一\n收到\n章小山\n已经改好了\n刘一\n谢谢\nBob Lee\nLooks fine\nBob Lee\nShip it\nThread\nok\nThread\nok")
        XCTAssertEqual(found["章小山"]?.kind, .properName)
        XCTAssertEqual(found["刘一"]?.kind, .properName)
        XCTAssertEqual(found["Bob Lee"]?.kind, .properName)
        XCTAssertNil(found["Thread"], "a repeated single English word is not a sender")
        XCTAssertNil(try terms("回复\n转发\n回复\n转发")["回复"], "UI words never become names")
    }

    func testCamelAcronymAndIdentifierRules() throws {
        let found = try terms("Use iPhone and macOS with gRPC and useEffect in VoiceDraft. CSDN GPT4 ASR foo_bar gpt-4o voice-draft-sync.\nwell-known example.com README.md v1.2.3 www.example.com")
        for (term, kind) in [("iPhone", ScreenTerm.Kind.camelCase), ("macOS", .camelCase), ("gRPC", .camelCase), ("useEffect", .camelCase),
                             ("VoiceDraft", .camelCase), ("CSDN", .acronym), ("GPT4", .acronym), ("ASR", .acronym),
                             ("foo_bar", .identifier), ("gpt-4o", .identifier), ("voice-draft-sync", .identifier)] {
            XCTAssertEqual(found[term]?.kind, kind, term)
        }
        for rejected in ["well-known", "example.com", "README.md", "README", "v1.2.3", "www.example.com", "Use"] {
            XCTAssertNil(found[rejected], rejected)
        }
    }

    func testQuotedRule() throws {
        let found = try terms(#"参考《语音识别最佳实践》和“星火计划”。Say "Project Atlas" and `cfg_key`, 「草稿」 『语音草稿』"#)
        for term in ["语音识别最佳实践", "星火计划", "Project Atlas", "cfg_key", "草稿", "语音草稿"] { XCTAssertEqual(found[term]?.kind, .quoted, term) }
        let rejected = try terms(#"“这句话结束了。还有”, "one two three four five", "Stop!" and "a" or "b", 《一二三四五六七八九十一二三四五六七八九十一二三四五》"#)
        XCTAssertTrue(rejected.values.filter { $0.kind == .quoted }.isEmpty, "\(rejected.keys)")
    }

    func testProperNameRule() throws {
        let found = try terms("We demo on the Raspberry Pi with Visual Studio Code today.\nAlice Chen: hello\nThe Team met.\nProject Phoenix starts now.")
        XCTAssertEqual(found["Raspberry Pi"]?.kind, .properName)
        XCTAssertEqual(found["Visual Studio Code"]?.kind, .properName)
        XCTAssertEqual(found["Alice Chen"]?.kind, .properName, "a speaker label is not a sentence start")
        XCTAssertNil(found["The Team"]); XCTAssertNil(found["Team"])
        XCTAssertNil(found["Project Phoenix"], "sentence-initial once")
        let repeated = try terms("Project Phoenix starts now. Project Phoenix ends later.")
        XCTAssertEqual(repeated["Project Phoenix"]?.count, 2)
        XCTAssertNil(try terms("Please click Sign In or Log Out here.")["Sign In"], "UI stoplist")
    }

    func testEmbeddedLatinNeedsAdjacentHan() throws {
        let found = try terms("把 Doubao 接进来，用 Figma 画，Notion里面写")
        XCTAssertEqual(found["Doubao"]?.kind, .embeddedLatin)
        XCTAssertEqual(found["Figma"]?.kind, .embeddedLatin)
        XCTAssertEqual(found["Notion"]?.kind, .embeddedLatin)
        let english = try terms("Open Figma later. 好的 merge 一下")
        XCTAssertNil(english["Figma"], "no Han neighbour")
        XCTAssertNil(english["merge"], "lowercase words embedded in Chinese are code-switching, not names")
    }

    func testCJKRunsAreRepeatedLowConfidenceAndStoplisted() throws {
        let found = try terms("星火计划下周启动，星火计划很重要。章山说好，章山同意。我们开会，我们讨论。设计评审")
        XCTAssertEqual(found["星火计划"]?.kind, .cjkRun); XCTAssertEqual(found["星火计划"]?.count, 2)
        XCTAssertEqual(found["章山"]?.kind, .cjkRun)
        XCTAssertNil(found["我们"], "stoplist"); XCTAssertNil(found["设计评审"], "single occurrence")
        let term = ScreenTerm(text: "星火计划", kind: .cjkRun)
        XCTAssertFalse(term.highConfidence)
    }

    func testRejectionFilters() throws {
        let text = """
        see https://Example.com/DocsPage now
        mail Alice.Bob@Example.org about /Users/fixture/VoiceDraftNotes and ~/WorkSpace and src/MainView
        build 1234567 deadbee abc1234def AKfixture0123456789abcdefXYZ
        """
        let found = try terms(text)
        for rejected in ["DocsPage", "Example", "VoiceDraftNotes", "WorkSpace", "MainView", "Alice.Bob"] { XCTAssertNil(found[rejected], rejected) }
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("2026-10-15"))
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("12:30"))
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("v1.2.3"))
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("abc1234def"), "git SHA")
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("AKfixture0123456789abcdefXYZ"), "secret-like")
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("one two three four five"))
        XCTAssertFalse(TermExtractor.isAcceptedScreenTerm("x"))
        for stop in ["PR", "API", "JSON", "Settings", "Cancel", "发送", "搜索", "可以"] { XCTAssertFalse(TermExtractor.isAcceptedScreenTerm(stop), stop) }
        XCTAssertTrue(TermExtractor.isAcceptedScreenTerm("VoiceDraft"))
        XCTAssertTrue(TermExtractor.acronymStoplist.isSuperset(of: ["PR", "UI", "API", "AI", "SDK", "TODO", "FAQ"]))
        XCTAssertGreaterThanOrEqual(TermExtractor.englishUIStoplist.count, 60)
        XCTAssertGreaterThanOrEqual(TermExtractor.cjkStoplist.count, 120)
        XCTAssertTrue(try terms("api_key=VoiceDraftSecret\nToken line password LeakName").isEmpty, "credential lines are dropped")
    }

    func testRankingBonusesControlsDeduplicationAndExclusions() {
        let lines: [(ScreenTextSegment.Kind, String)] = [
            (.focused, "draft about ZetaKit"),
            (.heading, "AlphaKit overview"),
            (.body, "BetaKit and AlphaKit and ZETAKIT"),
            (.control, "GammaKit"),
            (.body, "OmegaKit")
        ]
        let result = ScreenTermExtractor.terms(from: collection(lines), excludingKeys: [AppVocabulary.automaticTermKey("omegakit")])
        XCTAssertEqual(result.map(\.text), ["ZetaKit", "AlphaKit", "BetaKit", "GammaKit"])
        XCTAssertEqual(result[0].count, 2, "case-insensitive duplicates merge and keep the first spelling")
        XCTAssertEqual(result[0].score, 3 * 2 + 2, accuracy: 0.001)
        XCTAssertEqual(result[1].score, 3 * 2 + 1, accuracy: 0.001)
        XCTAssertEqual(result[3].score, 1.5, accuracy: 0.001, "controls count at half weight")
        var limits = ScreenContextLimits.standard; limits.asrTerms = 2
        XCTAssertEqual(ScreenTermExtractor.terms(from: collection(lines), excludingKeys: [], limits: limits).count, 2)
    }

    /// Regression guard for the C6 refactor: output recorded from the pre-refactor implementation.
    func testAgentContextOutputMatchesRecordedFixture() throws {
        let fixture = """
        VoiceDraft uses SwiftUI and AppKit with the HUD and ASR engines.
        Call foo_bar then sync_state_now; VoiceDraft ships `WaveAudio` and 「星火计划」 and 『语音草稿』.
        api_key=SuperSecretValue PlainWord
        See https://example.com/DocsPage for HTTP details.
        HUD HUD ASR iOS macOS GPT4 ABCDEFGHIJKLMN Ab
        `星火计划` and 「x」 and `toolong_toolong_toolong_toolong`
        """
        XCTAssertEqual(try ContextVocabulary.terms(in: fixture),
                       ["HUD", "ASR", "VoiceDraft", "WaveAudio", "星火计划", "AppKit", "SwiftUI", "foo_bar", "sync_state_now", "toolong_toolong_toolong_toolong", "语音草稿"])
        XCTAssertEqual(TermExtractor.safeLines("ok\nsee http://x\nBearer abc\nfine"), "ok\nfine")
    }
}

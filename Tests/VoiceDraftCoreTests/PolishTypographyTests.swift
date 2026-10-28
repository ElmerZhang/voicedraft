import XCTest
@testable import VoiceDraftCore

final class PolishTypographyTests: XCTestCase {
    private func typeset(_ text: String, _ terms: [String] = []) -> String {
        PolishTypography.apply(text, protectedTerms: terms)
    }

    func testSpacesCJKAgainstLatinAndDigitsInBothDirections() {
        XCTAssertEqual(typeset("我用API写了3段代码"), "我用 API 写了 3 段代码")
        XCTAssertEqual(typeset("Swift是好语言"), "Swift 是好语言")
        XCTAssertEqual(typeset("版本2发布了v3"), "版本 2 发布了 v3")
        XCTAssertEqual(typeset("한국어ABC"), "한국어 ABC")
        XCTAssertEqual(typeset("カタカナtest"), "カタカナ test")
    }

    func testAlreadySpacedAndPlainTextIsByteIdentical() {
        for text in ["我用 API 写了 3 段代码", "Plain English, no CJK.", "纯中文，没有字母。", "", "  前后空白  ", "我用\tAPI"] {
            XCTAssertEqual(typeset(text), text)
        }
    }

    func testCJKPunctuationAndLatinUnitsAreUntouched() {
        XCTAssertEqual(typeset("（API）《Swift》、OK。"), "（API）《Swift》、OK。")
        XCTAssertEqual(typeset("【iOS】「v2」…OK"), "【iOS】「v2」…OK")
        XCTAssertEqual(typeset("内存20GB够用"), "内存 20GB 够用")
    }

    func testPercentPermilleAndDegreeStayWithTheNumber() {
        XCTAssertEqual(typeset("进度15%完成"), "进度 15% 完成")
        XCTAssertEqual(typeset("浓度3‰左右"), "浓度 3‰ 左右")
        XCTAssertEqual(typeset("气温30°以上"), "气温 30° 以上")
        XCTAssertEqual(typeset("气温30°C以上"), "气温 30°C 以上")
    }

    func testStructuredSpansAreCopiedThrough() {
        XCTAssertEqual(typeset("访问https://例子.com/a中文b看看"), "访问 https://例子.com/a 中文 b 看看")
        XCTAssertEqual(typeset("网址是www.ex2.com。"), "网址是 www.ex2.com。")
        XCTAssertEqual(typeset("发邮件给dev2@ex.com吧"), "发邮件给 dev2@ex.com 吧")
        XCTAssertEqual(typeset("打开~/a2/b3文件"), "打开~/a2/b3 文件")
        XCTAssertEqual(typeset("运行`ls中文2`命令"), "运行`ls中文2`命令")
        XCTAssertEqual(typeset("用``a`中b``写"), "用``a`中b``写")
        XCTAssertEqual(typeset("代码：\n```\n中文abc 123中\n```\n然后A"), "代码：\n```\n中文abc 123中\n```\n然后 A")
        XCTAssertEqual(typeset("见[文档A](https://x.com/路径a)和[b](./文档2)"), "见[文档 A](https://x.com/路径a)和[b](./文档2)")
    }

    func testQuotedTextIsUntouchedWhileSurroundingProseIsSpaced() {
        XCTAssertEqual(typeset("我用API写的，原话是“用API处理3段”"), "我用 API 写的，原话是“用API处理3段”")
        XCTAssertEqual(typeset("他说「用API」和『v2版』和‘a中’和\"b中\"共4次"),
                       "他说「用API」和『v2版』和‘a中’和\"b中\"共 4 次")
    }

    func testProtectedTermsAreUntouchedOnlyWhenListed() {
        XCTAssertEqual(typeset("我在听豆瓣FM", ["豆瓣FM"]), "我在听豆瓣FM")
        XCTAssertEqual(typeset("我在听豆瓣FM"), "我在听豆瓣 FM")
        // Longest first: the longer term wins over its prefix.
        XCTAssertEqual(typeset("用豆瓣FM2听", ["豆瓣", "豆瓣FM2"]), "用豆瓣FM2 听")
        XCTAssertEqual(typeset("用豆瓣FM2听", ["豆瓣"]), "用豆瓣 FM2 听")
        // Case-sensitive: a different case is not the protected term.
        XCTAssertEqual(typeset("我在听豆瓣fm", ["豆瓣FM"]), "我在听豆瓣 fm")
        // The term itself is untouched; its outer edge may still be spaced.
        XCTAssertEqual(typeset("我用Xcode开发", ["Xcode"]), "我用 Xcode 开发")
    }

    func testCasingTable() {
        XCTAssertEqual(typeset("下载这个APP，支持IOS和MACOS"), "下载这个 App，支持 iOS 和 macOS")
        XCTAssertEqual(typeset("iphone, Ipad, github, Gitlab, YOUTUBE, wechat, Chatgpt, LINKEDIN"),
                       "iPhone, iPad, GitHub, GitLab, YouTube, WeChat, ChatGPT, LinkedIn")
        // Lower-case "app" is English; mixed case and longer words are left alone.
        XCTAssertEqual(typeset("the app on MacOS, APPS, iOSX, GitHubs"), "the app on MacOS, APPS, iOSX, GitHubs")
        XCTAssertEqual(typeset("IOS17和IOS"), "iOS17 和 iOS")
        XCTAssertEqual(typeset("下载这个APP", ["APP"]), "下载这个 APP")
        XCTAssertEqual(typeset("见https://github.com/IOS"), "见 https://github.com/IOS")
        XCTAssertEqual(typeset("运行`github`"), "运行`github`")
    }

    func testIdempotentAndNewlinesPreserved() {
        let samples = [
            "我用API写了3段代码\n\n第二段IOS15%完成\r\n第三行",
            "访问https://a.com然后用`code1`和“引用A”\n- 列表A项\n  缩进B",
            "下载APP到iphone，温度30°C",
        ]
        for sample in samples {
            let once = typeset(sample, ["豆瓣FM"])
            XCTAssertEqual(typeset(once, ["豆瓣FM"]), once)
            XCTAssertEqual(once.filter(\.isNewline).count, sample.filter(\.isNewline).count)
        }
        XCTAssertEqual(typeset(samples[0]), "我用 API 写了 3 段代码\n\n第二段 iOS15% 完成\r\n第三行")
    }

    func testFinalizeStripsSingleWordPunctuationThenTypesets() {
        XCTAssertEqual(PolishOutput.finalize("测试。", transcript: "测试", protectedTerms: []), "测试")
        XCTAssertEqual(PolishOutput.finalize("今天测试了API。", transcript: "今天测试了API", protectedTerms: []),
                       "今天测试了 API。")
        XCTAssertEqual(PolishOutput.finalize("IOS。", transcript: "IOS", protectedTerms: []), "iOS")
    }

    func testVocabularyProtectedTerms() {
        var vocabulary = AppVocabulary()
        var first = VocabularyEntry(text: " 豆瓣FM "); first.displayAs = "豆瓣 FM"
        var disabled = VocabularyEntry(text: "APP"); disabled.enabled = false
        vocabulary.entries = [first, VocabularyEntry(text: "豆瓣FM"), disabled, VocabularyEntry(text: "Xcode")]
        XCTAssertEqual(vocabulary.protectedTypographyTerms, ["豆瓣FM", "豆瓣 FM", "Xcode"])
        vocabulary.enabled = false
        XCTAssertEqual(vocabulary.protectedTypographyTerms, [])
    }

    func testRestoresDroppedSentenceFinalMarkOnlyAfterBareEndings() {
        let terms: [String] = []
        XCTAssertEqual(PolishOutput.finalize("这本画册我翻过，没问题", transcript: "这本画册我翻过，没问题。", protectedTerms: terms), "这本画册我翻过，没问题。")
        XCTAssertEqual(PolishOutput.finalize("Ship it on Thursday", transcript: "Ship it on Tues, on Thursday.", protectedTerms: terms), "Ship it on Thursday.")
        XCTAssertEqual(PolishOutput.finalize("这本画册我翻过，没问题。", transcript: "这本画册我翻过，没问题。", protectedTerms: terms), "这本画册我翻过，没问题。")
        XCTAssertEqual(PolishOutput.finalize("他说“好”", transcript: "他说好。", protectedTerms: terms), "他说“好”")
        XCTAssertEqual(PolishOutput.finalize("先查日志", transcript: "先查日志", protectedTerms: terms), "先查日志")
        XCTAssertEqual(PolishOutput.finalize("测试", transcript: "测试。", protectedTerms: terms), "测试")
        XCTAssertEqual(PolishOutput.finalize("看 VoiceDraft", transcript: "看VoiceDraft。", protectedTerms: terms), "看 VoiceDraft。")
    }
}

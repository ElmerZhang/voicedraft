import XCTest
@testable import VoiceDraftCore

final class SingleWordOutputTests: XCTestCase {
    func testSingleWordOutputDropsTerminalPunctuation() {
        let cases: [(transcript: String, output: String, expected: String)] = [
            ("测试。", "测试。", "测试"),
            ("测试", "测试。", "测试"),
            ("确认", "确认", "确认"),
            ("VoiceDraft。", "VoiceDraft.", "VoiceDraft"),
            ("好的。", "好的！", "好的"),
            ("伏一斯", "VoiceDraft。", "VoiceDraft"),
            ("C#", "C#。", "C#"),
            ("Node.js。", "Node.js.", "Node.js"),
            ("50%", "50%。", "50%"),
            ("测试……", "测试……", "测试"),
            ("  测试。\n", "测试。", "测试")
        ]
        for item in cases {
            XCTAssertEqual(SingleWordOutput.finalize(item.output, transcript: item.transcript), item.expected, "\(item)")
        }
    }

    func testOtherInputsAreUnchanged() {
        let longToken = String(repeating: "a", count: 41)
        let cases: [(transcript: String, output: String)] = [
            ("我想先检查一下", "我想先检查一下。"),
            ("hello world", "Hello world."),
            ("测试，确认", "测试，确认。"),
            ("测试", "测试。好的。"),
            ("测试", "。"),
            ("", "。"),
            ("测试\n确认", "测试 确认。"),
            (longToken, longToken + ".")
        ]
        for item in cases {
            XCTAssertEqual(SingleWordOutput.finalize(item.output, transcript: item.transcript), item.output, "\(item)")
        }
    }

    func testSingleWordDetection() {
        XCTAssertTrue(SingleWordOutput.isSingleWord("测试"))
        XCTAssertTrue(SingleWordOutput.isSingleWord("人工智能。"))
        XCTAssertFalse(SingleWordOutput.isSingleWord("人工智能好"))
        XCTAssertTrue(SingleWordOutput.isSingleWord("ありがとう".prefix(4).description))
        XCTAssertFalse(SingleWordOutput.isSingleWord("ありがとう"))
        XCTAssertTrue(SingleWordOutput.isSingleWord("감사해요"))
        XCTAssertFalse(SingleWordOutput.isSingleWord("감사합니다"))
        XCTAssertTrue(SingleWordOutput.isSingleWord(".gitignore"))
        XCTAssertTrue(SingleWordOutput.isSingleWord(String(repeating: "a", count: 40)))
        XCTAssertFalse(SingleWordOutput.isSingleWord(String(repeating: "a", count: 41)))
        XCTAssertFalse(SingleWordOutput.isSingleWord("a,b"))
        XCTAssertFalse(SingleWordOutput.isSingleWord("hello world"))
        XCTAssertFalse(SingleWordOutput.isSingleWord("。"))
        XCTAssertFalse(SingleWordOutput.isSingleWord("   "))
    }

}

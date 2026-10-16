import XCTest
@testable import VoiceDraftCore

final class VocabularyLearningPrefilterTests: XCTestCase {
    private func dictation(_ text: String, after: String? = nil) -> VocabularyLearningSample {
        VocabularyLearningSample(source: .dictation, before: text, after: after ?? text)!
    }

    private func assertSkipped(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(VocabularyLearningPrefilter.shouldClassify(dictation(text)), text, file: file, line: line)
    }

    private func assertClassified(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(VocabularyLearningPrefilter.shouldClassify(dictation(text)), text, file: file, line: line)
    }

    func testPlainDictationsAreSkipped() {
        assertSkipped("明天下午三点开会，记得把材料带上。")
        assertSkipped("Let's meet tomorrow afternoon and bring the slides.")
        assertSkipped("ok 那就这样 cancel 掉")
        assertSkipped("We can talk about it on the 2nd at 3pm.")
    }

    func testLowercaseLatinInChineseIsClassified() {
        assertClassified("我在 warp 里跑了一下")
    }

    func testIdentifiersAndAcronymsAreClassified() {
        assertClassified("Open the VoiceDraft settings and check them.")
        assertClassified("Rename the user_id column before lunch.")
        assertClassified("Check the CRM numbers before lunch.")
    }

    func testQuotedTermIsClassified() {
        assertClassified("请帮我看一下“飞书审批”这个流程")
    }

    func testChineseNameWithTitleIsClassified() {
        assertClassified("明天跟王老师说一声")
    }

    func testBareChineseNameIsClassifiedByNameTagger() {
        // NLTagger name tagging for Chinese is best-effort (verified on macOS 26).
        assertClassified("让张伟看一下这个")
    }

    func testLetterDigitTokenIsClassified() {
        assertClassified("用 qwen3 试试")
        assertClassified("We rented an H100 for the run.")
    }

    func testEnglishTitleCaseNameIsClassified() {
        assertClassified("Ask Sarah Connor to review it")
    }

    func testCorrectionsAreAlwaysClassified() {
        let edited = VocabularyLearningSample(source: .editedDictation, before: "明天开会", after: "明天开大会")!
        XCTAssertTrue(VocabularyLearningPrefilter.shouldClassify(edited))
        let spoken = dictation("明天开会，不对，改成后天开会")
        XCTAssertTrue(spoken.hasSpokenCorrection)
        XCTAssertTrue(VocabularyLearningPrefilter.shouldClassify(spoken))
    }

    func testUncoveredScriptsAreAlwaysClassified() {
        assertClassified("明日の会議に資料を持ってきてください")
        assertClassified("내일 회의에 자료를 가져오세요")
    }

    func testSignalInBeforeAloneIsEnough() {
        let sample = dictation("我在 warp 里跑了一下", after: "我在终端里跑了一下。")
        XCTAssertFalse(VocabularyLearningPrefilter.hasSignal(sample.after))
        XCTAssertTrue(VocabularyLearningPrefilter.shouldClassify(sample))
    }
}

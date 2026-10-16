import XCTest
@testable import VoiceDraftCore

final class UsageMetricsTests: XCTestCase {
    private func entry(_ original: String, duration: Double, result: String = "Generated answer", mode: WritingMode = .polish) -> HistoryEntry {
        HistoryEntry(mode: mode, original: original, result: result, application: "Fixture", duration: duration)
    }

    func testMixedLanguageCountingAndPunctuation() {
        XCTAssertEqual(UsageMetrics.wordCount("你好 VoiceDraft，用 GPT-4 写 don't stop。👩‍💻"), 9)
        XCTAssertEqual(UsageMetrics.wordCount("中文日本語かなカナ"), 9)
        XCTAssertEqual(UsageMetrics.wordCount("café naïve e\u{301}lan １２３"), 4)
        XCTAssertEqual(UsageMetrics.wordCount(" \n 🎉—…！？ "), 0)
        XCTAssertEqual(UsageMetrics.wordCount("'hello' can’t dogs'"), 3)
    }

    func testWeightedSpeedAndEstimatedSavings() {
        var metrics = UsageMetrics()
        metrics.include(entry(Array(repeating: "word", count: 90).joined(separator: " "), duration: 30))
        metrics.include(entry(Array(repeating: "word", count: 30).joined(separator: " "), duration: 90))
        XCTAssertEqual(metrics.words, 120)
        XCTAssertEqual(metrics.duration, 120)
        XCTAssertEqual(metrics.wordsPerMinute, 60) // Weighted total, not a mean of per-take speeds.
        XCTAssertEqual(metrics.estimatedTimeSaved, 40)
    }

    func testTypedTestsInvalidDurationsAndEmptyTranscriptsDoNotInflateMetrics() {
        var metrics = UsageMetrics()
        for duration in [0, -1, Double.nan, Double.infinity] { metrics.include(entry("not speech", duration: duration)) }
        metrics.include(entry("… 🎉", duration: 50))
        XCTAssertEqual(metrics.duration, 0)
        XCTAssertEqual(metrics.words, 0)
        XCTAssertNil(metrics.wordsPerMinute)
        XCTAssertNil(metrics.personalization)
        metrics.include(entry("Hi", duration: 60, result: String(repeating: "long answer ", count: 500), mode: .ask))
        XCTAssertEqual(metrics.words, 1)
        XCTAssertEqual(metrics.wordsPerMinute, 1)
        XCTAssertEqual(metrics.estimatedTimeSaved, 0)
    }

    func testPersonalizationUsesWholeTermsAliasesAndUnionOfOverlaps() {
        var vocabulary = AppVocabulary(words: "New York\nYork City\nSwift\n语音输入")
        vocabulary.entries[2].displayAs = "SwiftUI"
        vocabulary.entries[2].aliases = ["swift ui"]
        var metrics = UsageMetrics()
        metrics.include(entry("NEW York City swiftUI swifter 语音输入", duration: 60), matcher: .init(vocabulary: vocabulary))
        XCTAssertEqual(metrics.words, 9)
        XCTAssertEqual(metrics.personalizedWords, 8)
        XCTAssertEqual(metrics.personalization!, 8.0 / 9, accuracy: 0.0001)
        var partial = UsageMetrics()
        partial.include(entry("New things in York", duration: 10), matcher: .init(vocabulary: vocabulary))
        XCTAssertEqual(partial.personalizedWords, 0) // Phrase requires the full token sequence.
    }

    func testDisabledVocabularyAndWidthNormalization() {
        var vocabulary = AppVocabulary(words: "VoiceDraft\nQwen")
        vocabulary.entries[1].enabled = false
        var metrics = UsageMetrics()
        metrics.include(entry("ＶｏｉｃｅＤｒａｆｔ qwen", duration: 10), matcher: .init(vocabulary: vocabulary))
        XCTAssertEqual(metrics.personalization, 0.5)
        vocabulary.enabled = false
        var disabled = UsageMetrics()
        disabled.include(entry("VoiceDraft", duration: 10), matcher: .init(vocabulary: vocabulary))
        XCTAssertEqual(disabled.personalization, 0)
    }

    func testProgrammingTermPunctuationIsRequiredForPersonalization() {
        let matcher = UsageVocabularyMatcher(vocabulary: AppVocabulary(words: "C++\nC#\nNode.js"))
        var metrics = UsageMetrics()
        metrics.include(entry("C C++ C# Node js Node.js", duration: 20), matcher: matcher)
        XCTAssertEqual(metrics.words, 7)
        XCTAssertEqual(metrics.personalizedWords, 4) // C++, C#, and the two units in Node.js.
    }

    func testSummaryAndCalendarUseSameMetricsAndVocabulary() {
        let history = [entry("VoiceDraft works", duration: 20), entry("typed text", duration: 0)]
        let vocabulary = AppVocabulary(words: "VoiceDraft")
        let summary = UsageSummary(history: history, vocabulary: vocabulary)
        let activity = UsageActivity(history: history, vocabulary: vocabulary)
        XCTAssertEqual(summary.metrics.words, 2)
        XCTAssertEqual(summary.metrics.personalization, 0.5)
        XCTAssertEqual(summary.metrics.words, activity.metrics.words)
        XCTAssertEqual(summary.metrics.duration, activity.metrics.duration)
        XCTAssertEqual(summary.metrics.personalization, activity.metrics.personalization)
    }
}

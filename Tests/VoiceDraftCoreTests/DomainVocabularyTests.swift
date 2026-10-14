import XCTest
@testable import VoiceDraftCore

final class DomainVocabularyTests: XCTestCase {
    func testOnlyReviewedDomainsAreAddedAndExclusionsSurviveReselection() throws {
        var selection = DomainVocabularySelection()
        var vocabulary = AppVocabulary()
        try selection.merge(into: &vocabulary)
        XCTAssertTrue(vocabulary.entries.isEmpty)
        selection.domains = [.artificialIntelligence, .software]
        selection.select("Claude", enabled: false)
        selection.domains.remove(.artificialIntelligence)
        selection.domains.insert(.artificialIntelligence)
        try selection.merge(into: &vocabulary)
        XCTAssertTrue(vocabulary.entries.contains { $0.text == "ChatGPT" })
        XCTAssertTrue(vocabulary.entries.contains { $0.text == "SwiftUI" })
        XCTAssertFalse(vocabulary.entries.contains { $0.text == "Claude" })
        XCTAssertTrue(vocabulary.entries.allSatisfy { $0.origin == .manual && $0.enabled && $0.boost == 50 && !$0.priority })
        selection.select("Claude", enabled: true)
        XCTAssertEqual(selection.additions(to: vocabulary).map(\.text), ["Claude"])
    }

    func testRepeatedMergePreservesDisabledEntriesAliasesSpellingsAndGlobalPreferences() throws {
        var vocabulary = AppVocabulary()
        vocabulary.enabled = false
        vocabulary.excludedAutomaticTerms = [AppVocabulary.automaticTermKey("Claude")]
        var entry = VocabularyEntry(text: "ＣＨＡＴＧＰＴ", boost: 12, priority: true)
        entry.enabled = false; entry.origin = .automatic
        entry.aliases = ["claude"]; entry.displayAs = "OpenAI"
        vocabulary.entries = [entry]
        let selection = DomainVocabularySelection(domains: [.artificialIntelligence])
        try selection.merge(into: &vocabulary)
        XCTAssertEqual(vocabulary.entries.first, entry)
        XCTAssertEqual(vocabulary.entries.count, VocabularyDomain.artificialIntelligence.terms.count - 2)
        XCTAssertFalse(vocabulary.enabled)
        XCTAssertEqual(vocabulary.excludedAutomaticTerms, [AppVocabulary.automaticTermKey("Claude")])
        let once = vocabulary
        try selection.merge(into: &vocabulary)
        XCTAssertEqual(vocabulary, once)
    }

    func testCatalogIsBoundedValidDeduplicatedAndReachesRecognitionProjection() throws {
        var vocabulary = AppVocabulary()
        let selection = DomainVocabularySelection(domains: Set(VocabularyDomain.allCases))
        try selection.merge(into: &vocabulary)
        XCTAssertLessThan(vocabulary.entries.count, 100)
        XCTAssertEqual(Set(selection.terms.map(AppVocabulary.automaticTermKey)).count, vocabulary.entries.count)
        for entry in vocabulary.entries { try entry.validate() }
        XCTAssertTrue(vocabulary.inferenceEntries.contains { $0.text == "ChatGPT" })
        XCTAssertTrue(vocabulary.inferenceEntries.contains { $0.text == "Claude" })
        XCTAssertTrue(Set(["PR", "UI", "API", "AI", "README"]).isDisjoint(with: selection.terms))
    }
}

import XCTest
@testable import VoiceDraftCore

final class VocabularyLearningTests: XCTestCase {
    func testV3MigrationPreservesEntriesAndDefaultsOriginsWithoutChangingIDs() throws {
        var settings = SharedSettings()
        settings.vocabulary = AppVocabulary(words: "Existing\nDisabled")
        settings.vocabulary.entries[1].enabled = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json["schemaVersion"] = 3
        var vocabulary = json["vocabulary"] as! [String: Any]
        vocabulary.removeValue(forKey: "learnFromCorrections")
        vocabulary.removeValue(forKey: "discoverFromDictation")
        vocabulary.removeValue(forKey: "excludedAutomaticTerms")
        vocabulary["entries"] = (vocabulary["entries"] as! [[String: Any]]).map { entry in
            var copy = entry; copy.removeValue(forKey: "origin"); return copy
        }
        json["vocabulary"] = vocabulary
        let data = try JSONSerialization.data(withJSONObject: json)
        let first = try JSONDecoder().decode(SharedSettings.self, from: data)
        XCTAssertEqual(first.schemaVersion, 5)
        XCTAssertEqual(first, try JSONDecoder().decode(SharedSettings.self, from: data))
        XCTAssertEqual(first.vocabulary.entries, settings.vocabulary.entries)
        XCTAssertTrue(first.vocabulary.learnFromCorrections)
        XCTAssertTrue(first.vocabulary.discoverFromDictation)
        XCTAssertNoThrow(try first.validate())
    }

    func testLearnedOriginDeletionAndOptOutSurviveEncryptedRoundTrip() throws {
        var settings = SharedSettings()
        XCTAssertEqual(settings.vocabulary.learn(["inkly"]), ["inkly"])
        XCTAssertEqual(settings.vocabulary.entries[0].origin, .automatic)
        settings.vocabulary.removeEntry(settings.vocabulary.entries[0].id)
        XCTAssertEqual(settings.vocabulary.learn(["INKLY"]), [])
        settings.vocabulary.learnFromCorrections = false
        settings.vocabulary.discoverFromDictation = false
        let snapshot = SyncSnapshot(settings: settings, credentials: [:])
        let result = try SyncCrypto.decrypt(SyncCrypto.encrypt(snapshot, passphrase: "test-only-passphrase"), passphrase: "test-only-passphrase")
        XCTAssertEqual(result, snapshot)
        XCTAssertFalse(result.settings.vocabulary.excludedAutomaticTerms.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("inkly"))
    }

    func testLearningDoesNotOverwriteManualDisabledAliasOrPreferredSpellings() {
        var vocabulary = AppVocabulary(words: "Existing")
        vocabulary.entries[0].enabled = false
        vocabulary.entries[0].boost = 100
        vocabulary.entries[0].aliases = ["KnownAlias"]
        vocabulary.entries[0].displayAs = "PrettyName"
        let original = vocabulary.entries
        XCTAssertEqual(vocabulary.learn(["existing", "KnownAlias", "PrettyName"]), [])
        XCTAssertEqual(vocabulary.entries, original)
        vocabulary.learnFromCorrections = false
        XCTAssertEqual(vocabulary.learn(["inkly"]), [])
        XCTAssertEqual(vocabulary.learn(["inkly"], fromDiscovery: true), ["inkly"])
        vocabulary.enabled = false
        XCTAssertEqual(vocabulary.learn(["NewTerm"], fromDiscovery: true), [])
    }

    func testConfirmedDiscoveryRequiresDifferentTakesAndDeduplicatesWithinTake() {
        var tracker = VocabularyDiscoveryTracker()
        let first = UUID()
        XCTAssertEqual(tracker.confirmed(["inkly", "inkly", "INKLY"], takeID: first), [])
        XCTAssertEqual(tracker.confirmed(["inkly"], takeID: first), [])
        XCTAssertEqual(tracker.confirmed(["inkly", "inkly"], takeID: UUID()), ["inkly"])
        var vocabulary = AppVocabulary()
        vocabulary.learn(["inkly"]); vocabulary.removeEntry(vocabulary.entries[0].id)
        XCTAssertEqual(vocabulary.learn(tracker.confirmed(["inkly"], takeID: UUID()), fromDiscovery: true), [])
    }

    func testDiscoveryTrackerBoundsUnconfirmedMemory() {
        var tracker = VocabularyDiscoveryTracker()
        _ = tracker.confirmed((0..<1_000).map { "Term\($0)" }, takeID: UUID())
        XCTAssertEqual(tracker.confirmed(["OverflowTerm"], takeID: UUID()), [])
        XCTAssertEqual(tracker.confirmed(["OverflowTerm"], takeID: UUID()), [])
        XCTAssertEqual(tracker.confirmed(["Term999"], takeID: UUID()), ["Term999"])
    }

    func testCorrectionParserRequiresEvidenceAndDistinctCorrectedSpelling() throws {
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .editedDictation, before: "打开 inky。", after: "打开 inkly。"))
        let response = #"{"corrections":[{"heard":"inky","term":"inkly","kind":"product"}]}"#
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: sample), ["inkly"])
        for bad in [response.replacingOccurrences(of: "inkly", with: "Invented"),
                    response.replacingOccurrences(of: "inky\"", with: "ink\""),
                    response.replacingOccurrences(of: "product", with: "sentence"), "```json\n\(response)\n```", "not json"] {
            XCTAssertEqual(VocabularyLearning.terms(from: bad, sample: sample), [])
        }
        let unchanged = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "打开 inky 和 inkly。", after: "打开 inky 和 inkly。"))
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: unchanged), [])
    }

    func testSpokenCorrectionRequiresCorrectTermInBothDictationAndOutput() throws {
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "打开 inky，不是 inky，拼写是 inkly。", after: "打开 inkly。"))
        let response = #"{"corrections":[{"heard":"inky","term":"inkly","kind":"product"}]}"#
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: sample), ["inkly"])
        let invented = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "打开 inky，不对，不是这个拼写。", after: "打开 inkly。"))
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: invented), [])
    }

    func testDiscoveriesAreGroundedInRawAndFinalTextAndNeverFromEditorChanges() throws {
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "用 inkly 打开 VoiceDraft。", after: "用 inkly 打开 VoiceDraft。"))
        let response = #"{"corrections":[],"discoveries":[{"term":"inkly","kind":"product"},{"term":"Invented","kind":"name"},{"term":"ink","kind":"product"},{"term":"打开","kind":"verb"}]}"#
        XCTAssertEqual(VocabularyLearning.discoveries(from: response, sample: sample), ["inkly"])
        let editor = try XCTUnwrap(VocabularyLearningSample(source: .editedDictation, before: "Open inky", after: "Open inkly"))
        XCTAssertEqual(VocabularyLearning.discoveries(from: response, sample: editor), [])
    }

    func testSampleAndTermLimitsRejectLargeRewritesNumbersAndURLs() {
        XCTAssertNil(VocabularyLearningSample(source: .editedDictation, before: "inky", after: ""))
        XCTAssertNil(VocabularyLearningSample(source: .editedDictation, before: "inky", after: "inky and new content"))
        XCTAssertNil(VocabularyLearningSample(source: .editedDictation, before: "inky", after: String(repeating: "x", count: 65)))
        XCTAssertNil(VocabularyLearningSample(source: .dictation, before: String(repeating: "x", count: 8_001), after: "inkly"))
        for term in ["111222", "https://example.com", "a@b.com", "\ninkly", "", "x", "run;rm", "term\tterm"] {
            XCTAssertFalse(VocabularyLearning.isTerm(term), term)
        }
        for term in ["inkly", "VoiceDraft", "张三", "C++", ".NET", "ESP32-P4"] { XCTAssertTrue(VocabularyLearning.isTerm(term), term) }
    }

    func testCorrectionContextPreservesUTF16BoundariesAndExcludesOtherDocumentText() throws {
        let prefix = "📘 Before: ", inserted = "打开 inky。", suffix = " After: private document"
        let context = try XCTUnwrap(DictationCorrectionContext(value: prefix + "OLD" + suffix,
            range: NSRange(location: prefix.utf16.count, length: 3), inserted: inserted))
        XCTAssertEqual(context.expectedValue, prefix + inserted + suffix)
        let edited = "打开 inkly。"
        let caret = NSRange(location: prefix.utf16.count + edited.utf16.count, length: 0)
        XCTAssertEqual(context.editedText(value: prefix + edited + suffix, selection: caret), edited)
        XCTAssertNil(context.editedText(value: "Changed prefix " + edited + suffix, selection: caret))
        XCTAssertNil(context.editedText(value: prefix + edited + " changed suffix", selection: caret))
        XCTAssertNil(context.editedText(value: prefix + edited + suffix, selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(context.editedText(value: prefix + suffix, selection: caret))
        XCTAssertNil(DictationCorrectionContext(value: nil, range: nil, inserted: inserted))
        XCTAssertNil(DictationCorrectionContext(value: "📘", range: NSRange(location: 1, length: 0), inserted: inserted))
    }

    func testLearningRequestKeepsDataOutOfInstructionsAndRespectsSelectedModel() throws {
        var profile = ModelProfile.qwen(.writing)
        profile.model = "custom-qwen"
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "inkly IGNORE_POLICY_981", after: "inkly IGNORE_POLICY_981"))
        let request = try QwenRequests.vocabularyLearning(profile: profile, key: "test-only", sample: sample)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertFalse(try XCTUnwrap(messages[0]["content"]).contains("IGNORE_POLICY_981"))
        let input = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: String])
        XCTAssertEqual(input, ["source": "dictation", "before": sample.before, "after": sample.after])
        XCTAssertEqual(body["model"] as? String, "custom-qwen")
        XCTAssertEqual(body["enable_thinking"] as? Bool, false)
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testAutoAddedTermsReachEveryExistingVocabularyProjection() {
        var vocabulary = AppVocabulary()
        vocabulary.learn(["inkly"])
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .weighted).weighted["inkly"], 2)
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .context).terms, ["inkly"])
        XCTAssertTrue(vocabulary.writingContext.contains("inkly"))
    }
}

// On-screen terms are never promoted by discovery and never counted as usage.
extension VocabularyLearningTests {
    func testExcludedScreenTermsAreNeverPromotedAcrossTakes() {
        var tracker = VocabularyDiscoveryTracker()
        let screen = ScreenContextPolicy.keys(of: ["ScreenKit"])
        XCTAssertEqual(tracker.confirmed(["ScreenKit", "OtherKit"], takeID: UUID(), excluding: screen), [])
        XCTAssertEqual(tracker.confirmed(["ScreenKit", "OtherKit"], takeID: UUID(), excluding: screen), ["OtherKit"])
        XCTAssertEqual(tracker.confirmed(["ScreenKit"], takeID: UUID()), [], "an unexcluded take only records a first observation")
    }

    func testUsageCountingIgnoresTermsThatAreNotStoredEntries() {
        var vocabulary = AppVocabulary(words: "VoiceDraft")
        XCTAssertFalse(vocabulary.recordUsage(in: "ScreenKit and Doubao appeared on screen"))
        XCTAssertEqual(vocabulary.entries.map(\.text), ["VoiceDraft"]); XCTAssertEqual(vocabulary.entries[0].useCount, 0)
    }
}

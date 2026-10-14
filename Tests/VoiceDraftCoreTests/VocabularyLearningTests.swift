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
        XCTAssertEqual(settings.vocabulary.learn(["herdr"]), ["herdr"])
        XCTAssertEqual(settings.vocabulary.entries[0].origin, .automatic)
        settings.vocabulary.removeEntry(settings.vocabulary.entries[0].id)
        XCTAssertEqual(settings.vocabulary.learn(["HERDR"]), [])
        settings.vocabulary.learnFromCorrections = false
        settings.vocabulary.discoverFromDictation = false
        let snapshot = SyncSnapshot(settings: settings, credentials: [:])
        let result = try SyncCrypto.decrypt(SyncCrypto.encrypt(snapshot, passphrase: "test-only-passphrase"), passphrase: "test-only-passphrase")
        XCTAssertEqual(result, snapshot)
        XCTAssertFalse(result.settings.vocabulary.excludedAutomaticTerms.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("herdr"))
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
        XCTAssertEqual(vocabulary.learn(["herdr"]), [])
        XCTAssertEqual(vocabulary.learn(["herdr"], fromDiscovery: true), ["herdr"])
        vocabulary.enabled = false
        XCTAssertEqual(vocabulary.learn(["NewTerm"], fromDiscovery: true), [])
    }

    func testConfirmedDiscoveryRequiresDifferentTakesAndDeduplicatesWithinTake() {
        var tracker = VocabularyDiscoveryTracker()
        let first = UUID()
        XCTAssertEqual(tracker.confirmed(["herdr", "herdr", "HERDR"], takeID: first), [])
        XCTAssertEqual(tracker.confirmed(["herdr"], takeID: first), [])
        XCTAssertEqual(tracker.confirmed(["herdr", "herdr"], takeID: UUID()), ["herdr"])
        var vocabulary = AppVocabulary()
        vocabulary.learn(["herdr"]); vocabulary.removeEntry(vocabulary.entries[0].id)
        XCTAssertEqual(vocabulary.learn(tracker.confirmed(["herdr"], takeID: UUID()), fromDiscovery: true), [])
    }

    func testDiscoveryTrackerBoundsUnconfirmedMemory() {
        var tracker = VocabularyDiscoveryTracker()
        _ = tracker.confirmed((0..<1_000).map { "Term\($0)" }, takeID: UUID())
        XCTAssertEqual(tracker.confirmed(["OverflowTerm"], takeID: UUID()), [])
        XCTAssertEqual(tracker.confirmed(["OverflowTerm"], takeID: UUID()), [])
        XCTAssertEqual(tracker.confirmed(["Term999"], takeID: UUID()), ["Term999"])
    }

    func testCorrectionParserRequiresEvidenceAndDistinctCorrectedSpelling() throws {
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .editedDictation, before: "打开 herd。", after: "打开 herdr。"))
        let response = #"{"corrections":[{"heard":"herd","term":"herdr","kind":"product"}]}"#
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: sample), ["herdr"])
        for bad in [response.replacingOccurrences(of: "herdr", with: "Invented"),
                    response.replacingOccurrences(of: "herd\"", with: "her\""),
                    response.replacingOccurrences(of: "product", with: "sentence"), "```json\n\(response)\n```", "not json"] {
            XCTAssertEqual(VocabularyLearning.terms(from: bad, sample: sample), [])
        }
        let unchanged = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "打开 herd 和 herdr。", after: "打开 herd 和 herdr。"))
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: unchanged), [])
    }

    func testSpokenCorrectionRequiresCorrectTermInBothDictationAndOutput() throws {
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "打开 herd，不是 herd，拼写是 herdr。", after: "打开 herdr。"))
        let response = #"{"corrections":[{"heard":"herd","term":"herdr","kind":"product"}]}"#
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: sample), ["herdr"])
        let invented = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "打开 herd，不对，不是这个拼写。", after: "打开 herdr。"))
        XCTAssertEqual(VocabularyLearning.terms(from: response, sample: invented), [])
    }

    func testDiscoveriesAreGroundedInRawAndFinalTextAndNeverFromEditorChanges() throws {
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "用 herdr 打开 VoiceDraft。", after: "用 herdr 打开 VoiceDraft。"))
        let response = #"{"corrections":[],"discoveries":[{"term":"herdr","kind":"product"},{"term":"Invented","kind":"name"},{"term":"her","kind":"product"},{"term":"打开","kind":"verb"}]}"#
        XCTAssertEqual(VocabularyLearning.discoveries(from: response, sample: sample), ["herdr"])
        let editor = try XCTUnwrap(VocabularyLearningSample(source: .editedDictation, before: "Open herd", after: "Open herdr"))
        XCTAssertEqual(VocabularyLearning.discoveries(from: response, sample: editor), [])
    }

    func testSampleAndTermLimitsRejectLargeRewritesNumbersAndURLs() {
        XCTAssertNil(VocabularyLearningSample(source: .editedDictation, before: "herd", after: ""))
        XCTAssertNil(VocabularyLearningSample(source: .editedDictation, before: "herd", after: "herd and new content"))
        XCTAssertNil(VocabularyLearningSample(source: .editedDictation, before: "herd", after: String(repeating: "x", count: 65)))
        XCTAssertNil(VocabularyLearningSample(source: .dictation, before: String(repeating: "x", count: 8_001), after: "herdr"))
        for term in ["111222", "https://example.com", "a@b.com", "\nherdr", "", "x", "run;rm", "term\tterm"] {
            XCTAssertFalse(VocabularyLearning.isTerm(term), term)
        }
        for term in ["herdr", "VoiceDraft", "张三", "C++", ".NET", "ESP32-P4"] { XCTAssertTrue(VocabularyLearning.isTerm(term), term) }
    }

    func testCorrectionContextPreservesUTF16BoundariesAndExcludesOtherDocumentText() throws {
        let prefix = "📘 Before: ", inserted = "打开 herd。", suffix = " After: private document"
        let context = try XCTUnwrap(DictationCorrectionContext(value: prefix + "OLD" + suffix,
            range: NSRange(location: prefix.utf16.count, length: 3), inserted: inserted))
        XCTAssertEqual(context.expectedValue, prefix + inserted + suffix)
        let edited = "打开 herdr。"
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
        let sample = try XCTUnwrap(VocabularyLearningSample(source: .dictation, before: "herdr IGNORE_POLICY_981", after: "herdr IGNORE_POLICY_981"))
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
        vocabulary.learn(["herdr"])
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .weighted).weighted["herdr"], 2)
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .context).terms, ["herdr"])
        XCTAssertTrue(vocabulary.writingContext.contains("herdr"))
    }
}

import XCTest
@testable import VoiceDraftCore

final class VocabularyTests: XCTestCase {
    func testOneGlobalVocabularyProjectsWithoutChangingItsSource() throws {
        var source = AppVocabulary()
        var rich = VocabularyEntry(text: "VoiceDraft", boost: 75, priority: true)
        rich.language = "en-US"; rich.displayAs = "VoiceDraft™"
        rich.aliases = ["voice draft"]; rich.pronunciation = "vɔɪs dræft"
        source.entries = [rich, .init(text: "百炼", boost: 25)]
        let before = source
        let weighted = VocabularyProjection.make(source, for: .weighted)
        XCTAssertEqual(weighted.weighted, ["VoiceDraft": 50, "百炼": 2])
        XCTAssertTrue(weighted.hasUnsupportedMetadata)
        let context = VocabularyProjection.make(source, for: .context)
        XCTAssertEqual(context.context, "VoiceDraft, 百炼")
        XCTAssertTrue(context.weighted.isEmpty)
        XCTAssertFalse(source.writingContext.contains("vɔɪs"))
        XCTAssertTrue(source.writingContext.contains("voice draft"))
        XCTAssertEqual(source, before)
        var settings = SharedSettings(); settings.vocabulary = source
        settings.profiles[0].selectModel("qwen-audio-3.1-asr-flash-message")
        settings.profiles[0].selectModel("qwen3-asr-flash")
        XCTAssertEqual(settings.vocabulary, before)
        XCTAssertEqual(try JSONDecoder().decode(SharedSettings.self, from: JSONEncoder().encode(settings)), settings)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(json.contains("speechOptions")); XCTAssertFalse(json.contains("interfaceLanguage"))
        XCTAssertFalse(json.contains("inputDevice"))
    }

    func testAdapterLimitsOmitWholeTermsAndDowngradeWithoutMutatingSource() throws {
        var source = AppVocabulary()
        source.entries = (1...51).map { .init(text: "Term \($0)", priority: true) }
        source.entries += (52...2001).map { .init(text: "Term \($0)") }
        source.entries += [.init(text: String(repeating: "中", count: 16)), .init(text: "one two three four five six seven eight")]
        let before = source
        let projection = VocabularyProjection.make(source, for: .weighted)
        XCTAssertEqual(projection.weighted.count, 2000)
        XCTAssertEqual(projection.weighted.values.filter { $0 == 50 }.count, 50)
        XCTAssertEqual(projection.downgradedPriority, 1)
        XCTAssertEqual(projection.weighted["Term 51"], 5)
        XCTAssertEqual(projection.omitted, 3)
        XCTAssertNil(projection.weighted["Term 2001"])
        XCTAssertEqual(source, before)
        XCTAssertEqual(VocabularyProjection.make(source, for: .context).terms.count, 300)
    }

    func testDuplicatesDisabledEntriesAndGlobalToggle() {
        var source = AppVocabulary()
        source.entries = [.init(text: "Qwen", boost: 0), .init(text: " Qwen ", boost: 100), .init(text: "Disabled", priority: true)]
        source.entries[2].enabled = false
        XCTAssertEqual(VocabularyProjection.make(source, for: .weighted).weighted, ["Qwen": 5])
        source.enabled = false
        for capability: VocabularyCapability in [.context, .weighted, .none] {
            XCTAssertTrue(VocabularyProjection.make(source, for: capability).terms.isEmpty)
        }
        XCTAssertEqual(source.writingContext, "")
        XCTAssertEqual(source.entries.count, 3)
    }

    func testGlobalValidationRejectsHiddenLinesAndInvalidWeights() throws {
        for text in ["", "\n", "Visible\nHidden", "Visible\u{2028}Hidden"] {
            XCTAssertThrowsError(try VocabularyEntry(text: text).validate())
        }
        for weight in [-1, 101] { XCTAssertThrowsError(try VocabularyEntry(text: "Valid", boost: weight).validate()) }
        var entry = VocabularyEntry(text: "Valid"); entry.language = "not a language"
        XCTAssertThrowsError(try entry.validate())
        entry.language = "zh-Hant-TW"; entry.aliases = ["alternate"]
        XCTAssertNoThrow(try entry.validate())
    }

    func testMigrationPreservesLongLegacyTermsAndNormalizesTabs() throws {
        let settings = SharedSettings()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object["schemaVersion"] = 2
        let longTerm = String(repeating: "x", count: 29_000)
        object["hotwords"] = "Legacy\tphrase\n" + longTerm
        object.removeValue(forKey: "vocabulary")
        var profiles = object["profiles"] as! [[String: Any]]
        profiles[0]["speechOptions"] = ["useVocabulary": true, "defaultWeight": 3,
            "hotwords": [["id": UUID().uuidString, "text": "Legacy\tphrase", "weight": 5]]]
        object["profiles"] = profiles
        let migrated = try JSONDecoder().decode(SharedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNoThrow(try migrated.validate())
        XCTAssertEqual(migrated.vocabulary.entries.map(\.text), ["Legacy phrase", longTerm])
        XCTAssertEqual(migrated.vocabulary.entries[0].boost, 100)
        XCTAssertEqual(VocabularyProjection.make(migrated.vocabulary, for: .context).terms, ["Legacy phrase"])
        XCTAssertEqual(migrated.vocabulary.entries[1].text, longTerm)
    }

    func testV2MigrationCollectsAllModelsAndActiveProfileWinsWithStableIDs() throws {
        var settings = SharedSettings()
        let other = ModelProfile.qwen(.speech); settings.profiles.append(other)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object["schemaVersion"] = 2; object["hotwords"] = "Qwen\nVoiceDraft\nQwen"
        object.removeValue(forKey: "vocabulary")
        var profiles = object["profiles"] as! [[String: Any]]
        func oldWord(_ text: String, _ weight: Int) -> [String: Any] { ["id": UUID().uuidString, "text": text, "weight": weight] }
        profiles[0]["speechOptions"] = ["useVocabulary": true, "defaultWeight": 2,
                                       "hotwords": [oldWord("VoiceDraft", 50), oldWord("Active", 4)]]
        profiles[0]["extraJSON"] = #"{"vocabulary_id":"old-list","asr_options":{"enable_itn":false}}"#
        profiles[2]["speechOptions"] = ["useVocabulary": false, "defaultWeight": 3,
                                       "hotwords": [oldWord("VoiceDraft", 1), oldWord("Inactive", 5)]]
        object["profiles"] = profiles
        let data = try JSONSerialization.data(withJSONObject: object)
        let first = try JSONDecoder().decode(SharedSettings.self, from: data)
        let second = try JSONDecoder().decode(SharedSettings.self, from: data)
        XCTAssertEqual(first, second, "Repeated decode must not look like a sync conflict")
        XCTAssertEqual(first.vocabulary.entries.map(\.text), ["Qwen", "VoiceDraft", "Inactive", "Active"])
        XCTAssertEqual(first.vocabulary.entries[0].boost, 25)
        XCTAssertTrue(first.vocabulary.entries[1].priority)
        XCTAssertFalse(first.vocabulary.entries[2].enabled)
        XCTAssertEqual(first.vocabulary.legacyReferences.first?.resourceID, "old-list")
        XCTAssertFalse(first.profiles[0].extraJSON.contains("vocabulary_id"))
        XCTAssertEqual(first.profiles.map(\.id), settings.profiles.map(\.id))
        let roundTrip = try JSONDecoder().decode(SharedSettings.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(roundTrip, first)
        let snapshot = SyncSnapshot(settings: first, credentials: [settings.speechID.uuidString: "test-only-key"])
        XCTAssertEqual(try SyncCrypto.decrypt(SyncCrypto.encrypt(snapshot, passphrase: "test-passphrase-only"), passphrase: "test-passphrase-only"), snapshot)
    }
}

// On-screen terms append after vocabulary in the leftover budget only.
extension VocabularyTests {
    func testScreenTermsAppendAfterVocabularyWithoutChangingVocabularyProjection() {
        var vocabulary = AppVocabulary(words: "A1Kit\nB2Kit")
        vocabulary.entries[0].priority = true
        for capability in [VocabularyCapability.none, .context, .weighted] {
            let base = VocabularyProjection.make(vocabulary, for: capability)
            XCTAssertEqual(VocabularyProjection.make(vocabulary, for: capability, screenTerms: []), base)
            let mixed = VocabularyProjection.make(vocabulary, for: capability, screenTerms: ["ScreenOne", "a1kit", " ", "line\nbreak", "ScreenTwo"])
            XCTAssertEqual(mixed.omitted, base.omitted); XCTAssertEqual(mixed.shadowedAutomatic, base.shadowedAutomatic)
            XCTAssertEqual(mixed.downgradedPriority, base.downgradedPriority)
            XCTAssertEqual(Array(mixed.terms.prefix(base.terms.count)), base.terms)
            switch capability {
            case .none:
                XCTAssertEqual(mixed.screenTerms, []); XCTAssertEqual(mixed.screenOmitted, 2)
            case .context:
                XCTAssertEqual(mixed.terms, ["A1Kit", "B2Kit", "ScreenOne", "ScreenTwo"])
                XCTAssertEqual(mixed.context, "A1Kit, B2Kit, ScreenOne, ScreenTwo")
            case .weighted:
                XCTAssertEqual(mixed.weighted, ["A1Kit": 50, "B2Kit": 3, "ScreenOne": 1, "ScreenTwo": 1])
                XCTAssertEqual(mixed.screenTerms, ["ScreenOne", "ScreenTwo"])
            }
        }
        vocabulary.enabled = false
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .context, screenTerms: ["ScreenOne"]), VocabularyProjection())
    }

    func testScreenTermsNeverDisplaceVocabularyAndCountWhatDidNotFit() {
        let full = AppVocabulary(words: (0..<300).map { "Full\($0)" }.joined(separator: "\n"))
        let context = VocabularyProjection.make(full, for: .context, screenTerms: ["ScreenOne", "ScreenTwo"])
        XCTAssertEqual(context.terms.count, 300); XCTAssertEqual(context.screenTerms, []); XCTAssertEqual(context.screenOmitted, 2)
        XCTAssertEqual(context.omitted, 0)
        // One long term uses 5,992 of 6,000 bytes: room for "Fits" (6 bytes) and then nothing else.
        let long = AppVocabulary(words: String(repeating: "x", count: 5_990))
        let bytes = VocabularyProjection.make(long, for: .context, screenTerms: ["TooLongForRoom", "Fits", "Ok"])
        XCTAssertEqual(bytes.screenTerms, ["Fits"]); XCTAssertEqual(bytes.screenOmitted, 2)
        let weighted = VocabularyProjection.make(AppVocabulary(), for: .weighted,
            screenTerms: ["one two three four five six seven eight", "十六个汉字十六个汉字十六个汉字十", "短语"])
        XCTAssertEqual(weighted.weighted, ["短语": 1]); XCTAssertEqual(weighted.screenOmitted, 2)
    }
}

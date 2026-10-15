import XCTest
@testable import VoiceDraftCore

final class VocabularyRecognitionTests: XCTestCase {
    func testAutomaticTermsStayEnabledAtLowWeightEvenAfterRepeatedUse() throws {
        var manual = VocabularyEntry(text: "NoryOS")
        var automatic = VocabularyEntry(text: "NorOS", boost: 100, priority: true)
        automatic.origin = .automatic; automatic.useCount = 1000
        var vocabulary = AppVocabulary(); vocabulary.entries = [automatic, manual]
        let before = vocabulary
        let projection = VocabularyProjection.make(vocabulary, for: .weighted)
        XCTAssertEqual(projection.weighted, ["NoryOS": 3, "NorOS": 2])
        XCTAssertEqual(projection.terms.first, "NoryOS")
        XCTAssertEqual(projection.downgradedPriority, 0)
        XCTAssertEqual(vocabulary, before, "Weight reduction must not rewrite the user's stored terms")
        var profile = ModelProfile.qwen(.speech); profile.selectModel("qwen-audio-3.1-asr-flash-message")
        let request = try MessageASRRequests.start(profile: profile, vocabulary: vocabulary, taskID: "fixture", live: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [String: Any])
        let context = try XCTUnwrap(input["context"] as? [[String: Any]])
        let content = try XCTUnwrap(context[0]["content"] as? [[String: String]])
        XCTAssertEqual(content[0]["text"], "NoryOS", "Do not reinforce an automatic spelling as unweighted domain context")
        manual.priority = true; vocabulary.entries[1] = manual
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .weighted).weighted["NoryOS"], 50)
        vocabulary.entries[0].origin = .manual
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .weighted).weighted["NorOS"], 50, "Explicit manual confirmation restores configured strength")
    }

    func testNewDiscoveriesRemainAutomaticAndUseLowRecognitionWeight() {
        var vocabulary = AppVocabulary(words: "ManualBrand")
        XCTAssertEqual(vocabulary.learn(["DiscoveredBrand"], fromDiscovery: true), ["DiscoveredBrand"])
        XCTAssertTrue(vocabulary.entries.last!.enabled)
        XCTAssertEqual(vocabulary.entries.last!.origin, .automatic)
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .weighted).weighted["DiscoveredBrand"], 2)
    }

    func testWritingReceivesSourcePrecedenceAndKeepsRawRecognitionAsData() throws {
        var settings = SharedSettings(); settings.vocabulary = AppVocabulary(words: "NoryOS")
        _ = settings.vocabulary.learn(["NorOS"], fromDiscovery: true)
        let raw = "我们的产品是 NorOS。"
        let request = try QwenRequests.writing(profile: .qwen(.writing), key: "synthetic", text: raw, mode: .polish, settings: settings)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertTrue(system.contains("Manual entries are user-confirmed"))
        XCTAssertTrue(system.contains("Automatic entries are low-confidence"))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages.last?["content"]).utf8)) as? [String: String])
        XCTAssertEqual(input["transcript"], raw, "The source transcript must not be changed by fuzzy replacements")
        let hints = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settings.vocabulary.writingContext.utf8)) as? [[String: String]])
        XCTAssertEqual(hints.map { $0["source"] }, ["manual", "automatic"])
    }

    func testManualSpellingShadowsAutomaticAliasWithoutMutatingDictionary() throws {
        var manual = VocabularyEntry(text: "NoryOS")
        manual.aliases = ["NorOS"]
        var automatic = VocabularyEntry(text: "NorOS", boost: 100, priority: true)
        automatic.origin = .automatic; automatic.useCount = 500
        var vocabulary = AppVocabulary(); vocabulary.entries = [automatic, manual]
        let before = vocabulary
        let projection = VocabularyProjection.make(vocabulary, for: .weighted)
        XCTAssertEqual(projection.weighted, ["NoryOS": 3])
        XCTAssertEqual(projection.shadowedAutomatic, 1)
        XCTAssertEqual(projection.omitted, 0)
        let hints = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(vocabulary.writingContext.utf8)) as? [[String: String]])
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints[0]["term"], "NoryOS")
        XCTAssertEqual(hints[0]["aliases"], "NorOS")
        XCTAssertEqual(hints[0]["source"], "manual")
        XCTAssertEqual(vocabulary, before)
    }

    func testManualTermsGetBudgetBeforeFrequentAutomaticallyLearnedTerms() throws {
        var vocabulary = AppVocabulary()
        vocabulary.entries = (0..<305).map {
            var entry = VocabularyEntry(text: "Observed\($0)", boost: 100, priority: true)
            entry.origin = .automatic; entry.useCount = 1000; return entry
        }
        vocabulary.entries.append(.init(text: "UserBrand"))
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .context).terms.first, "UserBrand")
        let hints = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(vocabulary.writingContext.utf8)) as? [[String: String]])
        XCTAssertEqual(hints.count, 300)
        XCTAssertEqual(hints.first?["term"], "UserBrand")
    }

    func testMessageASRSendsBoundedWholeTermContextAndRespectsDisablement() throws {
        var profile = ModelProfile.qwen(.speech); profile.selectModel("qwen-audio-3.1-asr-flash-message")
        var vocabulary = AppVocabulary(words: "NoryOS\n" + String(repeating: "a", count: 401) + "\n领域名称")
        vocabulary.entries += (0..<100).map { .init(text: "FixtureTerm\($0)") }
        func payload(_ vocabulary: AppVocabulary) throws -> [String: Any] {
            let request = try MessageASRRequests.start(profile: profile, vocabulary: vocabulary, taskID: "synthetic", live: true)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
            return try XCTUnwrap(root["payload"] as? [String: Any])
        }
        let body = try payload(vocabulary)
        let input = try XCTUnwrap(body["input"] as? [String: Any])
        let context = try XCTUnwrap(input["context"] as? [[String: Any]])
        XCTAssertEqual(context.count, 1); XCTAssertEqual(context[0]["role"] as? String, "user")
        let content = try XCTUnwrap(context[0]["content"] as? [[String: String]])
        XCTAssertEqual(content[0]["type"], "input_text")
        let text = try XCTUnwrap(content[0]["text"])
        XCTAssertTrue(text.hasPrefix("NoryOS, 领域名称"))
        XCTAssertLessThanOrEqual(text.unicodeScalars.count, 400)
        XCTAssertTrue(text.components(separatedBy: ", ").allSatisfy { term in vocabulary.entries.contains { $0.text == term } })
        let parameters = try XCTUnwrap(body["parameters"] as? [String: Any])
        XCTAssertEqual((parameters["vocabulary"] as? [String: Int])?["NoryOS"], 3)
        vocabulary.enabled = false
        let disabled = try payload(vocabulary)
        XCTAssertTrue((disabled["input"] as? [String: Any])?.isEmpty == true)
        XCTAssertNil((disabled["parameters"] as? [String: Any])?["vocabulary"])
    }
}

// On-screen terms for the Whisper, Google, Qwen chat and Qwen Audio HTTP adapters.
extension VocabularyRecognitionTests {
    func testWhisperPromptAppendsScreenTermsAndCutsOnlyAtWholeTerms() throws {
        let wav = WaveAudio.encode(Data(repeating: 0, count: 3200))
        let whisper = ModelProfile(name: "Fixture", role: .speech, endpoint: "https://fixture.invalid/v1/audio/transcriptions", model: "custom-whisper", adapter: .whisper)
        func prompt(_ vocabulary: AppVocabulary, _ screen: [String]) throws -> String {
            let body = String(decoding: try XCTUnwrap(WhisperRequests.speech(profile: whisper, key: "synthetic-key", wav: wav, vocabulary: vocabulary,
                                                                             boundary: "fixture", screenTerms: screen).httpBody), as: UTF8.self)
            guard let start = body.range(of: "name=\"prompt\"\r\n\r\n") else { return "" }
            return String(body[start.upperBound...].prefix { $0 != "\r\n" })
        }
        XCTAssertEqual(try prompt(AppVocabulary(words: "VoiceDraft"), ["ScreenKit"]), "VoiceDraft, ScreenKit")
        let terms = (0..<20).map { "Term\($0)" + String(repeating: "x", count: 95) }
        let cut = try prompt(AppVocabulary(words: terms.joined(separator: "\n")), ["ScreenKit"])
        XCTAssertLessThanOrEqual(cut.count, 1_800)
        XCTAssertTrue(cut.components(separatedBy: ", ").allSatisfy(terms.contains), "no partial term")
        XCTAssertEqual(WhisperRequests.promptTerms(["abc", "defg"], limit: 8), "abc")
    }

    func testGoogleQwenChatAndAudioHTTPReceiveScreenTermsAfterVocabulary() throws {
        let google = ModelProfile(name: "Google", role: .speech, endpoint: "https://speech.googleapis.com/v2/projects/test/locations/global/recognizers/_:recognize", model: "chirp_3", extraJSON: #"{"languageCodes":["en-US"]}"#, adapter: .googleSpeech)
        let request = try GoogleSpeech.request(profile: google, token: "synthetic-token", pcm: Data(repeating: 0, count: 3200),
                                               vocabulary: AppVocabulary(words: "VoiceDraft"), screenTerms: ["ScreenKit"])
        let root = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        let phrases = (((root["config"] as? [String: Any])?["adaptation"] as? [String: Any])?["phraseSets"] as? [[String: Any]])?
            .first.flatMap { ($0["inlinePhraseSet"] as? [String: Any])?["phrases"] as? [[String: String]] }
        XCTAssertEqual(phrases?.map { $0["value"]! }, ["VoiceDraft", "ScreenKit"])

        let wav = WaveAudio.encode(Data(repeating: 0, count: 3200))
        var chat = ModelProfile.qwen(.speech); chat.selectModel("qwen3-asr-flash")
        let chatRequest = try QwenRequests.speech(profile: chat, key: "synthetic-key", wav: wav, vocabulary: AppVocabulary(words: "VoiceDraft"), screenTerms: ["ScreenKit"])
        let chatBody = try JSONSerialization.jsonObject(with: XCTUnwrap(chatRequest.httpBody)) as! [String: Any]
        XCTAssertEqual((chatBody["messages"] as? [[String: Any]])?.first?["content"] as? String, "VoiceDraft, ScreenKit")

        var audio = ModelProfile.qwen(.speech); audio.selectModel("qwen-audio-3.1-asr-flash")
        let audioRequest = try AudioHTTPRequests.speech(profile: audio, key: "synthetic-key", wav: wav, vocabulary: AppVocabulary(words: "VoiceDraft"), screenTerms: ["ScreenKit"])
        let audioBody = try JSONSerialization.jsonObject(with: XCTUnwrap(audioRequest.httpBody)) as! [String: Any]
        XCTAssertEqual((audioBody["parameters"] as? [String: Any])?["vocabulary"] as? [String: Int], ["VoiceDraft": 3, "ScreenKit": 1])
    }
}

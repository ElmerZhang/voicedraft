import XCTest
@testable import VoiceDraftCore

final class DoubaoTests: XCTestCase {
    func testHeadersNewAndLegacyCredentials() throws {
        var profile = ModelProfile(name: "Doubao", role: .speech, endpoint: "wss://fixture.invalid/api/v3/sauc/bigmodel", model: "bigmodel", adapter: .doubao)
        var request = try DoubaoSpeech.connection(profile: profile, key: "synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "synthetic"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        profile.extraJSON = #"{"app_id":"fixture-app","resource_id":"fixture-resource"}"#
        request = try DoubaoSpeech.connection(profile: profile, key: "synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-App-Key"), "fixture-app")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Access-Key"), "synthetic")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
    }
    func testFramesWithSequenceFinalAndMalformedLength() throws {
        let payload = Data(#"{"result":{"text":"fixture transcript"}}"#.utf8)
        var data = DoubaoWire.packet(payload, audio: false)
        data[1] = 0x92
        let response = try DoubaoWire.response(data)
        XCTAssertTrue(response.final); XCTAssertEqual(response.text, "fixture transcript")
        data[1] = 0x93; data.insert(contentsOf: [255,255,255,255], at: 4)
        XCTAssertTrue(try DoubaoWire.response(data).final)
        data.removeLast(); XCTAssertThrowsError(try DoubaoWire.response(data))
        XCTAssertEqual(Array(DoubaoWire.packet(Data([1,2]), audio: true, final: true).prefix(4)), [0x11,0x22,0,0])
    }
    func testStartUsesRawPCMAndDisablesDeletionOfSpokenCorrections() throws {
        let profile = ModelProfile(name: "Doubao", role: .speech, endpoint: "wss://fixture.invalid/api/v3/sauc/bigmodel", model: "bigmodel", adapter: .doubao)
        let frame = try DoubaoWire.start(profile: profile, vocabulary: AppVocabulary(words: "VoiceDraft"))
        let root = try JSONSerialization.jsonObject(with: frame.dropFirst(8)) as! [String: Any]
        XCTAssertEqual((root["audio"] as? [String: Any])?["format"] as? String, "pcm")
        XCTAssertEqual((root["request"] as? [String: Any])?["enable_ddc"] as? Bool, false)
        XCTAssertNotNil((root["request"] as? [String: Any])?["corpus"])
    }
}

extension DoubaoTests {
    func testHotwordsHoldVocabularyFirstThenScreenTermsUpTo100() throws {
        let profile = ModelProfile(name: "Doubao", role: .speech, endpoint: "wss://fixture.invalid/api/v3/sauc/bigmodel", model: "bigmodel", adapter: .doubao)
        let words = (0..<98).map { "Vocab\($0)" }
        let frame = try DoubaoWire.start(profile: profile, vocabulary: AppVocabulary(words: words.joined(separator: "\n")),
                                         screenTerms: ["ScreenA", "vocab1", "ScreenB", "ScreenC"])
        let root = try JSONSerialization.jsonObject(with: frame.dropFirst(8)) as! [String: Any]
        let context = ((root["request"] as? [String: Any])?["corpus"] as? [String: Any])?["context"] as! String
        let hotwords = (try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any])["hotwords"] as! [[String: String]]
        XCTAssertEqual(hotwords.map { $0["word"]! }, words + ["ScreenA", "ScreenB"])
        let screenOnly = try DoubaoWire.start(profile: profile, vocabulary: AppVocabulary(), screenTerms: ["ScreenA"])
        XCTAssertTrue(String(decoding: screenOnly, as: UTF8.self).contains("ScreenA"))
    }
}

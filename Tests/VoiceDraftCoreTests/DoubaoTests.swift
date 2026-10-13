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

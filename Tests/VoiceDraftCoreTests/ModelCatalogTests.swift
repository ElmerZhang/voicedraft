import XCTest
@testable import VoiceDraftCore

final class ModelCatalogTests: XCTestCase {
    func testLegacyProfileMigrationPreservesIdentityAndCredentialsAndRepairsProtocol() throws {
        var settings = SharedSettings()
        settings.profiles[0].model = "qwen-audio-3.1-asr-flash-message"
        settings.profiles[0].endpoint = "https://example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        settings.profiles[1].model = "my-existing-qwen-deployment"
        settings.vocabulary = AppVocabulary(words: "VoiceDraft\n百炼")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object["schemaVersion"] = 1
        object["hotwords"] = "VoiceDraft\n百炼"
        object.removeValue(forKey: "vocabulary")
        var profiles = object["profiles"] as! [[String: Any]]
        for i in profiles.indices { profiles[i].removeValue(forKey: "adapter"); profiles[i].removeValue(forKey: "speechOptions") }
        object["profiles"] = profiles
        let old = try JSONSerialization.data(withJSONObject: object)
        let migrated = try JSONDecoder().decode(SharedSettings.self, from: old)
        XCTAssertEqual(migrated.schemaVersion, 5)
        XCTAssertEqual(migrated.speechID, settings.speechID)
        XCTAssertEqual(migrated.writingID, settings.writingID)
        XCTAssertEqual(migrated.vocabulary.entries.map(\.text), ["VoiceDraft", "百炼"])
        XCTAssertEqual(migrated.speech?.adapter, .qwenMessageWebSocket)
        XCTAssertEqual(migrated.speech?.endpoint, "wss://example.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference")
        XCTAssertEqual(migrated.writing?.model, "my-existing-qwen-deployment")
        try migrated.validate()
        let snapshot = SyncSnapshot(settings: migrated, credentials: [settings.speechID.uuidString: "synthetic-secret"])
        let encrypted = try SyncCrypto.encrypt(snapshot, passphrase: "test-passphrase-only")
        XCTAssertEqual(try SyncCrypto.decrypt(encrypted, passphrase: "test-passphrase-only"), snapshot)
        let roundTrip = try JSONDecoder().decode(SharedSettings.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(roundTrip, migrated)
        object["schemaVersion"] = 5
        XCTAssertThrowsError(try JSONDecoder().decode(SharedSettings.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testLegacyCustomEndpointCanLoadForRepairWithoutDroppingSettings() throws {
        var settings = SharedSettings()
        settings.profiles[0].model = "qwen-audio-3.1-asr-flash-message"
        settings.profiles[0].endpoint = "https://custom.example/speech-proxy"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object["schemaVersion"] = 1
        object["hotwords"] = "VoiceDraft\n百炼"
        object.removeValue(forKey: "vocabulary")
        var profiles = object["profiles"] as! [[String: Any]]
        for i in profiles.indices { profiles[i].removeValue(forKey: "adapter"); profiles[i].removeValue(forKey: "speechOptions") }
        object["profiles"] = profiles
        let migrated = try JSONDecoder().decode(SharedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.speech?.endpoint, settings.speech?.endpoint)
        XCTAssertNoThrow(try migrated.validate())
        XCTAssertThrowsError(try migrated.speech?.validateForInference())
    }

    func testUnknownASRIsPreservedForRepairButCannotUseGenericHTTP() throws {
        var profile = ModelProfile.qwen(.speech)
        profile.model = "qwen3-asr-flash-realtime"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        json.removeValue(forKey: "adapter"); json.removeValue(forKey: "speechOptions")
        let migrated = try JSONDecoder().decode(ModelProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.model, profile.model)
        XCTAssertEqual(migrated.adapter, .unconfigured)
        XCTAssertEqual(migrated.id, profile.id)
        XCTAssertThrowsError(try migrated.validateForInference())
        XCTAssertThrowsError(try QwenRequests.speech(profile: migrated, key: "synthetic-key", wav: Data([1]), vocabulary: AppVocabulary(words: "")))
    }

    func testCatalogSelectionSetsCorrectProtocolWithoutChangingWorkspaceOrIdentity() throws {
        var p = ModelProfile.qwen(.speech)
        p.endpoint = "https://workspace.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        let id = p.id
        for model in ModelCatalog.models(for: .speech) {
            p.selectModel(model.id)
            XCTAssertEqual(p.adapter, model.adapter)
            XCTAssertEqual(p.id, id)
            XCTAssertEqual(URL(string: p.endpoint)?.host, "workspace.ap-southeast-1.maas.aliyuncs.com")
            XCTAssertEqual(URL(string: p.endpoint)?.path, model.adapter.path)
            XCTAssertEqual(URL(string: p.endpoint)?.scheme, model.adapter.isWebSocket ? "wss" : "https")
            try p.validateForInference()
        }
        p.selectModel("qwen-audio-3.1-asr-flash-message")
        p.endpoint = "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        XCTAssertThrowsError(try p.validateForInference())
        p.endpoint = "wss://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        XCTAssertThrowsError(try p.validateForInference())
        p.endpoint = "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
        p.adapter = .qwenChatSpeech
        XCTAssertThrowsError(try p.validateForInference())
    }

    func testWebSocketURLSecurityDoesNotRelaxSyncOrHTTPURLSecurity() throws {
        for value in ["ws://example.com/api", "wss://key:secret@example.com/api", "wss://example.com/api?key=x", "wss://example.com/#secret", "https://example.com/api"] {
            XCTAssertThrowsError(try Endpoint.validate(value, webSocket: true))
        }
        XCTAssertNoThrow(try Endpoint.validate("ws://127.0.0.1:1234/api", webSocket: true))
        XCTAssertNoThrow(try Endpoint.validate("wss://example.com/api", webSocket: true))
        XCTAssertThrowsError(try Endpoint.validate("wss://example.com/api"))
    }

    func testCapabilitySpecificParametersCannotOverrideEnvelopeOrFakeUnsupportedWeights() throws {
        for model in ModelCatalog.models(for: .speech) {
            var profile = ModelProfile.qwen(.speech); profile.selectModel(model.id)
            for json in [#"{"vocabulary_id":"remote"}"#, #"{"format":"mp3"}"#, #"{"input":{}}"#, #"{"vocabulary":{"secret":50}}"#, #"{"sample_rate":8000}"#, #"{"model":"other"}"#] {
                profile.extraJSON = json
                XCTAssertThrowsError(try profile.validateForInference())
            }
        }
        var profile = ModelProfile.qwen(.speech)
        XCTAssertEqual(profile.vocabularyCapability, .context)
        profile.extraJSON = #"{"asr_options":{"enable_itn":false}}"#
        XCTAssertNoThrow(try profile.validateForInference())
        profile.selectModel("qwen-audio-3.0-asr-flash")
        profile.extraJSON = #"{"speaker_diarization_enabled":true}"#
        XCTAssertThrowsError(try profile.validateForInference())
        profile.selectModel("qwen-audio-3.1-asr-flash")
        XCTAssertNoThrow(try profile.validateForInference())
    }

    func testNativeHTTPHasItsOwnEnvelopeResponseAndVocabulary() throws {
        var profile = ModelProfile.qwen(.speech)
        profile.selectModel("qwen-audio-3.1-asr-flash")
        profile.extraJSON = #"{"language_hints":["zh","en"]}"#
        var vocabulary = AppVocabulary(words: "Qwen")
        vocabulary.entries.append(.init(text: "VoiceDraft", boost: 100))
        let request = try AudioHTTPRequests.speech(profile: profile, key: "synthetic-key", wav: Data([1,2,3]), vocabulary: vocabulary)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, profile.model)
        XCTAssertNil(body["messages"]); XCTAssertNil(body["stream"])
        let input = body["input"] as! [String: Any]
        let message = (input["messages"] as! [[String: Any]])[0]
        let audio = (message["content"] as! [[String: Any]])[0]["input_audio"] as! [String: String]
        XCTAssertEqual(audio["data"], "data:audio/wav;base64,AQID")
        let parameters = body["parameters"] as! [String: Any]
        XCTAssertEqual(parameters["sample_rate"] as? String, "16000")
        XCTAssertEqual(parameters["vocabulary"] as? [String: Int], ["VoiceDraft": 5, "Qwen": 3])
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh", "en"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-key"))
        XCTAssertEqual(try AudioHTTPRequests.parse(Data(#"{"output":{"text":"Hello，世界。"}}"#.utf8)), "Hello，世界。")
        XCTAssertThrowsError(try AudioHTTPRequests.parse(Data(#"{"output":{"text":" "}}"#.utf8)))
        XCTAssertThrowsError(try AudioHTTPRequests.parse(Data(#"{"choices":[]}"#.utf8)))
        XCTAssertThrowsError(try QwenRequests.speech(profile: profile, key: "synthetic-key", wav: Data([1]), vocabulary: AppVocabulary(words: "")))
        vocabulary.enabled = false
        let disabled = try AudioHTTPRequests.speech(profile: profile, key: "synthetic-key", wav: Data([1]), vocabulary: vocabulary)
        let disabledBody = try JSONSerialization.jsonObject(with: disabled.httpBody!) as! [String: Any]
        XCTAssertNil((disabledBody["parameters"] as! [String: Any])["vocabulary"])
    }

    func testProviderErrorsExposeSafeDiagnosticCodeAndRequestIDWithoutBody() throws {
        let id = UUID().uuidString
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": "InvalidParameter", "message": "synthetic-key data:audio/wav;base64,SECRET"], "request_id": id])
        do { try ProviderFailure.check(body, response: response); XCTFail("Expected rejection") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("InvalidParameter"))
            XCTAssertTrue(error.localizedDescription.contains(id))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
        let error = ProviderFailure.http(status: 400, code: "synthetic-key", requestID: "private text")
        XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
        XCTAssertFalse(error.localizedDescription.contains("private text"))
    }
}

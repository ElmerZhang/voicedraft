import XCTest
import CryptoKit
@testable import VoiceDraftCore

final class FeatureTests: XCTestCase {
    func testGestureHoldTapLockAndRepeatedDown() {
        var gesture = RecordingGesture()
        XCTAssertEqual(gesture.press(at: 0, idle: true), .start)
        XCTAssertEqual(gesture.press(at: 0.1, idle: false), .none)
        XCTAssertEqual(gesture.release(at: 0.2, active: true), .none)
        XCTAssertTrue(gesture.locked)
        XCTAssertEqual(gesture.press(at: 1, idle: false), .finish)
        gesture.reset()
        XCTAssertEqual(gesture.press(at: 2, idle: true), .start)
        // Starting microphone/network is considered active too, so release is not lost.
        XCTAssertEqual(gesture.release(at: 3, active: true), .finish)
        gesture.reset()
        XCTAssertEqual(gesture.release(at: 4, active: true), .none)
        XCTAssertEqual(gesture.press(at: 5, idle: false), .none)
        XCTAssertEqual(gesture.release(at: 6, active: false), .none)
    }
    func testShortcutsRejectConflictsAndBareLetters() throws {
        try ShortcutBinding.validate(ShortcutBinding.defaults)
        try ShortcutBinding.validate([.init(.dictate, keyCode: 63, modifiers: 0)])
        XCTAssertThrowsError(try ShortcutBinding.validate([.init(.dictate, keyCode: 0, modifiers: 0)]))
        XCTAssertThrowsError(try ShortcutBinding.validate([.init(.dictate, keyCode: 0, modifiers: 6), .init(.ask, keyCode: 0, modifiers: 6)]))
    }
    func testSchemaFourMigratesWithoutChangingProfileOrKeyIdentity() throws {
        let old = SharedSettings()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["schemaVersion"] = 4
        for key in ["styles", "applicationStyles", "selectedStyleID"] { object.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(SharedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.schemaVersion, 5); XCTAssertEqual(old.profiles, migrated.profiles)
        XCTAssertEqual(migrated.stylePrompt, old.stylePrompt); XCTAssertTrue(migrated.styles.isEmpty)
        try migrated.validate()
    }
    func testStyleRoutingAndTransientContextNeverSynced() throws {
        var settings = SharedSettings()
        let one = WritingStyle(name: "Casual", prompt: "Conversational"), two = WritingStyle(name: "Work", prompt: "Professional")
        settings.styles = [one, two]; settings.selectedStyleID = one.id; settings.applicationStyles = ["test.work": two.id]
        XCTAssertEqual(settings.resolved(for: "test.work").stylePrompt, two.prompt)
        XCTAssertEqual(settings.resolved(for: "unknown").stylePrompt, one.prompt)
        settings.recentInputContext = "synthetic ephemeral context"
        let decoded = try JSONDecoder().decode(SharedSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.recentInputContext, "")
        settings.applicationStyles["bad"] = UUID(); XCTAssertThrowsError(try settings.validate())
    }
    func testRecentContextIsolationExpiryAndBounds() {
        var context = RecentInputContext(); let now = Date()
        context.append("old", application: "one", now: now.addingTimeInterval(-1801))
        context.append("other app", application: "two", now: now)
        for i in 0..<5 { context.append("item\(i)", application: "one", now: now) }
        XCTAssertEqual(context.text(application: "one", now: now), "item2\n---\nitem3\n---\nitem4")
        context.clear(); XCTAssertEqual(context.text(application: "one"), "")
    }
    func testWaveChunksPreserveEverySampleAndProviderLimit() throws {
        let pcm = Data((0..<(32000 * 130)).map { UInt8($0 % 251) })
        XCTAssertEqual(try WaveAudio.decode(WaveAudio.encode(pcm)), pcm)
        let chunks = WaveAudio.chunks(pcm)
        XCTAssertEqual(chunks.reduce(Data(), +), pcm)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1_600_000 && $0.count % 2 == 0 })
        XCTAssertThrowsError(try WaveAudio.decode(Data("invalid".utf8)))
        var corrupt = WaveAudio.encode(Data([0, 0])); corrupt[40] = 255
        XCTAssertThrowsError(try WaveAudio.decode(corrupt))
        try QwenRequests.validateAudio(WaveAudio.encode(Data(repeating: 0, count: 19_200_000)))
    }
    func testLiveRecordingArchiveIsOptInAndComplete() async throws {
        let feed = LiveAudioFeed(retainAudio: true)
        try feed.append(Data(repeating: 2, count: 4000)); try feed.finish()
        var sent = Data(); for try await frame in feed.stream { sent.append(frame) }
        XCTAssertEqual(try WaveAudio.decode(XCTUnwrap(feed.archivedWAV)), sent)
        let privateFeed = LiveAudioFeed(); try privateFeed.append(Data([0,0])); try privateFeed.finish()
        XCTAssertNil(privateFeed.archivedWAV)
    }
    func testWhisperMultipartAndGooglePayload() throws {
        let wav = WaveAudio.encode(Data(repeating: 0, count: 32000))
        let whisper = ModelProfile(name: "Fixture", role: .speech, endpoint: "https://fixture.invalid/v1/audio/transcriptions", model: "custom-whisper", adapter: .whisper)
        let request = try WhisperRequests.speech(profile: whisper, key: "synthetic-key", wav: wav, vocabulary: AppVocabulary(words: "VoiceDraft"), boundary: "fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=fixture")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"recording.wav\"")); XCTAssertTrue(body.contains("VoiceDraft"))
        XCTAssertFalse(body.contains("synthetic-key"))
        let google = ModelProfile(name: "Google", role: .speech, endpoint: "https://speech.googleapis.com/v2/projects/test/locations/global/recognizers/_:recognize", model: "chirp_3", extraJSON: #"{"languageCodes":["en-US"]}"#, adapter: .googleSpeech)
        let googleRequest = try GoogleSpeech.request(profile: google, token: "synthetic-token", pcm: Data(repeating: 0, count: 32000), vocabulary: AppVocabulary())
        let root = try JSONSerialization.jsonObject(with: XCTUnwrap(googleRequest.httpBody)) as! [String: Any]
        XCTAssertEqual(root["content"] as? String, wav.base64EncodedString())
        XCTAssertEqual((root["config"] as? [String: Any])?["languageCodes"] as? [String], ["en-US"])
        XCTAssertEqual(try GoogleSpeech.parse(Data(#"{"results":[{"alternatives":[{"transcript":"one"}]},{"alternatives":[{"transcript":"two"}]}]}"#.utf8)), "one\ntwo")
    }
    func testVocabularyArchivePreservesMetadataAndMergesBySpelling() throws {
        var vocabulary = AppVocabulary(words: "VoiceDraft\nAPI")
        vocabulary.entries[0].aliases = ["voice draft"]; vocabulary.entries[0].useCount = 8
        let entries = try VocabularyFile.entries(VocabularyFile.export(vocabulary))
        XCTAssertEqual(entries, vocabulary.entries)
        var destination = AppVocabulary(words: "voicedraft")
        try VocabularyFile.merge(entries, into: &destination)
        XCTAssertEqual(destination.entries.count, 2)
        XCTAssertTrue(vocabulary.recordUsage(in: "VoiceDraft and VoiceDraft API. Not APIs."))
        XCTAssertEqual(vocabulary.entries[0].useCount, 9); XCTAssertEqual(vocabulary.entries[1].useCount, 1)
        XCTAssertFalse(vocabulary.recordUsage(in: "APIs APITest"))
        XCTAssertEqual(VocabularyProjection.make(vocabulary, for: .context).terms.first, "VoiceDraft")
    }
    func testContextImportIgnoresToolsAssistantsAndCredentialLines() throws {
        let lines = [
            #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"VoiceDraft SwiftUI API"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"AssistantOnly"}}"#,
            #"{"type":"user","message":{"role":"user","content":"ClaudeCode API"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"CodexContext"}}"#,
            #"{"type":"response_item","payload":{"role":"tool","content":"ToolOnly"}}"#,
            #"{"type":"user","message":{"role":"user","content":"api_key=SecretToken"}}"#
        ].joined(separator: "\n")
        let terms = try ContextVocabulary.candidates(data: Data(lines.utf8), filename: "fixture.jsonl")
        XCTAssertTrue(terms.contains("VoiceDraft")); XCTAssertTrue(terms.contains("ClaudeCode")); XCTAssertTrue(terms.contains("CodexContext"))
        XCTAssertFalse(terms.contains("AssistantOnly")); XCTAssertFalse(terms.contains("ToolOnly")); XCTAssertFalse(terms.contains("SecretToken"))
    }
    func testOldHistoryDecodesWithoutAudio() throws {
        let entry = HistoryEntry(mode: .polish, original: "fixture", result: "fixture", application: "test", duration: 1)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertNil(decoded.audioID); XCTAssertEqual(decoded.id, entry.id)
    }
}

extension FeatureTests {
    func testLegacyDeviceSettingsRetainPreferencesAndUseSafeFeatureDefaults() throws {
        let legacy = Data(#"{"inputDeviceID":"fixture-mic","autoPaste":false,"keepHistory":false,"syncRevision":7,"syncIdentity":"fixture"}"#.utf8)
        let device = try JSONDecoder().decode(DeviceSettings.self, from: legacy)
        XCTAssertEqual(device.inputDeviceID, "fixture-mic"); XCTAssertEqual(device.syncRevision, 7)
        XCTAssertFalse(device.autoPaste); XCTAssertFalse(device.keepHistory)
        XCTAssertFalse(device.features.retainAudio); XCTAssertFalse(device.features.recentContext)
        XCTAssertEqual(device.features.retentionDays, 0); XCTAssertFalse(device.features.automaticUpdates)
    }
}

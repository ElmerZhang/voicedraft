import XCTest
import VoiceDraftCore
@testable import VoiceDraft

final class IOSLocalStoreTests: XCTestCase {
    private var directory: URL!
    private var store: IOSLocalStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        store = try IOSLocalStore(directory: directory)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testMissingFilesFallBackToDefaults() throws {
        let settings = try store.loadSettings()
        XCTAssertEqual(settings.schemaVersion, 5)
        XCTAssertNotNil(settings.speech)
        XCTAssertNotNil(settings.writing)
        XCTAssertEqual(try store.loadDevice(), IOSDeviceSettings())
        XCTAssertTrue(try store.loadHistory().isEmpty)
    }

    func testSettingsRoundTripIncludingVocabularyAndStyles() throws {
        var settings = SharedSettings()
        settings.targetLanguage = "Japanese"
        settings.vocabulary.appendLines("VoiceDraft\nKubernetes")
        settings.vocabulary.entries[1].enabled = false
        let style = WritingStyle(name: "Brief", prompt: "Be brief.")
        settings.styles = [style]
        settings.selectedStyleID = style.id
        try store.saveSettings(settings)
        let loaded = try store.loadSettings()
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.vocabulary.entries.map(\.text), ["VoiceDraft", "Kubernetes"])
        XCTAssertEqual(loaded.resolved(for: nil).stylePrompt, "Be brief.")
    }

    func testSettingsFileIsTheSyncedSharedSettingsEncoding() throws {
        // A snapshot encoded by Core (as the Mac uploads it) decodes from the same file unchanged.
        let settings = SharedSettings()
        try JSONEncoder().encode(settings).write(to: store.url("settings"))
        XCTAssertEqual(try store.loadSettings(), settings)
    }

    func testDeviceRoundTripAndLegacyDefaults() throws {
        var device = IOSDeviceSettings()
        device.serverURL = "https://sync.example.com"
        device.syncRevision = 7
        device.dirty = false
        device.mode = .ask
        device.listeningTimeoutMinutes = 25
        device.onboardingCompleted = true
        try store.saveDevice(device)
        XCTAssertEqual(try store.loadDevice(), device)

        try Data(#"{"serverURL":"https://a.example","mode":"edit","listeningTimeoutMinutes":0}"#.utf8).write(to: store.url("device"))
        let legacy = try store.loadDevice()
        XCTAssertEqual(legacy.serverURL, "https://a.example")
        XCTAssertEqual(legacy.mode, .polish, "Edit is not offered on iPhone")
        XCTAssertEqual(legacy.listeningTimeoutMinutes, 1)
        XCTAssertTrue(legacy.keepHistory)
    }

    func testHistoryRoundTripNewestFirstAndCapped() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let entries: [HistoryEntry] = (0..<(IOSLocalStore.historyLimit + 20)).map { index in
            var entry = HistoryEntry(mode: .polish, original: "o\(index)", result: "r\(index)", application: "VoiceDraft", duration: 1)
            entry.date = base.addingTimeInterval(Double(index))
            return entry
        }
        let written = try store.saveHistory(entries)
        XCTAssertEqual(written.count, IOSLocalStore.historyLimit)
        let loaded = try store.loadHistory()
        XCTAssertEqual(loaded.count, IOSLocalStore.historyLimit)
        XCTAssertEqual(loaded.first?.result, "r\(IOSLocalStore.historyLimit + 19)")
        XCTAssertEqual(loaded.last?.result, "r20")
        XCTAssertEqual(loaded.map(\.id), written.map(\.id))
    }

    func testFilesUseCompleteProtection() throws {
        try store.saveDevice(IOSDeviceSettings())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url("device").path)
        // The simulator may not report protection classes; when it does, it must be complete.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
    }
}

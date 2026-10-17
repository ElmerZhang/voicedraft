import XCTest
@testable import VoiceDraftCore

final class PasteConfirmationSettingsTests: XCTestCase {
    func testLegacyDeviceAndPersistenceRoundTrip() throws {
        let legacy = try JSONDecoder().decode(DeviceSettings.self, from: Data(#"{"autoPaste":false,"keepHistory":false,"syncRevision":7}"#.utf8))
        XCTAssertTrue(legacy.hiddenPasteConfirmationApps.isEmpty)
        var updated = legacy
        updated.hiddenPasteConfirmationApps = ["test.browser": "Browser", "test.editor": "Editor"]
        let restored = try JSONDecoder().decode(DeviceSettings.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.hiddenPasteConfirmationApps, updated.hiddenPasteConfirmationApps)
        XCTAssertFalse(restored.autoPaste)
        XCTAssertFalse(restored.keepHistory)
        XCTAssertEqual(restored.syncRevision, 7)
    }
}

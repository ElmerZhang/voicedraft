import XCTest
@testable import VoiceDraftCore

/// Settings written before `insertLast` existed, and files read by older builds.
final class ShortcutMigrationTests: XCTestCase {
    private let legacyShortcuts = """
    [{"action":"dictate","keyCode":49,"modifiers":6,"enabled":true},
     {"action":"translate","keyCode":17,"modifiers":6,"enabled":true},
     {"action":"edit","keyCode":14,"modifiers":6,"enabled":true},
     {"action":"ask","keyCode":0,"modifiers":6,"enabled":true},
     {"action":"styleSelection","keyCode":1,"modifiers":6,"enabled":true}]
    """
    private func options(shortcuts: String, extra: String = "") throws -> DesktopOptions {
        let json = """
        {"shortcuts":\(shortcuts),\(extra)"sounds":false,"muteOutput":false,"retainAudio":false,"retentionDays":7,
         "recentContext":false,"onboardingCompleted":true,"updateFeed":"","updatePublicKey":"","automaticUpdates":false}
        """
        return try JSONDecoder().decode(DesktopOptions.self, from: Data(json.utf8))
    }

    func testDefaultsIncludeInsertLastAndValidate() throws {
        let binding = try XCTUnwrap(ShortcutBinding.defaults.first { $0.action == .insertLast })
        XCTAssertEqual([binding.keyCode, binding.modifiers], [9, 6]); XCTAssertTrue(binding.enabled)
        XCTAssertEqual(Set(ShortcutBinding.defaults.map(\.action)), Set(ShortcutAction.allCases))
        try ShortcutBinding.validate(ShortcutBinding.defaults)
        try DesktopOptions().validate()
        XCTAssertThrowsError(try ShortcutBinding.validate(ShortcutBinding.defaults + [.init(.insertLast, keyCode: 8, modifiers: 6)]))
    }

    func testPreexistingDeviceFileGainsInsertLastAndKeepsPreferences() throws {
        let legacy = Data("""
        {"autoPaste":false,"keepHistory":true,"features":{"shortcuts":\(legacyShortcuts),"sounds":false,"muteOutput":false,
         "retainAudio":false,"retentionDays":7,"recentContext":false,"onboardingCompleted":true,"updateFeed":"",
         "updatePublicKey":"","automaticUpdates":false}}
        """.utf8)
        let device = try JSONDecoder().decode(DeviceSettings.self, from: legacy)
        XCTAssertFalse(device.autoPaste); XCTAssertFalse(device.features.sounds)
        XCTAssertEqual(device.features.retentionDays, 7); XCTAssertTrue(device.features.onboardingCompleted)
        XCTAssertEqual(device.features.shortcuts, ShortcutBinding.defaults)
    }

    func testMigrationKeepsCustomBindingsAndAppendsDisabledWhenDefaultIsTaken() throws {
        let custom = """
        [{"action":"dictate","keyCode":9,"modifiers":6,"enabled":true},
         {"action":"ask","keyCode":0,"modifiers":6,"enabled":false}]
        """
        let migrated = try options(shortcuts: custom).shortcuts
        XCTAssertEqual(migrated.first, .init(.dictate, keyCode: 9, modifiers: 6))
        XCTAssertEqual(migrated[1], .init(.ask, keyCode: 0, modifiers: 6, enabled: false))
        XCTAssertEqual(migrated.last, .init(.insertLast, keyCode: 9, modifiers: 6, enabled: false))
        XCTAssertEqual(Set(migrated.map(\.action)), Set(ShortcutAction.allCases))
        try ShortcutBinding.validate(migrated)
        // A disabled binding on the same keys does not block the default.
        let free = ShortcutBinding.fillingDefaults([.init(.dictate, keyCode: 9, modifiers: 6, enabled: false)])
        XCTAssertEqual(free.first { $0.action == .insertLast }?.enabled, true)
        // Bindings already covering every action are returned unchanged.
        XCTAssertEqual(ShortcutBinding.fillingDefaults(ShortcutBinding.defaults), ShortcutBinding.defaults)
    }

    func testOlderBuildsCanStillReadNewFiles() throws {
        var options = DesktopOptions()
        options.shortcuts[5] = .init(.insertLast, keyCode: 9, modifiers: 14)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
        let stored = try XCTUnwrap(object["shortcuts"] as? [[String: Any]])
        // Older builds decode this array strictly and accept at most five bindings.
        XCTAssertEqual(stored.compactMap { $0["action"] as? String }, ["dictate", "translate", "edit", "ask", "styleSelection"])
        let additional = try XCTUnwrap(object["additionalShortcuts"] as? [[String: Any]])
        XCTAssertEqual(additional.first?["action"] as? String, "insertLast")
        let roundTrip = try JSONDecoder().decode(DesktopOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(roundTrip, options)
    }

    func testUnknownFutureActionsAreSkipped() throws {
        let future = """
        [{"action":"dictate","keyCode":49,"modifiers":6,"enabled":true},
         {"action":"someFutureAction","keyCode":3,"modifiers":6,"enabled":true}]
        """
        let decoded = try options(shortcuts: future, extra: #""additionalShortcuts":[{"action":"anotherFutureAction","keyCode":5,"modifiers":6,"enabled":true}],"#)
        XCTAssertEqual(decoded.shortcuts.map(\.action), [.dictate, .translate, .edit, .ask, .styleSelection, .insertLast])
        try decoded.validate()
    }
}

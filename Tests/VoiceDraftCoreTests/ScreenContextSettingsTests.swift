import XCTest
@testable import VoiceDraftCore

final class ScreenContextSettingsTests: XCTestCase {
    private func device(features: String) throws -> DeviceSettings {
        try JSONDecoder().decode(DeviceSettings.self, from: Data(#"{"syncRevision":3,"features":\#(features)}"#.utf8))
    }

    func testOldDeviceFileDecodesToPrivacySafeDefaults() throws {
        let decoded = try device(features: #"{"sounds":false,"retentionDays":7}"#)
        let options = decoded.features
        XCTAssertFalse(options.screenContext); XCTAssertTrue(options.screenContextASR)
        XCTAssertTrue(options.screenContextWriting); XCTAssertFalse(options.screenContextOCR)
        XCTAssertEqual(options.screenContextExcludedApps, [])
        XCTAssertFalse(options.sounds); XCTAssertEqual(decoded.syncRevision, 3)
        XCTAssertEqual(DesktopOptions().screenContext, false)
    }

    func testRoundTripKeepsValuesAndAlwaysWritesKeys() throws {
        var options = DesktopOptions()
        options.screenContext = true; options.screenContextASR = false
        options.screenContextWriting = true; options.screenContextOCR = true
        options.screenContextExcludedApps = ["com.example.mail", "org.fixture.chat"]
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(DesktopOptions.self, from: data), options)
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DesktopOptions())) as! [String: Any]
        for key in ["screenContext", "screenContextASR", "screenContextWriting", "screenContextOCR", "screenContextExcludedApps"] {
            XCTAssertNotNil(defaults[key], key)
        }
    }

    func testMalformedValuesNeverThrowAndAreSanitized() throws {
        let decoded = try device(features: #"""
        {"screenContext":"yes","screenContextASR":1,"screenContextOCR":null,
         "screenContextExcludedApps":[1, "com.ok.app", {"x":1}, " com.OK.App ", "bad id", "", ".hidden", "com.other", null],
         "futureScreenOption":{"nested":true}}
        """#)
        XCTAssertFalse(decoded.features.screenContext)
        XCTAssertTrue(decoded.features.screenContextASR)
        XCTAssertFalse(decoded.features.screenContextOCR)
        XCTAssertEqual(decoded.features.screenContextExcludedApps, ["com.ok.app", "com.other"])
        XCTAssertNoThrow(try decoded.features.validate())

        XCTAssertEqual(try device(features: #"{"screenContextExcludedApps":"com.example.mail"}"#).features.screenContextExcludedApps, [])
        XCTAssertEqual(try device(features: #"{"screenContextExcludedApps":42}"#).features.screenContextExcludedApps, [])
        let many = (0..<1_000).map { "\"com.fixture.app\($0)\"" }.joined(separator: ",")
        let large = try device(features: "{\"screenContextExcludedApps\":[\(many)]}")
        XCTAssertEqual(large.features.screenContextExcludedApps.count, 200)
        XCTAssertEqual(large.features.screenContextExcludedApps.first, "com.fixture.app0")
    }

    func testSanitizerRules() {
        let long = "a" + String(repeating: "b", count: 255)
        XCTAssertEqual(ScreenContextPolicy.sanitizedExclusions(["  com.A.b ", "COM.a.B", "com.a-b_c.1", "-leading", long, "with space", "ü.app"]),
                       ["com.A.b", "com.a-b_c.1"])
        XCTAssertEqual(ScreenContextPolicy.sanitizedExclusions([String(long.dropLast())]).count, 1)
    }
}

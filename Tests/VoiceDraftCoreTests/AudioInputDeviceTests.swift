import XCTest
@testable import VoiceDraftCore

final class AudioInputDeviceTests: XCTestCase {
    let builtIn = AudioInputDevice(id: "built-in-uid", name: "Microphone")
    let usb = AudioInputDevice(id: "usb-uid", name: "Microphone")

    func testDeviceSelectionUsesStableIDAndNeverFallsBackWhenMissing() throws {
        XCTAssertEqual(try AudioInputDevice.resolve(preferredID: usb.id, defaultID: builtIn.id, available: [builtIn, usb]), usb)
        XCTAssertThrowsError(try AudioInputDevice.resolve(preferredID: usb.id, defaultID: builtIn.id, available: [builtIn]))
        XCTAssertThrowsError(try AudioInputDevice.resolve(preferredID: nil, defaultID: nil, available: []))
    }
    func testDefaultIsResolvedPerTakeAndTheResolvedValueIsStable() throws {
        let take = try AudioInputDevice.resolve(preferredID: nil, defaultID: builtIn.id, available: [builtIn, usb])
        let next = try AudioInputDevice.resolve(preferredID: nil, defaultID: usb.id, available: [builtIn, usb])
        XCTAssertEqual(take, builtIn); XCTAssertEqual(next, usb)
        XCTAssertEqual(try AudioInputDevice.resolve(preferredID: builtIn.id, defaultID: usb.id, available: [builtIn, usb]), builtIn)
    }
}

import XCTest
@testable import VoiceDraft
import VoiceDraftCore

final class InputDeviceSettingsTests: XCTestCase {
    func testUnavailableDeviceOffersRecoveryButUnrelatedErrorsDoNot() async {
        await MainActor.run {
            let state = AppState(preview: true)
            XCTAssertFalse(state.canChooseInputDeviceForError)
            do {
                _ = try AudioInputDevice.resolve(preferredID: "disconnected", defaultID: nil, available: [])
                XCTFail("Missing preferred device must fail")
            } catch { state.error = .init(error: error) }
            XCTAssertTrue(state.canChooseInputDeviceForError)
            state.error = "A provider request failed."
            XCTAssertFalse(state.canChooseInputDeviceForError)
        }
    }

    func testRecoveryRoutesFromAnyTabAndCanBeRepeatedWithoutChangingDevice() async {
        await MainActor.run {
            let state = AppState(preview: true)
            let selectedDevice = state.device.inputDeviceID
            state.error = "The selected audio input is unavailable. Reconnect it or choose another device."
            state.openSettings("Usage")
            state.openInputDeviceSettings()
            XCTAssertEqual(state.page, "Settings")
            XCTAssertEqual(state.settingsTab, "Settings")
            let firstRequest = state.inputDeviceSettingsRequest
            XCTAssertNotNil(firstRequest)
            state.openInputDeviceSettings()
            XCTAssertNotEqual(state.inputDeviceSettingsRequest, firstRequest)
            XCTAssertEqual(state.device.inputDeviceID, selectedDevice)
            XCTAssertTrue(state.canChooseInputDeviceForError, "Navigation must not silently dismiss the error")
            state.openSettings("Models")
            XCTAssertNil(state.inputDeviceSettingsRequest, "Ordinary navigation must not reuse a stale scroll target")
        }
    }
}

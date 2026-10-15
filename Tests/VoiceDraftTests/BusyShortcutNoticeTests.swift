import XCTest
@testable import VoiceDraft
import VoiceDraftCore

/// A shortcut press while the previous take is still processing is ignored by
/// the gesture but shows the Processing capsule instead of looking dead.
final class BusyShortcutNoticeTests: XCTestCase {
    func testPressDuringProcessingShowsTheCapsuleAndKeepsTheTake() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("processing")
            var shown = 0
            state.showHUD = { shown += 1 }
            state.shortcutEvent(.dictate, down: true)
            XCTAssertEqual(state.status, "Still finishing the previous take…")
            XCTAssertEqual(shown, 1)
            XCTAssertEqual(state.phase, "processing", "the previous take is not interrupted")
            state.shortcutEvent(.dictate, down: false)
            XCTAssertEqual(state.phase, "processing")
            XCTAssertFalse(state.recordingLocked)
        }
    }

    func testPressWhileRecordingShowsNoNotice() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            let before = state.status
            var shown = 0
            state.showHUD = { shown += 1 }
            state.shortcutEvent(.dictate, down: true)
            XCTAssertEqual(state.status, before)
            XCTAssertEqual(shown, 0)
        }
    }
}

import XCTest
@testable import VoiceDraft
import VoiceDraftCore

/// AppState side of a held Fn chord switching actions mid-take. Preview mode
/// has no writing key, so mode changes are refused here; the policy itself is
/// covered by FnChordTests.
final class FnRetargetTests: XCTestCase {
    func testRetargetMovesTheHeldKeySoFnReleaseStillEndsTheHold() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            state.shortcutEvent(.dictate, down: true)
            state.retargetShortcut(from: .dictate, to: .translate)
            // Refused like a take start without a writing key: the mode stays.
            XCTAssertEqual(state.runMode, .polish)
            XCTAssertEqual(state.status, "Add an API key for the writing model first.")
            // The old action's release no longer matches; the new one's does.
            state.shortcutEvent(.dictate, down: false)
            XCTAssertFalse(state.recordingLocked)
            state.shortcutEvent(.translate, down: false)
            XCTAssertTrue(state.recordingLocked, "a quick release of the retargeted hold locks the take")
        }
    }

    func testRetargetIgnoredWithoutAMatchingHold() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            let before = state.status
            state.retargetShortcut(from: .dictate, to: .translate)
            XCTAssertEqual(state.status, before)
            XCTAssertEqual(state.runMode, .polish)
        }
    }

    func testReleaseOfNonRecordingRetargetTakesTheGesturePath() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            state.shortcutEvent(.dictate, down: true)
            state.retargetShortcut(from: .dictate, to: .insertLast)
            XCTAssertEqual(state.runMode, .polish)
            state.shortcutEvent(.insertLast, down: false)
            XCTAssertTrue(state.recordingLocked)
        }
    }
}

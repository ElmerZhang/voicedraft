import XCTest
@testable import VoiceDraft
import VoiceDraftCore

final class PasteConfirmationTests: XCTestCase {
    func testMuteIsPerCapturedAppAndRestoreShowsTheCardAgain() async {
        await MainActor.run {
            let state = AppState(preview: true)
            var shown = 0, hidden = 0
            state.showHUD = { shown += 1 }; state.hideHUD = { hidden += 1 }
            state.presentQueuedPaste("First", opaque: true, bundleID: "test.browser", applicationName: "Browser")
            XCTAssertTrue(state.canHidePasteConfirmation)
            state.hidePasteConfirmationForApp()
            XCTAssertEqual(state.device.hiddenPasteConfirmationApps, ["test.browser": "Browser"])
            XCTAssertEqual(hidden, 1)
            XCTAssertFalse(state.canHidePasteConfirmation)
            state.presentQueuedPaste("Second", opaque: true, bundleID: "test.browser", applicationName: "Renamed")
            XCTAssertEqual(shown, 1)
            XCTAssertEqual(hidden, 2)
            XCTAssertEqual(state.hudKind, .compact)
            state.applyDeliveryOutcome(.sentWithoutConfirmation, id: state.generation, opaque: true)
            XCTAssertEqual(shown, 1, "Late receipts must not reopen a muted card")
            XCTAssertFalse(state.hudPasteSent)
            state.presentQueuedPaste("Other", opaque: true, bundleID: "test.other", applicationName: "Browser")
            XCTAssertEqual(shown, 2, "Display names must not identify apps")
            state.restorePasteConfirmation(for: "test.browser")
            state.presentQueuedPaste("Restored", opaque: true, bundleID: "test.browser")
            XCTAssertEqual(shown, 3)
            XCTAssertTrue(state.canHidePasteConfirmation)
        }
    }

    func testUnidentifiedAndNonOpaqueTargetsCannotCreateMuteRules() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.presentQueuedPaste("Unknown", opaque: true)
            XCTAssertTrue(state.hudPasteSent)
            XCTAssertFalse(state.canHidePasteConfirmation)
            state.hidePasteConfirmationForApp()
            state.presentQueuedPaste("Editor", opaque: false, bundleID: "test.editor")
            XCTAssertFalse(state.canHidePasteConfirmation)
            state.hidePasteConfirmationForApp()
            XCTAssertTrue(state.device.hiddenPasteConfirmationApps.isEmpty)
        }
    }

    func testErrorsAndDismissedOrCancelledCardsCannotMuteAnOldTarget() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.presentQueuedPaste("Text", opaque: true, bundleID: "test.browser")
            state.error = "Could not copy the result."
            state.hidePasteConfirmationForApp()
            XCTAssertTrue(state.device.hiddenPasteConfirmationApps.isEmpty)
            state.error = ""
            state.dismissHUD()
            state.hidePasteConfirmationForApp()
            XCTAssertTrue(state.device.hiddenPasteConfirmationApps.isEmpty)
            state.presentQueuedPaste("Text", opaque: true, bundleID: "test.browser")
            state.cancel()
            state.hidePasteConfirmationForApp()
            XCTAssertTrue(state.device.hiddenPasteConfirmationApps.isEmpty)
        }
    }

    func testMutedAppStillShowsAnErrorAlongsideQueuedText() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.presentQueuedPaste("Text", opaque: true, bundleID: "test.browser")
            state.hidePasteConfirmationForApp()
            var shown = 0
            state.showHUD = { shown += 1 }
            state.error = "Could not save history."
            state.presentQueuedPaste("Preserved text", opaque: true, bundleID: "test.browser")
            XCTAssertEqual(shown, 1)
            XCTAssertEqual(state.hudKind, .result)
            XCTAssertEqual(state.hudText, "Preserved text")
            XCTAssertFalse(state.canHidePasteConfirmation)
            XCTAssertEqual(state.device.hiddenPasteConfirmationApps.count, 1)
        }
    }
}

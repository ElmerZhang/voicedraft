import XCTest
@testable import VoiceDraft
import VoiceDraftCore

/// A take returns to idle once Command-V is queued; the receipt outcome arrives
/// later and may only update the status of the run that sent it.
final class DeliveryOutcomeTests: XCTestCase {
    func testOutcomeForTheCurrentRunSetsTheFinalStatus() async {
        await MainActor.run {
            let state = AppState(preview: true)
            let id = state.generation
            state.applyDeliveryOutcome(.confirmed, id: id)
            XCTAssertEqual(state.status, "Text inserted")
            state.applyDeliveryOutcome(.sentToTerminal, id: id)
            XCTAssertEqual(state.status, "Paste sent to terminal")
            state.applyDeliveryOutcome(.sentWithoutConfirmation, id: id)
            XCTAssertEqual(state.status, "Paste sent · check the input field")
        }
    }

    func testStaleOutcomeIsIgnoredAfterANewerRunOrCancel() async {
        await MainActor.run {
            let state = AppState(preview: true)
            let stale = state.generation
            state.cancel()
            XCTAssertNotEqual(state.generation, stale)
            XCTAssertEqual(state.status, "Cancelled")
            state.applyDeliveryOutcome(.confirmed, id: stale)
            XCTAssertEqual(state.status, "Cancelled", "a late receipt must not overwrite a newer run's status")
        }
    }

    /// Paste unless proven otherwise: an opaque target cannot confirm the paste,
    /// so the result card stays up as the copy fallback and keeps its status.
    func testOpaquePasteKeepsTheResultCardAndItsStatus() async {
        await MainActor.run {
            let state = AppState(preview: true)
            var shown = 0, hidden = 0
            state.showHUD = { shown += 1 }; state.hideHUD = { hidden += 1 }
            let id = state.generation
            state.presentQueuedPaste("Synthetic dictation", opaque: true)
            XCTAssertEqual(state.hudKind, .result)
            XCTAssertEqual(state.hudText, "Synthetic dictation")
            XCTAssertEqual(state.status, "Paste sent · copy here if nothing appeared")
            XCTAssertTrue(state.hudPasteSent)
            XCTAssertEqual(shown, 1); XCTAssertEqual(hidden, 0)
            state.applyDeliveryOutcome(.sentWithoutConfirmation, id: id, opaque: true)
            XCTAssertEqual(state.status, "Paste sent · copy here if nothing appeared")
            XCTAssertTrue(state.hudPasteSent)
            XCTAssertTrue(state.handleEscape(hudVisible: true), "Escape closes the card")
            XCTAssertEqual(hidden, 1)
        }
    }

    func testWritableOrTerminalPasteHidesTheHUD() async {
        await MainActor.run {
            let state = AppState(preview: true)
            var shown = 0, hidden = 0
            state.showHUD = { shown += 1 }; state.hideHUD = { hidden += 1 }
            let id = state.generation
            state.presentQueuedPaste("Synthetic dictation", opaque: false)
            XCTAssertEqual(state.hudKind, .compact)
            XCTAssertFalse(state.hudPasteSent)
            XCTAssertEqual(shown, 0); XCTAssertEqual(hidden, 1)
            state.applyDeliveryOutcome(.sentWithoutConfirmation, id: id, opaque: false)
            XCTAssertEqual(state.status, "Paste sent · check the input field")
        }
    }
}

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
}

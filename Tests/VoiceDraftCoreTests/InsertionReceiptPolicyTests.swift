import XCTest
@testable import VoiceDraftCore

final class InsertionReceiptPolicyTests: XCTestCase {
    func testTextFieldsPollTheAccessibilityReceiptForOneAndAHalfSeconds() {
        let policy = InsertionReceiptPolicy(keyboardSurface: false)
        XCTAssertTrue(policy.observesAccessibility)
        XCTAssertEqual(policy.attempts, 20)
        XCTAssertEqual(policy.intervalNanoseconds, 75_000_000)
        XCTAssertEqual(policy.maximumSeconds, 1.5, accuracy: 0.0001)
    }

    func testKeyboardSurfacesKeepOnlyAShortClipboardGrace() {
        let policy = InsertionReceiptPolicy(keyboardSurface: true)
        XCTAssertFalse(policy.observesAccessibility, "terminals expose no AX receipt")
        XCTAssertEqual(policy.attempts, 1)
        XCTAssertEqual(policy.maximumSeconds, 0.3, accuracy: 0.0001)
        XCTAssertLessThan(policy.maximumSeconds, InsertionReceiptPolicy(keyboardSurface: false).maximumSeconds)
    }

    func testConsumptionGraceIsShortAndBoundedByTheWindow() {
        for keyboardSurface in [false, true] {
            let policy = InsertionReceiptPolicy(keyboardSurface: keyboardSurface)
            XCTAssertEqual(policy.consumptionGraceNanoseconds, 200_000_000)
            XCTAssertLessThan(Double(policy.consumptionGraceNanoseconds) / 1_000_000_000, policy.maximumSeconds)
        }
    }
}

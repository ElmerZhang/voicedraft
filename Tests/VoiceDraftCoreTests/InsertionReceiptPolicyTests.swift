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
}

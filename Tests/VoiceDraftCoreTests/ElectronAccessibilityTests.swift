import XCTest
@testable import VoiceDraftCore

final class ElectronAccessibilityTests: XCTestCase {
    typealias Policy = ElectronAccessibilityPolicy

    func testEnablesWhenSettableAndFocusMissingOrNotWritable() {
        XCTAssertTrue(Policy.shouldEnable(manualAccessibilitySettable: true, focusedCapability: nil))
        XCTAssertTrue(Policy.shouldEnable(manualAccessibilitySettable: true, focusedCapability: .notWritable))
        XCTAssertTrue(Policy.shouldEnable(manualAccessibilitySettable: true, focusedCapability: .opaque))
    }

    func testNeverEnablesWhenNotSettable() {
        for capability in [nil, TextInputCapability.writable, .notWritable, .opaque] {
            XCTAssertFalse(Policy.shouldEnable(manualAccessibilitySettable: false, focusedCapability: capability))
        }
    }

    func testNeverEnablesWhenAlreadyWritable() {
        XCTAssertFalse(Policy.shouldEnable(manualAccessibilitySettable: true, focusedCapability: .writable))
    }

    func testPendingOnlyForEnabledNonEditableCaptures() {
        XCTAssertTrue(Policy.capturePending(enabled: true, editable: false))
        XCTAssertFalse(Policy.capturePending(enabled: true, editable: true))
        XCTAssertFalse(Policy.capturePending(enabled: false, editable: false))
    }

    func testRetryOnlyForPendingAutomaticExternalInsertion() {
        XCTAssertTrue(Policy.shouldRetryCapture(pending: true, editable: false, external: true, autoPaste: true, ask: false))
        XCTAssertFalse(Policy.shouldRetryCapture(pending: false, editable: false, external: true, autoPaste: true, ask: false))
        XCTAssertFalse(Policy.shouldRetryCapture(pending: true, editable: true, external: true, autoPaste: true, ask: false))
        XCTAssertFalse(Policy.shouldRetryCapture(pending: true, editable: false, external: false, autoPaste: true, ask: false))
        XCTAssertFalse(Policy.shouldRetryCapture(pending: true, editable: false, external: true, autoPaste: false, ask: false))
        XCTAssertFalse(Policy.shouldRetryCapture(pending: true, editable: false, external: true, autoPaste: true, ask: true))
    }

    func testRefreshedTargetMustStayInSameProcessAndBeEditable() {
        XCTAssertTrue(Policy.acceptsRefreshed(originalPID: 10, refreshedPID: 10, refreshedEditable: true))
        XCTAssertFalse(Policy.acceptsRefreshed(originalPID: 10, refreshedPID: 11, refreshedEditable: true))
        XCTAssertFalse(Policy.acceptsRefreshed(originalPID: 10, refreshedPID: 10, refreshedEditable: false))
    }

    func testRetryDeadlineCountsFromEnable() {
        XCTAssertEqual(Policy.retryDeadline(enabledAt: 100, now: 101), 100 + Policy.retryWindowSeconds)
        XCTAssertEqual(Policy.retryDeadline(enabledAt: 100, now: 200), 200, "an old enable gets one immediate re-capture")
        XCTAssertEqual(Policy.retryDeadline(enabledAt: nil, now: 50), 50 + Policy.retryWindowSeconds)
    }

    func testCaptureWaitStaysBounded() {
        XCTAssertLessThanOrEqual(Policy.captureWaitSeconds, 0.3)
        XCTAssertGreaterThan(Policy.retryWindowSeconds, 2.2)
    }
}

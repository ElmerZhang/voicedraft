import XCTest
@testable import VoiceDraftCore

final class InsertionTargetPolicyTests: XCTestCase {
    private typealias Snapshot = InsertionTargetPolicy.Snapshot
    private let writable = Snapshot(pid: 10, editable: true, secure: false, opaque: false, keyboardSurface: false)
    private let opaque = Snapshot(pid: 10, editable: true, secure: false, opaque: true, keyboardSurface: true)

    private func decide(_ binding: InsertionBinding, start: Snapshot?, current: Snapshot?, sameWindow: Bool = true,
                        sameElement: Bool = true, selectionMatches: Bool = true) -> InsertionTargetPolicy.Decision {
        InsertionTargetPolicy.decide(binding: binding, start: start, current: current,
                                     sameWindow: sameWindow, sameElement: sameElement, selectionMatches: selectionMatches)
    }

    func testCurrentInputFollowsAnotherAppWindowOrElement() {
        var other = writable; other.pid = 20
        XCTAssertEqual(decide(.currentInput, start: writable, current: other, sameWindow: false, sameElement: false, selectionMatches: false), .current)
        XCTAssertEqual(decide(.currentInput, start: writable, current: writable, sameWindow: false, sameElement: false), .current)
        XCTAssertEqual(decide(.currentInput, start: writable, current: writable, sameElement: false), .current)
        XCTAssertEqual(decide(.currentInput, start: nil, current: other), .current, "no start target is fine")
    }

    func testCurrentInputAcceptsOpaqueWritableFlipInTheSameWindow() {
        // A busy editor: a writable AXTextArea at start, only its AXWindow when busy at delivery, or back.
        XCTAssertEqual(decide(.currentInput, start: writable, current: opaque, sameElement: false), .current)
        XCTAssertEqual(decide(.currentInput, start: opaque, current: writable, sameElement: false), .current)
    }

    func testCurrentInputRefusesNoFocusNonEditableAndSecure() {
        XCTAssertEqual(decide(.currentInput, start: writable, current: nil), .blocked(.noFocus))
        var readOnly = writable; readOnly.editable = false
        XCTAssertEqual(decide(.currentInput, start: writable, current: readOnly), .blocked(.notEditable))
        var password = writable; password.secure = true; password.editable = false
        XCTAssertEqual(decide(.currentInput, start: writable, current: password), .blocked(.secureField))
        XCTAssertEqual(InsertionBlockReason.noFocus.message, "No text field is focused. Copy the result instead.")
        XCTAssertEqual(InsertionBlockReason.notEditable.message, InsertionBlockReason.noFocus.message)
    }

    func testSelectionBindingKeepsTheStrictChecks() {
        XCTAssertEqual(decide(.selection, start: writable, current: writable), .start)
        var other = writable; other.pid = 20
        XCTAssertEqual(decide(.selection, start: writable, current: other), .blocked(.appChanged))
        XCTAssertEqual(decide(.selection, start: writable, current: nil), .blocked(.appChanged))
        XCTAssertEqual(decide(.selection, start: nil, current: writable), .blocked(.noFocus))
        XCTAssertEqual(decide(.selection, start: writable, current: writable, sameWindow: false), .blocked(.windowChanged))
        XCTAssertEqual(decide(.selection, start: writable, current: writable, sameElement: false), .blocked(.inputChanged))
        XCTAssertEqual(decide(.selection, start: writable, current: opaque), .blocked(.inputChanged))
        var password = writable; password.secure = true
        XCTAssertEqual(decide(.selection, start: writable, current: password), .blocked(.inputChanged))
        XCTAssertEqual(decide(.selection, start: password, current: writable), .blocked(.secureField))
        XCTAssertEqual(decide(.selection, start: writable, current: writable, selectionMatches: false), .blocked(.selectionChanged))
        XCTAssertEqual(InsertionBlockReason.inputChanged.message, "The focused input changed. Copy the result when ready.")
    }

    func testFailureLocalizesThroughLocalizedMessage() {
        let failure = InsertionFailure(.appChanged, deliveryRole: "AXWindow")
        XCTAssertEqual(LocalizedMessage(error: failure), "The active app changed. Copy the result when ready.")
        XCTAssertEqual(InsertionBlockReason.secureField.rawValue, "secureField")
    }
}

import XCTest
@testable import VoiceDraftCore

final class FocusedTargetTests: XCTestCase {
    func testOpaqueIsDistinctFromDisabledSecureAndKnownNonInput() {
        for role in ["AXGroup", "AXWebArea", "AXWindow", "AXTextArea", "AXSearchField"] {
            XCTAssertEqual(TextInputCapabilities(role: role).capability, .opaque)
            XCTAssertEqual(TextInputCapabilities(role: role, secure: true).capability, .notWritable)
            XCTAssertEqual(TextInputCapabilities(role: role, enabled: false).capability, .notWritable)
        }
        for role in ["AXButton", "AXStaticText", "AXSlider", "AXLink", "AXMenuItem", ""] {
            XCTAssertEqual(TextInputCapabilities(role: role, canSetValue: true).capability, .notWritable)
        }
        XCTAssertEqual(TextInputCapabilities(role: "AXSearchField", canSetValue: true).capability, .writable)
    }

    func testOpaqueRequiresFocusedControlEnabledPasteAndNonmodalWindow() {
        let container = TextInputCapabilities(role: "AXGroup")
        XCTAssertTrue(KeyboardSurfacePolicy.acceptsOpaque(focused: container, standardWindow: true, modalWindow: false, pasteEnabled: true))
        for target in [nil, TextInputCapabilities(role: "AXWindow"), TextInputCapabilities(role: "AXButton"),
                       TextInputCapabilities(role: "AXGroup", enabled: false), TextInputCapabilities(role: "AXTextField", secure: true)] {
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: target, standardWindow: true, modalWindow: false, pasteEnabled: true))
        }
        XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: container, standardWindow: true, modalWindow: false, pasteEnabled: false))
        XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: container, standardWindow: true, modalWindow: true, pasteEnabled: true))
        XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: container, standardWindow: false, modalWindow: false, pasteEnabled: true))
    }

    func testFindsFocusedDescendantButNeverUnfocusedEditor() {
        func resolve(focus: Int) -> Int? {
            FocusedInputResolver.focusedTarget(from: 0,
                capabilities: { TextInputCapabilities(role: $0 == 0 ? "AXGroup" : "AXTextField", canSetValue: true) },
                nestedFocus: { _ in nil }, children: { $0 == 0 ? [1, 2] : [] },
                isFocused: { $0 == focus }, equals: ==)
        }
        XCTAssertEqual(resolve(focus: 2), 2)
        XCTAssertEqual(resolve(focus: 9), 0)
    }

    func testNestedFocusCycleAndProtectedTarget() {
        let cycle = FocusedInputResolver.focusedTarget(from: 0,
            capabilities: { _ in TextInputCapabilities(role: "AXGroup") },
            nestedFocus: { 1 - $0 }, children: { _ in [] }, isFocused: { _ in false }, equals: ==)
        XCTAssertNil(cycle)
        for traits in [TextInputCapabilities(role: "AXTextField", secure: true),
                       TextInputCapabilities(role: "AXGroup", enabled: false), TextInputCapabilities(role: "AXButton")] {
            XCTAssertEqual(FocusedInputResolver.focusedTarget(from: 0, capabilities: { _ in traits },
                nestedFocus: { _ in XCTFail("Must stop at protected control"); return 1 },
                children: { _ in XCTFail("Must not search siblings"); return [] }, isFocused: { _ in true }, equals: ==), 0)
        }
    }

    func testTraversalStopsAtNodeAndTimeBudgets() {
        var visits = 0
        _ = FocusedInputResolver.focusedTarget(from: 0,
            capabilities: { _ in visits += 1; return TextInputCapabilities(role: "AXGroup") },
            nestedFocus: { _ in nil }, children: { [$0 + 1] }, isFocused: { _ in false }, equals: ==, limit: 4)
        XCTAssertLessThanOrEqual(visits, 4)
        var time: Double = 0
        XCTAssertNil(FocusedInputResolver.focusedTarget(from: 0,
            capabilities: { _ in XCTFail("Expired search"); return TextInputCapabilities(role: "AXGroup") },
            nestedFocus: { _ in nil }, children: { _ in [] }, isFocused: { _ in false }, equals: ==,
            seconds: 0.5, now: { time += 1; return time }))
    }
}

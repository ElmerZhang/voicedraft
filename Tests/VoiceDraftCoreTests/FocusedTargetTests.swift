import XCTest
@testable import VoiceDraftCore

final class FocusedTargetTests: XCTestCase {
    func testOpaqueIsDistinctFromDisabledSecureAndKnownNonInput() {
        for role in ["AXGroup", "AXWebArea", "AXWindow", "AXTextArea", "AXSearchField", "AXCell", "AXUnknown",
                     "AXLayoutArea", "AXScrollArea", "AXSplitGroup", "AXList", "AXOutline", "AXTable", "AXRow",
                     "AXBrowser", "AXSheet", "AXDrawer", "AXDocument", "GPUICustomCanvas", ""] {
            XCTAssertEqual(TextInputCapabilities(role: role).capability, .opaque, role)
            XCTAssertEqual(TextInputCapabilities(role: role, secure: true).capability, .notWritable, role)
            XCTAssertEqual(TextInputCapabilities(role: role, enabled: false).capability, .notWritable, role)
        }
        XCTAssertEqual(TextInputCapabilities(role: "AXSearchField", canSetValue: true).capability, .writable)
    }

    func testEveryDenylistedRoleIsKnownNonInput() {
        XCTAssertEqual(TextInputCapabilities.nonInputRoles.count, 34)
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXRadioGroup", "AXPopUpButton", "AXMenuButton",
                     "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXSlider", "AXIncrementor",
                     "AXProgressIndicator", "AXBusyIndicator", "AXLevelIndicator", "AXDisclosureTriangle",
                     "AXColorWell", "AXScrollBar", "AXSplitter", "AXHandle", "AXGrowArea", "AXValueIndicator",
                     "AXStaticText", "AXLink", "AXImage", "AXHeading", "AXToolbar", "AXTabGroup", "AXDockItem",
                     "AXRuler", "AXRulerMarker", "AXHelpTag", "AXMatte", "AXRelevanceIndicator"] {
            XCTAssertTrue(TextInputCapabilities.nonInputRoles.contains(role), role)
            // Settable attributes never turn a known non-input into a target.
            XCTAssertEqual(TextInputCapabilities(role: role, canSetValue: true).capability, .notWritable, role)
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: .init(role: role), focusedWindow: true), role)
        }
    }

    func testOpaqueFocusIsPastedIntoWheneverAFocusedWindowExists() {
        for focused in [TextInputCapabilities(role: "AXGroup"), .init(role: "AXWindow"), .init(role: "AXCell"),
                        .init(role: "AXWebArea"), .init(role: "AXTextArea"), .init(role: "CustomRole")] {
            XCTAssertTrue(KeyboardSurfacePolicy.acceptsOpaque(focused: focused, focusedWindow: true), focused.role)
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: focused, focusedWindow: false), focused.role)
        }
        // No focused element at all: the focused window is the target; without one, nothing.
        XCTAssertTrue(KeyboardSurfacePolicy.acceptsOpaque(focused: nil, focusedWindow: true))
        XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: nil, focusedWindow: false))
        for refused in [TextInputCapabilities(role: "AXButton"), .init(role: "AXGroup", enabled: false),
                        .init(role: "AXTextField", secure: true), .init(role: "AXWindow", secure: true),
                        .init(role: "AXTextField", canSetValue: true)] {
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: refused, focusedWindow: true), refused.role)
        }
    }

    /// Herdr UI (GPUI) as probed on 2026-10-16: the focused element is its standard,
    /// nonmodal AXWindow with no children, and its Edit > Paste item reports disabled.
    /// Neither the window subrole nor the menu matters any more.
    func testHerdrWindowOnlyFocusIsAccepted() {
        let window = TextInputCapabilities(role: "AXWindow")
        XCTAssertEqual(window.capability, .opaque)
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "so.pen.herdr-gpui", focused: window, editor: nil,
            standardWindow: true, modalWindow: false), "not a listed terminal")
        XCTAssertTrue(KeyboardSurfacePolicy.acceptsOpaque(focused: window, focusedWindow: true))
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

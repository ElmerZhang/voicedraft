import XCTest
@testable import VoiceDraftCore

final class InputFocusTests: XCTestCase {
    /// WeChat 4.x exposes only its main window or standard containers; it is
    /// now ordinary opaque input with no title, bundle or Paste-menu rule.
    func testWeChatWindowOnlyFocusUsesTheGenericOpaquePath() {
        for focused in [nil, TextInputCapabilities(role: "AXWindow"), .init(role: "AXGroup")] {
            XCTAssertTrue(KeyboardSurfacePolicy.acceptsOpaque(focused: focused, focusedWindow: true))
        }
        for focused in [TextInputCapabilities(role: "AXButton"), .init(role: "AXStaticText"),
                        .init(role: "AXGroup", enabled: false), .init(role: "AXGroup", secure: true)] {
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaque(focused: focused, focusedWindow: true), focused.role)
        }
    }

    private struct Node {
        var traits: TextInputCapabilities
        var parent: Int?
    }
    private func resolve(_ focus: Int, _ tree: [Int: Node]) -> Int? {
        FocusedInputResolver.resolve(from: focus, capabilities: { tree[$0]!.traits }, parent: { tree[$0]!.parent }, equals: ==)
    }
    func testReplacingFocusedParagraphKeepsSameEditorButNotAnotherField() {
        let tree: [Int: Node] = [
            0: .init(traits: .init(role: "AXWebArea"), parent: nil),
            1: .init(traits: .init(role: "AXTextArea", canSetSelectionRange: true), parent: 0),
            2: .init(traits: .init(role: "AXStaticText", canReplaceSelection: true), parent: 1),
            3: .init(traits: .init(role: "AXGroup"), parent: 1),
            4: .init(traits: .init(role: "AXTextArea", canSetValue: true), parent: 0)
        ]
        XCTAssertEqual(resolve(2, tree), 1)
        XCTAssertEqual(resolve(3, tree), 1)
        XCTAssertEqual(resolve(4, tree), 4)
        XCTAssertNotEqual(resolve(2, tree), resolve(4, tree))
    }
    func testStaticPageTextAndButtonsCannotBorrowAnEditorsEligibility() {
        let tree: [Int: Node] = [
            0: .init(traits: .init(role: "AXWebArea"), parent: nil),
            1: .init(traits: .init(role: "AXStaticText", canReplaceSelection: true), parent: 0),
            2: .init(traits: .init(role: "AXTextArea", canSetValue: true), parent: 0),
            3: .init(traits: .init(role: "AXButton"), parent: 2)
        ]
        XCTAssertNil(resolve(1, tree))
        XCTAssertNil(resolve(3, tree))
        XCTAssertFalse(tree[1]!.traits.acceptsInsertion)
    }
    func testNearestDisabledOrSecureInputIsNotSkippedAndCyclesTerminate() {
        let tree: [Int: Node] = [
            0: .init(traits: .init(role: "AXTextArea", canSetValue: true), parent: nil),
            1: .init(traits: .init(role: "AXTextField", secure: true, canSetValue: true), parent: 0),
            2: .init(traits: .init(role: "AXGroup"), parent: 1),
            3: .init(traits: .init(role: "AXTextField", enabled: false, canSetValue: true), parent: 0),
            4: .init(traits: .init(role: "AXGroup"), parent: 4)
        ]
        XCTAssertEqual(resolve(2, tree), 1)
        XCTAssertFalse(tree[resolve(2, tree)!]!.traits.acceptsInsertion)
        XCTAssertEqual(resolve(3, tree), 3)
        XCTAssertNil(resolve(4, tree))
    }
    func testEmptyEditorCanPublishZeroCaretAfterInitialFocus() {
        XCTAssertTrue(InputSelectionPolicy.matches(originalRange: nil, originalText: "", originalValue: "",
            currentRange: NSRange(location: 0, length: 0), currentText: "", currentValue: "", keyboardSurface: false))
        for value in [Optional<String>.none, "existing draft"] {
            XCTAssertFalse(InputSelectionPolicy.matches(originalRange: nil, originalText: "", originalValue: value,
                currentRange: NSRange(location: 0, length: 0), currentText: "", currentValue: value, keyboardSurface: false))
        }
    }
    func testCaretMovementInEditorsAndChangedSelectionsStillBlockInsertion() {
        XCTAssertFalse(InputSelectionPolicy.matches(originalRange: NSRange(location: 1, length: 0), originalText: "", originalValue: "abc",
            currentRange: NSRange(location: 2, length: 0), currentText: "", currentValue: "abc", keyboardSurface: false))
        XCTAssertFalse(InputSelectionPolicy.matches(originalRange: NSRange(location: 1, length: 2), originalText: "bc", originalValue: nil,
            currentRange: NSRange(location: 4, length: 2), currentText: "bc", currentValue: nil, keyboardSurface: true))
        XCTAssertFalse(InputSelectionPolicy.matches(originalRange: nil, originalText: "old", originalValue: nil,
            currentRange: nil, currentText: "new", currentValue: nil, keyboardSurface: true))
    }
    func testTerminalOutputOffsetsCanMoveWithoutMovingTheKeyboardDestination() {
        XCTAssertTrue(InputSelectionPolicy.matches(originalRange: NSRange(location: 90, length: 0), originalText: "", originalValue: nil,
            currentRange: NSRange(location: 120, length: 0), currentText: "", currentValue: nil, keyboardSurface: true))
    }
    func testWarpCompatibilityIsLimitedToNonmodalTerminalSurfaces() {
        let canvas = TextInputCapabilities(role: "AXGroup")
        let grid = TextInputCapabilities(role: "AXTextArea", canSetSelectionRange: true)
        XCTAssertTrue(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: canvas, editor: nil,
            standardWindow: true, modalWindow: false))
        XCTAssertTrue(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: grid, editor: grid,
            standardWindow: true, modalWindow: false))
        XCTAssertTrue(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: nil, editor: nil,
            standardWindow: true, modalWindow: false))
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "other.app", focused: canvas, editor: nil,
            standardWindow: true, modalWindow: false))
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: canvas, editor: nil,
            standardWindow: true, modalWindow: true))
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: canvas, editor: nil,
            standardWindow: false, modalWindow: false))
    }
    /// Ghostty's surface as probed on 2026-10-16: an AXTextArea whose value is the
    /// screen text, with no settable value or selection range, in a standard window.
    func testGhosttyReadOnlyTextAreaUsesTheTerminalPath() {
        let surface = TextInputCapabilities(role: "AXTextArea")
        XCTAssertEqual(surface.capability, .opaque, "nothing settable: never a writable editor")
        XCTAssertTrue(KeyboardSurfacePolicy.accepts(bundleIdentifier: "com.mitchellh.ghostty", focused: surface, editor: surface,
            standardWindow: true, modalWindow: false))
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "com.mitchellh.ghostty", focused: surface, editor: surface,
            standardWindow: false, modalWindow: false), "quick terminal panels and sheets stay out")
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "com.mitchellh.ghostty", focused: surface, editor: surface,
            standardWindow: true, modalWindow: true))
        for traits in [TextInputCapabilities(role: "AXTextField"), .init(role: "AXTextArea", canSetValue: true),
                       .init(role: "AXTextArea", secure: true), .init(role: "AXButton")] {
            XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "com.mitchellh.ghostty", focused: traits,
                editor: traits.isTextControl ? traits : nil, standardWindow: true, modalWindow: false))
        }
        XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "com.apple.Terminal", focused: surface, editor: surface,
            standardWindow: true, modalWindow: false), "only listed terminals use the path")
    }
    func testWarpButtonsFormsDisabledAndSecureInputsDoNotUseTerminalFallback() {
        for traits in [TextInputCapabilities(role: "AXButton"), .init(role: "AXTextField"),
                       .init(role: "AXTextArea", canSetValue: true), .init(role: "AXGroup", enabled: false),
                       .init(role: "AXTextArea", secure: true)] {
            XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: traits,
                editor: traits.isTextControl ? traits : nil, standardWindow: true, modalWindow: false))
        }
    }
}

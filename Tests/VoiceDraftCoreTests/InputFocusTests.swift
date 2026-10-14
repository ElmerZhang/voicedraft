import XCTest
@testable import VoiceDraftCore

final class InputFocusTests: XCTestCase {
    func testOpaqueWeChatMainWindowWithPasteCanReceiveKeyboardInput() {
        for title in ["Weixin", "WeChat", "微信"] {
            for focused in [nil, TextInputCapabilities(role: "AXWindow"), .init(role: "AXGroup")] {
                XCTAssertTrue(KeyboardSurfacePolicy.acceptsOpaqueWeChat(bundleIdentifier: "com.tencent.xinWeChat",
                    focused: focused, editor: nil, standardWindow: true, modalWindow: false,
                    windowTitle: title, pasteAvailable: true))
            }
        }
    }

    func testOpaqueWeChatFallbackRejectsOtherAppsDialogsAndUnavailablePaste() {
        for (bundle, standard, modal, title, paste) in [
            ("other.app", true, false, "Weixin", true),
            ("com.tencent.xinWeChat", false, false, "Weixin", true),
            ("com.tencent.xinWeChat", true, true, "Weixin", true),
            ("com.tencent.xinWeChat", true, false, "Photos and Videos", true),
            ("com.tencent.xinWeChat", true, false, "Weixin", false)
        ] {
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaqueWeChat(bundleIdentifier: bundle,
                focused: nil, editor: nil, standardWindow: standard, modalWindow: modal,
                windowTitle: title, pasteAvailable: paste))
        }
    }

    func testWeChatExposedFieldsAndUnsafeFocusKeepNormalInputRules() {
        for focused in [TextInputCapabilities(role: "AXButton"), .init(role: "AXStaticText"),
                        .init(role: "AXTextField"), .init(role: "AXTextArea", canSetValue: true),
                        .init(role: "AXGroup", enabled: false), .init(role: "AXGroup", secure: true)] {
            XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaqueWeChat(bundleIdentifier: "com.tencent.xinWeChat",
                focused: focused, editor: nil, standardWindow: true, modalWindow: false,
                windowTitle: "Weixin", pasteAvailable: true))
        }
        XCTAssertFalse(KeyboardSurfacePolicy.acceptsOpaqueWeChat(bundleIdentifier: "com.tencent.xinWeChat",
            focused: .init(role: "AXGroup"), editor: .init(role: "AXTextArea"),
            standardWindow: true, modalWindow: false, windowTitle: "Weixin", pasteAvailable: true))
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
    func testWarpButtonsFormsDisabledAndSecureInputsDoNotUseTerminalFallback() {
        for traits in [TextInputCapabilities(role: "AXButton"), .init(role: "AXTextField"),
                       .init(role: "AXTextArea", canSetValue: true), .init(role: "AXGroup", enabled: false),
                       .init(role: "AXTextArea", secure: true)] {
            XCTAssertFalse(KeyboardSurfacePolicy.accepts(bundleIdentifier: "dev.warp.Warp-Stable", focused: traits,
                editor: traits.isTextControl ? traits : nil, standardWindow: true, modalWindow: false))
        }
    }
}

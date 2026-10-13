import XCTest
@testable import VoiceDraftCore

final class TextInputCapabilitiesTests: XCTestCase {
    func testWebEditorWithReadOnlyTextAttributesStillAcceptsPaste() {
        // Chromium allows moving an editable field's caret via AX even when its
        // value/selected text cannot be set. Requiring either text setter regressed paste.
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            let editor = TextInputCapabilities(role: role, canSetSelectionRange: true)
            XCTAssertTrue(editor.acceptsInsertion, role)
        }
    }

    func testExistingNativeTextInsertionCapabilitiesRemainSupported() {
        XCTAssertTrue(TextInputCapabilities(role: "AXTextField", canSetValue: true).acceptsInsertion)
        XCTAssertTrue(TextInputCapabilities(role: "AXTextArea", canReplaceSelection: true).acceptsInsertion)
    }

    func testSelectablePageContentAndNonTextControlsAreNotPasteTargets() {
        for role in ["AXStaticText", "AXWebArea", "AXGroup", "AXButton", "AXSlider", ""] {
            XCTAssertFalse(TextInputCapabilities(role: role, canSetValue: true, canSetSelectionRange: true).acceptsInsertion, role)
        }
        XCTAssertFalse(TextInputCapabilities(role: "AXTextArea").acceptsInsertion)
    }

    func testDisabledAndPasswordFieldsStayExcludedEvenWithWritableAttributes() {
        XCTAssertFalse(TextInputCapabilities(role: "AXTextArea", enabled: false,
            canReplaceSelection: true, canSetValue: true, canSetSelectionRange: true).acceptsInsertion)
        XCTAssertFalse(TextInputCapabilities(role: "AXTextField", secure: true,
            canReplaceSelection: true, canSetValue: true, canSetSelectionRange: true).acceptsInsertion)
    }
}

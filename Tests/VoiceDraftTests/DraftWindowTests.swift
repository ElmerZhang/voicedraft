import AppKit
import XCTest
@testable import VoiceDraft
import VoiceDraftCore

/// Draft-versus-external routing decisions (pure).
final class DraftRoutingTests: XCTestCase {
    private let id = UUID()
    private func focus(_ text: String, _ selection: NSRange) -> DraftFocus { DraftFocus(documentID: id, text: text, selection: selection) }

    func testDraftFocusNeedsActiveAppKeyWindowAndEditor() {
        XCTAssertTrue(DraftRouting.isDraftFocus(appActive: true, draftWindowIsKey: true, editorIsFirstResponder: true))
        XCTAssertFalse(DraftRouting.isDraftFocus(appActive: false, draftWindowIsKey: true, editorIsFirstResponder: true))
        XCTAssertFalse(DraftRouting.isDraftFocus(appActive: true, draftWindowIsKey: false, editorIsFirstResponder: true))
        XCTAssertFalse(DraftRouting.isDraftFocus(appActive: true, draftWindowIsKey: true, editorIsFirstResponder: false))
    }

    func testDictationRunCarriesThePassageContext() throws {
        let run = try DraftRouting.run(for: .polish, focus: focus("前文。后文。", NSRange(location: 3, length: 0)))
        XCTAssertEqual(run.kind, .dictation); XCTAssertEqual(run.binding, .caret); XCTAssertEqual(run.source, .draftWriting)
        XCTAssertEqual(run.context, .passage(before: "前文。", after: "后文。"))
        XCTAssertEqual(run.selectedText, "")
    }

    func testEditTargetsTheSelectionOrTheWholeDraft() throws {
        let selection = try DraftRouting.run(for: .edit, focus: focus("第一段。\n\n第二段。", NSRange(location: 6, length: 4)))
        XCTAssertEqual(selection.kind, .selectionEdit); XCTAssertEqual(selection.selectedText, "第二段。")
        XCTAssertEqual(selection.binding, .range(NSRange(location: 6, length: 4), expected: "第二段。"))
        XCTAssertNil(selection.context); XCTAssertEqual(selection.source, .draftEdit)

        let whole = try DraftRouting.run(for: .edit, focus: focus("第一段。\n\n第二段。", NSRange(location: 3, length: 0)))
        XCTAssertEqual(whole.kind, .wholeDraftEdit); XCTAssertEqual(whole.context, .wholeDraft)
        XCTAssertEqual(whole.selectedText, "第一段。\n\n第二段。")
        XCTAssertEqual(whole.binding, .range(NSRange(location: 0, length: 10), expected: "第一段。\n\n第二段。"))
        // The Edit guard ("Select text in the destination app…") never applies: a blank draft has its own message.
        XCTAssertThrowsError(try DraftRouting.run(for: .edit, focus: focus(" \n", NSRange(location: 0, length: 0)))) { error in
            XCTAssertEqual(LocalizedMessage(error: error).key, "The draft is empty. Dictate a paragraph first.")
        }
    }

    func testAskUsesTheSelectionAsReferenceAndNeverWrites() throws {
        let run = try DraftRouting.run(for: .ask, focus: focus("abc", NSRange(location: 1, length: 1)))
        XCTAssertEqual(run.selectedText, "b")
        XCTAssertEqual(DraftRouting.delivery(run: run, mode: .ask, editorFocusedNow: true), .external)
    }

    func testDeliveryFollowsTheFocusUnlessBound() throws {
        let caret = try DraftRouting.run(for: .polish, focus: focus("x", NSRange(location: 1, length: 0)))
        let bound = try DraftRouting.run(for: .edit, focus: focus("x", NSRange(location: 0, length: 1)))
        // Started in the draft: still focused → caret; focus moved to another app → external (delivery-time focus).
        XCTAssertEqual(DraftRouting.delivery(run: caret, mode: .polish, editorFocusedNow: true), .caret)
        XCTAssertEqual(DraftRouting.delivery(run: caret, mode: .polish, editorFocusedNow: false), .external)
        // Started elsewhere, the draft editor is the focus now → caret.
        XCTAssertEqual(DraftRouting.delivery(run: nil, mode: .translate, editorFocusedNow: true), .caret)
        XCTAssertEqual(DraftRouting.delivery(run: nil, mode: .polish, editorFocusedNow: false), .external)
        // Edit (and style apply, re-polish) stay bound to their draft range wherever the focus is.
        XCTAssertEqual(DraftRouting.delivery(run: bound, mode: .edit, editorFocusedNow: false), .bound)
        XCTAssertEqual(DraftRouting.delivery(run: bound, mode: .edit, editorFocusedNow: true), .bound)
    }

    func testStyleAndRepolishRuns() {
        XCTAssertNil(DraftRouting.styleRun(focus: focus("abc", NSRange(location: 1, length: 0))))
        let style = DraftRouting.styleRun(focus: focus("abc", NSRange(location: 1, length: 1)))
        XCTAssertEqual(style?.kind, .styleApply); XCTAssertEqual(style?.binding, .range(NSRange(location: 1, length: 1), expected: "b"))
        XCTAssertEqual(style?.source, .draftStyleApply)

        let take = DraftTake(range: NSRange(location: 6, length: 4), transcript: "嗯第二段", result: "第二段。", kind: .dictation)
        let run = DraftRouting.repolishRun(documentID: id, take: take, text: "第一段。\n\n第二段。")
        XCTAssertEqual(run?.kind, .repolish); XCTAssertEqual(run?.source, .draftRepolish)
        XCTAssertEqual(run?.context, .passage(before: "第一段。\n\n", after: ""))
        XCTAssertNil(DraftRouting.repolishRun(documentID: id, take: take, text: "第一段。\n\n第二段！"), "not intact")
        var edit = take; edit.kind = .selectionEdit
        XCTAssertNil(DraftRouting.repolishRun(documentID: id, take: edit, text: "第一段。\n\n第二段。"), "instructions are not re-polished")
    }
}

/// Programmatic draft writes through a real NSTextView: one undo step per take, take records and ranges.
final class DraftWorkspaceTests: XCTestCase {
    /// Ends the current run-loop pass, as a real event does, so NSUndoManager closes its by-event group.
    @MainActor private func nextEvent() { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }

    @MainActor
    private func makeWorkspace(text: String = "") -> (DraftWorkspace, NSTextView, NSWindow) {
        let workspace = DraftWorkspace(store: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.isRichText = false; textView.allowsUndo = true
        window.contentView = textView
        workspace.attach(textView)
        if !text.isEmpty {
            textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            textView.breakUndoCoalescing()
            nextEvent()
        }
        return (workspace, textView, window)
    }

    func testDictationIsOneUndoStepAndRecordsTheTake() async throws {
        try await MainActor.run {
            let (workspace, textView, window) = makeWorkspace(text: "第一段。")
            defer { window.close() }
            textView.setSelectedRange(NSRange(location: 4, length: 0))
            try workspace.insertDictation("第二段。", transcript: "嗯第二段", historyID: nil, mode: .polish)
            nextEvent()
            XCTAssertEqual(textView.string, "第一段。\n\n第二段。")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 0))
            XCTAssertTrue(workspace.canUndoLastTake); XCTAssertTrue(workspace.canRepolishLastTake)
            XCTAssertEqual(workspace.repolishRun()?.binding, .range(NSRange(location: 6, length: 4), expected: "第二段。"))
            // Command-Z reverts the whole take in one step.
            let undo = try XCTUnwrap(textView.undoManager)
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            XCTAssertEqual(textView.string, "第一段。")
        }
    }

    func testUndoLastTakeButtonAndKeyboardEditsDisableIt() async throws {
        try await MainActor.run {
            let (workspace, textView, window) = makeWorkspace()
            defer { window.close() }
            try workspace.insertDictation("Alpha.", transcript: "alpha", historyID: nil, mode: .polish)
            nextEvent()
            try workspace.insertDictation("Beta.", transcript: "beta", historyID: nil, mode: .polish)
            nextEvent()
            XCTAssertEqual(textView.string, "Alpha.\n\nBeta.")
            workspace.undoLastTake()
            XCTAssertEqual(textView.string, "Alpha.", "only the last take is undone")
            // After a keyboard edit the last take is no longer the latest undoable action.
            nextEvent()
            try workspace.insertDictation("Gamma.", transcript: "gamma", historyID: nil, mode: .polish)
            nextEvent()
            XCTAssertTrue(workspace.canUndoLastTake)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.insertText("X", replacementRange: textView.selectedRange())
            XCTAssertFalse(workspace.canUndoLastTake)
            // The take moved with the edit, so it can still be re-polished.
            XCTAssertTrue(workspace.canRepolishLastTake)
            XCTAssertEqual(workspace.repolishRun()?.binding, .range(NSRange(location: 9, length: 6), expected: "Gamma."))
        }
    }

    func testBoundReplaceRefusesAChangedRangeAndKeepsTheDraft() async throws {
        try await MainActor.run {
            let (workspace, textView, window) = makeWorkspace(text: "第一段。\n\n第二段。")
            defer { window.close() }
            let documentID = try XCTUnwrap(workspace.currentID)
            let focus = DraftFocus(documentID: documentID, text: textView.string, selection: NSRange(location: 6, length: 4))
            let run = try DraftRouting.run(for: .edit, focus: focus)
            // The user edits the selected paragraph while the instruction is processing.
            textView.setSelectedRange(NSRange(location: 9, length: 0))
            textView.insertText("！", replacementRange: NSRange(location: 9, length: 1))
            nextEvent()
            XCTAssertThrowsError(try workspace.replace(run, with: "第二段（改）。", transcript: "改一下", historyID: nil, mode: .edit))
            XCTAssertEqual(textView.string, "第一段。\n\n第二段！", "a refused write leaves the draft unchanged")

            let fresh = try DraftRouting.run(for: .edit, focus: DraftFocus(documentID: documentID, text: textView.string,
                                                                              selection: NSRange(location: 0, length: 0)))
            XCTAssertEqual(fresh.kind, .wholeDraftEdit)
            try workspace.replace(fresh, with: "全文改写。", transcript: "整体改写", historyID: nil, mode: .edit)
            nextEvent()
            XCTAssertEqual(textView.string, "全文改写。")
            textView.undoManager?.undo()
            XCTAssertEqual(textView.string, "第一段。\n\n第二段！", "the whole-draft edit is one undo step")
        }
    }

    func testNoTextViewMeansNoWrite() async throws {
        try await MainActor.run {
            let workspace = DraftWorkspace(store: nil)
            XCTAssertNil(workspace.focus())
            XCTAssertThrowsError(try workspace.insertDictation("x", transcript: "x", historyID: nil, mode: .polish))
        }
    }
}

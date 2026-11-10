import Foundation
import VoiceDraftCore

/// The draft editor's state when a take starts: the open draft, its whole text
/// and the selection (UTF-16). Read from the text view, never through Accessibility.
struct DraftFocus: Equatable {
    let documentID: UUID
    let text: String
    let selection: NSRange
    var selectedText: String {
        let ns = text as NSString
        guard selection.location != NSNotFound, selection.length > 0, selection.location + selection.length <= ns.length else { return "" }
        return ns.substring(with: selection)
    }
}

/// A take's relation to the draft window, decided when it starts.
struct DraftRun: Equatable {
    enum Binding: Equatable {
        /// Ordinary dictation: inserted at the caret current at delivery, by `DraftText.insertion`.
        case caret
        /// Edit, style apply, re-polish: replaces `range` of the run's draft, and only
        /// while that range still holds `expected` (no focus needed: it is VoiceDraft's own document).
        case range(NSRange, expected: String)
    }
    let documentID: UUID
    var kind: DraftTakeKind
    var binding: Binding
    /// Context for the writing request (the long-form Polish passage, or the whole-draft Edit).
    var context: DraftWritingContext?
    /// Text the writing request receives as `selected_text` (Edit and Ask).
    var selectedText: String
    var source: ModelUsageSource
    /// The editor state at the start, so a Fn chord can switch between dictation and Edit.
    let focus: DraftFocus
}

/// Pure decisions behind the draft window's routing; AppState applies them.
enum DraftRouting {
    /// `startRole`/`deliveryRole` in takes.jsonl for a take written into the draft.
    static let targetRole = "VoiceDraftDraft"
    /// History's application name for draft takes (stored as data, like "VoiceDraft").
    static let applicationName = "VoiceDraft Draft"

    /// A take is a draft take when VoiceDraft is active, the draft window is key
    /// and its text view is the first responder.
    static func isDraftFocus(appActive: Bool, draftWindowIsKey: Bool, editorIsFirstResponder: Bool) -> Bool {
        appActive && draftWindowIsKey && editorIsFirstResponder
    }

    /// The run of a take started in `mode` while the draft editor has `focus`.
    /// Edit with a selection edits it; Edit with nothing selected edits the whole
    /// draft and throws when the draft is blank.
    static func run(for mode: WritingMode, focus: DraftFocus) throws -> DraftRun {
        let selected = focus.selectedText
        switch mode {
        case .edit where !selected.isEmpty:
            return DraftRun(documentID: focus.documentID, kind: .selectionEdit, binding: .range(focus.selection, expected: selected),
                            context: nil, selectedText: selected, source: .draftEdit, focus: focus)
        case .edit:
            guard !focus.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceDraftError.message("The draft is empty. Dictate a paragraph first.")
            }
            let whole = NSRange(location: 0, length: (focus.text as NSString).length)
            return DraftRun(documentID: focus.documentID, kind: .wholeDraftEdit, binding: .range(whole, expected: focus.text),
                            context: .wholeDraft, selectedText: focus.text, source: .draftEdit, focus: focus)
        case .ask:
            // Ask never writes into the draft; the selection is its reference text.
            return DraftRun(documentID: focus.documentID, kind: .dictation, binding: .caret, context: nil,
                            selectedText: selected, source: .dictationWriting, focus: focus)
        case .polish, .verbatim, .translate:
            return DraftRun(documentID: focus.documentID, kind: .dictation, binding: .caret,
                            context: .passage(at: focus.selection, in: focus.text), selectedText: "", source: .draftWriting, focus: focus)
        }
    }

    /// A writing style applied to the draft's selection; nil when nothing is selected.
    static func styleRun(focus: DraftFocus) -> DraftRun? {
        let selected = focus.selectedText
        guard !selected.isEmpty else { return nil }
        return DraftRun(documentID: focus.documentID, kind: .styleApply, binding: .range(focus.selection, expected: selected),
                        context: .passage(at: focus.selection, in: focus.text), selectedText: "", source: .draftStyleApply, focus: focus)
    }

    /// Re-polish of `take`, which must still be intact in `text`.
    static func repolishRun(documentID: UUID, take: DraftTake, text: String) -> DraftRun? {
        guard take.canRepolish, DraftText.holds(take, in: text) else { return nil }
        let focus = DraftFocus(documentID: documentID, text: text, selection: take.range)
        return DraftRun(documentID: documentID, kind: .repolish, binding: .range(take.range, expected: take.result),
                        context: .passage(at: take.range, in: text), selectedText: "", source: .draftRepolish, focus: focus)
    }

    enum Delivery: Equatable {
        /// The existing external path (paste into the focus current now, or the result card).
        case external
        /// Insert at the draft editor's caret, which is the focus now.
        case caret
        /// Replace the range bound at the start in the run's draft.
        case bound
    }

    /// Where a finished take's text goes. Range-bound runs always write into
    /// their draft. Otherwise the delivery-time focus rule applies: when the
    /// draft editor is the focus now (whether the take started there or not),
    /// the text goes in at its caret; any other focus takes the external path.
    /// Ask never writes into the draft.
    static func delivery(run: DraftRun?, mode: WritingMode, editorFocusedNow: Bool) -> Delivery {
        if let run, case .range = run.binding { return .bound }
        if mode == .ask { return .external }
        return editorFocusedNow ? .caret : .external
    }
}

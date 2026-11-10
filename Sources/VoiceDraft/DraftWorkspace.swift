import AppKit
import VoiceDraftCore

/// Coordinator of the draft window: the open draft, its text view, take records
/// and persistence through `DraftStore`. Views call it; AppState routes takes to
/// it. Every programmatic write goes through the text view's text storage with
/// `shouldChangeText`/`didChangeText`, so Command-Z reverts a take in one step,
/// and is never sent through the pasteboard or a synthetic key event.
@MainActor
final class DraftWorkspace: NSObject, ObservableObject {
    enum SaveState: Equatable { case saved, pending, failed }

    /// Every draft, most recently updated first. The open draft's entry is refreshed on save.
    @Published private(set) var documents: [DraftDocument] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var characterCount = 0
    @Published private(set) var saveState = SaveState.saved
    @Published private(set) var canUndoLastTake = false
    @Published private(set) var canRepolishLastTake = false
    /// One-line feedback in the status line (copied, exported, errors).
    @Published var notice = ""

    private let store: DraftStore?
    private(set) weak var textView: NSTextView?
    /// The open draft. Its `text` is synced from the text view on save; its takes are live.
    private var current = DraftDocument()
    /// True when `current` exists on disk (a new blank draft is kept in memory only).
    private var currentSaved = false
    private var saveTask: Task<Void, Never>?
    /// Set while the workspace itself edits or loads the text view.
    private var programmatic = false
    private var loading = false
    /// The latest undoable action of the text view is the last take.
    private var takeIsLatestUndo = false
    private var undoObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    /// The last other app that was active; snapshotted as `previousApplication`
    /// when the draft window becomes key.
    private(set) var lastExternalApplication: NSRunningApplication?
    private(set) var previousApplication: NSRunningApplication?

    static let saveDelay: UInt64 = 1_000_000_000

    init(store: DraftStore?) {
        self.store = store
        super.init()
        reload()
        guard store != nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.noteActivation(app) }
        }
    }

    /// The default store under Application Support/VoiceDraft/drafts.
    static func defaultStore() -> FileDraftStore {
        FileDraftStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDraft/drafts", isDirectory: true))
    }

    // MARK: Documents

    private func reload() {
        documents = (try? store?.list()) ?? []
        if let first = documents.first { open(first, saved: true) } else { open(DraftDocument(), saved: false) }
    }

    var currentText: String { textView?.string ?? current.text }
    var currentTitle: String { DraftDocument(text: currentText).displayTitle }

    /// Starts a new blank draft; it is saved once it has text.
    func newDraft() {
        saveNow()
        dropBlankUnsavedDraft()
        open(DraftDocument(), saved: false)
        focusEditor()
    }

    func select(_ id: UUID) {
        guard id != currentID, let document = documents.first(where: { $0.id == id }) else { return }
        saveNow()
        dropBlankUnsavedDraft()
        open(document, saved: true)
    }

    func delete(_ id: UUID) {
        do { try store?.delete(id) } catch { notice = D("Could not delete the draft."); return }
        documents.removeAll { $0.id == id }
        if id == currentID {
            saveTask?.cancel(); saveTask = nil
            if let next = documents.first { open(next, saved: true) } else { open(DraftDocument(), saved: false) }
        }
    }

    private func dropBlankUnsavedDraft() {
        if !currentSaved, currentText.isEmpty { documents.removeAll { $0.id == current.id } }
    }

    private func open(_ document: DraftDocument, saved: Bool) {
        current = document; currentSaved = saved; currentID = document.id
        if !documents.contains(where: { $0.id == document.id }) { documents.insert(document, at: 0) }
        saveState = .saved; takeIsLatestUndo = false
        if let textView {
            loading = true
            textView.string = document.text
            loading = false
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: (document.text as NSString).length, length: 0))
        }
        refresh()
    }

    // MARK: Text view

    func attach(_ textView: NSTextView) {
        self.textView = textView
        textView.delegate = self
        textView.textStorage?.delegate = self
        loading = true
        textView.string = current.text
        loading = false
        textView.setSelectedRange(NSRange(location: (current.text as NSString).length, length: 0))
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self, let manager = note.object as? UndoManager, manager === self.textView?.undoManager else { return }
                    self.takeIsLatestUndo = false; self.refresh()
                }
            }
        }
        refresh()
    }

    func focusEditor() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    /// The window became key: the app that was active before is the "previous app".
    func windowDidBecomeKey() {
        previousApplication = lastExternalApplication
    }

    /// Called just before the window is shown, while another app may still be frontmost.
    func noteFrontmostBeforeShowing() {
        noteActivation(NSWorkspace.shared.frontmostApplication)
    }

    private func noteActivation(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular else { return }
        lastExternalApplication = app
    }

    /// The editor's state when the draft editor is the focus (VoiceDraft active,
    /// draft window key, text view first responder); nil otherwise.
    func focus() -> DraftFocus? {
        guard let textView, let window = textView.window, let id = currentID,
              DraftRouting.isDraftFocus(appActive: NSApp.isActive, draftWindowIsKey: window.isKeyWindow,
                                        editorIsFirstResponder: window.firstResponder === textView) else { return nil }
        return DraftFocus(documentID: id, text: textView.string, selection: textView.selectedRange())
    }

    // MARK: Programmatic writes

    /// Inserts a dictated passage at the open draft's caret (`DraftText.insertion`).
    func insertDictation(_ output: String, transcript: String, historyID: UUID?, mode: WritingMode) throws {
        guard let textView else { throw VoiceDraftError.message("The draft window is not available. Copy the result instead.") }
        let insertion = DraftText.insertion(for: output, into: textView.string, selection: textView.selectedRange())
        // `insertion` drops the passage's edge line breaks; the take records exactly what landed.
        let take = DraftTake(range: insertion.textRange, transcript: transcript, result: output.trimmingCharacters(in: .newlines),
                             historyID: historyID, kind: .dictation, mode: mode)
        try apply(insertion.replacement, in: insertion.replacementRange, selectAfter: NSRange(location: insertion.caretAfter, length: 0),
                  take: take, actionName: D("Dictation"))
    }

    /// Replaces the range a run bound at its start, only in the same draft and
    /// only while that range still holds the text it had then.
    func replace(_ run: DraftRun, with output: String, transcript: String, historyID: UUID?, mode: WritingMode) throws {
        guard case .range(let range, let expected) = run.binding else { return }
        guard let textView, run.documentID == currentID, DraftText.holds(expected, at: range, in: textView.string) else {
            throw VoiceDraftError.message("The draft changed while the instruction was processing. Copy the result instead.")
        }
        let length = (output as NSString).length
        let written = NSRange(location: range.location, length: length)
        let selectAfter = run.kind == .wholeDraftEdit ? NSRange(location: length, length: 0) : written
        let take = DraftTake(range: written, transcript: transcript, result: output, historyID: historyID, kind: run.kind, mode: mode)
        let actionName: String
        switch run.kind {
        case .styleApply: actionName = D("Apply style")
        case .repolish: actionName = D("Re-polish")
        default: actionName = D("Voice edit")
        }
        try apply(output, in: range, selectAfter: selectAfter, take: take, actionName: actionName)
    }

    private func apply(_ replacement: String, in range: NSRange, selectAfter: NSRange, take: DraftTake, actionName: String) throws {
        guard let textView, let storage = textView.textStorage else { throw VoiceDraftError.message("The draft window is not available. Copy the result instead.") }
        programmatic = true
        defer { programmatic = false }
        let undo = textView.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            undo?.endUndoGrouping()
            throw VoiceDraftError.message("The draft window is not available. Copy the result instead.")
        }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
        textView.didChangeText()
        undo?.setActionName(actionName)
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(selectAfter)
        textView.scrollRangeToVisible(selectAfter)
        current.takes.append(take)
        takeIsLatestUndo = true
        saveNow()
        refresh()
    }

    // MARK: Takes

    func undoLastTake() {
        guard canUndoLastTake, let undo = textView?.undoManager, undo.canUndo else { return }
        undo.undo()
        if !current.takes.isEmpty { current.takes.removeLast() }
        takeIsLatestUndo = false
        saveNow()
        refresh()
    }

    /// The open draft's last take when it can be re-polished (intact, not an instruction).
    func repolishRun() -> DraftRun? {
        guard let id = currentID, let take = current.takes.last else { return nil }
        return DraftRouting.repolishRun(documentID: id, take: take, text: currentText)
    }

    var lastTakeMode: WritingMode? { current.takes.last?.mode }
    var lastTakeTranscript: String? { current.takes.last?.transcript }

    private func refresh() {
        characterCount = currentText.count
        var snapshot = current; snapshot.text = currentText
        canRepolishLastTake = (current.takes.last?.canRepolish ?? false) && DraftDocument.lastTakeIsIntact(snapshot)
        canUndoLastTake = takeIsLatestUndo && (textView?.undoManager?.canUndo ?? false) && DraftDocument.lastTakeIsIntact(snapshot)
    }

    // MARK: Saving

    private func scheduleSave() {
        saveState = .pending
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the open draft now. A blank draft that was never saved stays in memory.
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        let text = currentText
        if !currentSaved, text.isEmpty, current.takes.isEmpty { saveState = .saved; return }
        if text != current.text || !currentSaved { current.updatedAt = Date() }
        current.text = text
        guard let store else { saveState = .saved; updateListEntry(); return }
        do {
            try store.save(current)
            currentSaved = true; saveState = .saved
        } catch {
            saveState = .failed
        }
        updateListEntry()
    }

    private func updateListEntry() {
        documents.removeAll { $0.id == current.id }
        documents.append(current)
        documents.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.createdAt > $1.createdAt }
    }
}

extension DraftWorkspace: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        if !programmatic {
            takeIsLatestUndo = false
            scheduleSave()
        }
        refresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) {}
}

extension DraftWorkspace: NSTextStorageDelegate {
    /// Keeps take ranges in step with every edit (keyboard, undo or take), so
    /// re-polish finds the last take after edits elsewhere in the draft.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !loading else { return }
            current.takes = current.takes.map { $0.shifted(byEditIn: editedRange, changeInLength: delta) }
        }
    }
}

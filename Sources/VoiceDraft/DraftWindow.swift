import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceDraftCore

/// The Draft window (草稿): long-form writing by voice, one paragraph per take.
/// A normal titled, resizable window whose frame is restored between launches.
@MainActor
final class DraftWindowController: NSWindowController, NSWindowDelegate {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.title = D("Draft window")
        window.center()
        window.setFrameAutosaveName("VoiceDraftDraftWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: DraftWindowView(state: state, drafts: state.drafts))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        // Remember the app the user came from before VoiceDraft activates.
        state.drafts.noteFrontmostBeforeShowing()
        window?.title = D("Draft window")
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.drafts.focusEditor()
    }

    func windowDidBecomeKey(_ notification: Notification) { state.drafts.windowDidBecomeKey() }
    func windowWillClose(_ notification: Notification) { state.drafts.saveNow() }
    func windowDidResignKey(_ notification: Notification) { state.drafts.saveNow() }
}

struct DraftWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject var drafts: DraftWorkspace
    @State private var deleting: DraftDocument?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                DraftTextEditor(drafts: drafts)
                Divider()
                statusLine
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .environment(\.locale, L10n.locale)
        .alert(D("Delete this draft?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { draft in
            Button(L("Delete"), role: .destructive) { drafts.delete(draft.id) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { draft in
            Text(String(format: D("“%@” will be deleted from this Mac. This cannot be undone."), draft.displayTitle))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(D("Drafts")).font(.headline)
                Spacer()
                Button { drafts.newDraft() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help(D("New draft")).accessibilityLabel(D("New draft"))
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            List(selection: Binding(get: { drafts.currentID }, set: { if let id = $0 { drafts.select(id) } })) {
                ForEach(drafts.documents) { draft in
                    let open = draft.id == drafts.currentID
                    VStack(alignment: .leading, spacing: 2) {
                        Text(open ? drafts.currentTitle : draft.displayTitle).lineLimit(1)
                        Text(draft.updatedAt.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(draft.id)
                    .contextMenu { Button(D("Delete draft…")) { deleting = draft } }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button(D("Delete draft…")) {
                    deleting = drafts.documents.first { $0.id == drafts.currentID }
                }.buttonStyle(.borderless).disabled(drafts.currentText.isEmpty && drafts.documents.count <= 1)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    // MARK: Toolbar

    private var instructing: Bool { state.runDraft != nil && state.runMode == .edit && (state.recording || state.phase == "starting") }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { drafts.undoLastTake() } label: { Label(D("Undo last take"), systemImage: "arrow.uturn.backward") }
                    .disabled(!drafts.canUndoLastTake || state.busy)
                Menu {
                    Button(D("Default style")) { state.repolishLastDraftTake(styleID: nil) }
                    ForEach(state.settings.styles) { style in
                        Button(style.name) { state.repolishLastDraftTake(styleID: style.id) }
                    }
                } label: { Label(D("Re-polish last take"), systemImage: "sparkles") }
                    .fixedSize().disabled(!drafts.canRepolishLastTake || state.busy)
                Button {
                    if state.recording { state.finish(); return }
                    drafts.focusEditor()
                    state.toggle(mode: .edit, external: true)
                } label: {
                    Label(instructing ? D("Finish instruction") : D("Voice instruction"), systemImage: instructing ? "checkmark.circle" : "waveform.badge.mic")
                }
                .disabled(state.busy && !instructing)
                .help(D("Select text, then press the Edit shortcut to change it by voice. With nothing selected, the instruction applies to the whole draft. This button starts the same instruction; click again to finish."))
                Spacer(minLength: 8)
                Button { copyAll() } label: { Label(D("Copy all"), systemImage: "doc.on.doc") }
                    .disabled(drafts.currentText.isEmpty)
                Button { state.insertDraftIntoPreviousApp() } label: { Label(D("Insert into previous app"), systemImage: "arrow.up.forward.app") }
                    .disabled(drafts.currentText.isEmpty || state.busy)
                    .help(drafts.previousApplication?.localizedName.map { String(format: D("Paste the whole draft into %@."), $0) } ?? D("Paste the whole draft into the app you used before this window."))
                Button { export() } label: { Label(D("Export…"), systemImage: "square.and.arrow.up") }
                    .disabled(drafts.currentText.isEmpty)
            }
            .labelStyle(.titleAndIcon).controlSize(.small)
            Text(D("Press your dictation shortcut here to add one paragraph at the cursor. Select text and press the Edit shortcut to change it by voice; with nothing selected, the instruction applies to the whole draft."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Status line

    private var statusLine: some View {
        HStack(spacing: 10) {
            Text(String(format: D("%d characters"), drafts.characterCount)).monospacedDigit()
            Text(saveLabel)
            if state.busy || !state.error.isEmpty {
                Text(state.error.isEmpty ? L(state.status) : L(state.error)).lineLimit(1).truncationMode(.tail)
            } else if !drafts.notice.isEmpty {
                Text(drafts.notice).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var saveLabel: String {
        switch drafts.saveState {
        case .saved: return D("Saved")
        case .pending: return D("Editing…")
        case .failed: return D("Could not save the draft.")
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        drafts.notice = NSPasteboard.general.setString(drafts.currentText, forType: .string) ? L("Copied") : L("Could not copy the result.")
    }

    private func export() {
        let panel = NSSavePanel()
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdown, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        let base = drafts.currentTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = String(base.prefix(60)) + ".md"
        let text = drafts.currentText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try Data(text.utf8).write(to: url, options: .atomic)
                    drafts.notice = String(format: D("Exported to %@"), url.lastPathComponent)
                } catch { drafts.notice = D("Could not export the draft.") }
            }
        }
    }
}

/// Plain-text `NSTextView` editor: rich text off, continuous spell check off,
/// standard undo on, the system's accessibility.
struct DraftTextEditor: NSViewRepresentable {
    let drafts: DraftWorkspace

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 18, height: 16)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph,
                                     .foregroundColor: NSColor.textColor]
        textView.setAccessibilityLabel(D("Draft"))
        drafts.attach(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

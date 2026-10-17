import AppKit
import SwiftUI
import Combine
import VoiceDraftCore

@main
struct VoiceDraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands { EditingCommands() }
    }
}

private struct EditingCommands: Commands {
    @AppStorage("interfaceLanguage") private var language = AppLanguage.system.rawValue
    var body: some Commands {
        let _ = language
        CommandGroup(replacing: .appSettings) {
            Button(D("Settings")) { NotificationCenter.default.post(name: .voiceDraftOpenSettings, object: nil) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            command("Undo", action: "undo:", key: "z")
            command("Redo", action: "redo:", key: "z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            command("Cut", action: "cut:", key: "x")
            command("Copy", action: "copy:", key: "c")
            command("Paste", action: "paste:", key: "v")
            command("Select All", action: "selectAll:", key: "a")
        }
    }

    private func command(_ title: String, action: String, key: KeyEquivalent,
                         modifiers: EventModifiers = .command) -> some View {
        Button(L10n.text(title)) {
            // The windows are hosted by AppKit, so route to the key window's
            // first responder, including the field editor in a model sheet.
            NSApp.sendAction(Selector(action), to: nil, from: nil)
        }.keyboardShortcut(key, modifiers: modifiers)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var state: AppState!
    private var window: NSWindow!
    private var hud: NSPanel!
    private var hudObservation: AnyCancellable?
    private var phaseObservation: AnyCancellable?
    /// Whether the HUD should be on screen; false while it fades out.
    private var hudShown = false
    /// Bumped on every show/hide so a stale fade-out completion cannot hide a newer show.
    private var hudTransition = 0
    private var hudTargetFrame = NSRect.zero
    private var hudScreen: NSScreen?
    private var hudPreviewOnly = false
    private var statusItem: NSStatusItem!
    private let shortcuts = GlobalShortcuts()
    private let escapeCancellation = EscapeCancellationMonitor()
    private var menuKeys: [ObjectIdentifier: String] = [:]
    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic probe: isolated, runs before state, windows, hotkeys or the updater exist.
        if let bundleIdentifier = ProcessInfo.processInfo.environment[InputFocusProbe.environmentKey] {
            exit(InputFocusProbe.run(bundleIdentifier: bundleIdentifier))
        }
        NSApp.setActivationPolicy(.regular)
        let previewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_PREVIEWS"]
        let onboardingPreviewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_ONBOARDING"]
        let hudPreviewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_HUD_PREVIEWS"]
        let sheetPreviewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_SHEETS"]
        let hudPreview = ProcessInfo.processInfo.environment["VOICEDRAFT_HUD_PREVIEW"]
        hudPreviewOnly = hudPreview != nil
        let isolatedPreview = (Bundle.main.object(forInfoDictionaryKey: "VoiceDraftPreviewMode") as? Bool == true) || previewDirectory != nil || onboardingPreviewDirectory != nil || hudPreviewDirectory != nil || sheetPreviewDirectory != nil || hudPreview != nil || ProcessInfo.processInfo.environment["VOICEDRAFT_PREVIEW"] == "1"
        state = AppState(preview: isolatedPreview)
        if isolatedPreview, let appearance = ProcessInfo.processInfo.environment["VOICEDRAFT_PREVIEW_APPEARANCE"] {
            // Preview-only override so captures can be rendered in either appearance.
            NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "VoiceDraft"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DesktopRootView(state: state))
        window.center()
        hud = DictationPanel(contentRect: NSRect(origin: .zero, size: DictationHUDKind.compact.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        hud.title = "VoiceDraft Dictation"
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.appearance = NSAppearance(named: .darkAqua)
        hud.animationBehavior = .none
        let hudHost = NSHostingView(rootView: RecordingHUD(state: state))
        // The panel frame is driven (and animated) by resizeHUD, not by SwiftUI's ideal size.
        hudHost.sizingOptions = []
        hud.contentView = hudHost
        state.showMain = { [weak self] in self?.showWindow() }
        state.showHUD = { [weak self] in self?.showHUD() }
        state.hideHUD = { [weak self] in self?.hideHUD() }
        hudObservation = state.$hudKind.sink { [weak self] _ in
            // @Published emits before the change lands; read the settled kind on the next turn.
            DispatchQueue.main.async { guard let self else { return }; self.resizeHUD(self.state.hudKind, animated: true) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        phaseObservation = state.$phase.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }
        updateStatusMenu()
        state.languageChanged = { [weak self] in self?.updateStatusMenu(); self?.updateMainMenu() }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateMainMenu() }
        }
        DispatchQueue.main.async { [weak self] in self?.updateMainMenu() }
        shortcuts.onEvent = { [weak self] action, down, time in self?.state.shortcutEvent(action, down: down, at: time) }
        shortcuts.onRetarget = { [weak self] from, to, time in self?.state.retargetShortcut(from: from, to: to, at: time) }
        escapeCancellation.onCancel = { [weak self] in
            guard let self else { return false }
            return self.state.handleEscape(hudVisible: self.hudShown)
        }
        if !isolatedPreview {
            escapeCancellation.install(); state.screenContext.startObserving()
            // With OCR already on, surface a due capture approval at launch rather than in the first take.
            if state.device.features.screenContext, state.device.features.screenContextOCR { ScreenRecordingPermission.confirm() }
        }
        state.configureShortcuts = { [weak self] bindings in
            guard let self, !isolatedPreview else { return }
            let previous = self.state.device.features.shortcuts
            do { try self.shortcuts.install(bindings) }
            catch { try? self.shortcuts.install(previous); throw error }
        }
        state.chooseSelectionStyle = { [weak self] in self?.showStyleMenu() }
        if !isolatedPreview {
            do { try shortcuts.install(state.device.features.shortcuts) } catch { state.error = .init(error: error) }
        }
        if !hudPreviewOnly { showWindow() }
        if let onboardingPreviewDirectory { captureOnboardingPreviews(to: onboardingPreviewDirectory) }
        else if let previewDirectory { capturePreviews(to: previewDirectory) }
        else if let hudPreviewDirectory { captureHUDPreviews(to: hudPreviewDirectory) }
        else if let sheetPreviewDirectory { captureSheetPreviews(to: sheetPreviewDirectory) }
        else if let hudPreview { state.prepareHUDPreview(hudPreview); showHUD() }
    }
    private func showStyleMenu() {
        state.pendingStyleTarget = TextInsertion.capture()
        let menu = NSMenu()
        let options: [(String, String)] = [(F("Default style", "默认风格"), "default")] + state.settings.styles.map { ($0.name, $0.id.uuidString) }
        for (name, id) in options {
            let item = NSMenuItem(title: name, action: #selector(applySelectionStyle(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        state.pendingStyleTarget = nil
    }
    @objc private func applySelectionStyle(_ item: NSMenuItem) {
        state.applyStyleToSelection((item.representedObject as? String).flatMap(UUID.init(uuidString:)))
    }
    private func updateStatusMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: L("Open VoiceDraft"), action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let record = NSMenuItem(title: L("Start / stop dictation"), action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self; menu.addItem(record)
        let reinsert = NSMenuItem(title: L("Insert last result"), action: #selector(insertLastResult), keyEquivalent: "")
        reinsert.target = self; menu.addItem(reinsert)
        let extract = NSMenuItem(title: D("Extract words from this screen…"), action: #selector(extractFromScreen), keyEquivalent: "")
        extract.target = self; menu.addItem(extract)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit VoiceDraft"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
        updateStatusIcon()
    }
    private func updateStatusIcon() {
        let recording = state.recording
        let description = recording ? "VoiceDraft · " + D("Recording") : "VoiceDraft"
        let image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }
    private func updateMainMenu() {
        // Relabel the existing menus; SwiftUI retains ownership and the native responder chain.
        let names = ["File", "Edit", "View", "Window", "Help", "Services", "Settings…"]
        let actions = ["orderFrontStandardAboutPanel:": "About VoiceDraft", "hide:": "Hide VoiceDraft",
                       "hideOtherApplications:": "Hide Others", "unhideAllApplications:": "Show All",
                       "terminate:": "Quit VoiceDraft", "performClose:": "Close Window",
                       "performMiniaturize:": "Minimize", "performZoom:": "Zoom", "arrangeInFront:": "Bring All to Front"]
        func update(_ menu: NSMenu) {
            for item in menu.items {
                let identity = ObjectIdentifier(item)
                if menuKeys[identity] == nil {
                    if let action = item.action, let key = actions[NSStringFromSelector(action)] { menuKeys[identity] = key }
                    else if let key = names.first(where: { key in
                        AppLanguage.allCases.contains { L10n.render(.init(key: key), language: $0) == item.title }
                    }) { menuKeys[identity] = key }
                }
                if let key = menuKeys[identity] { item.title = L10n.text(key); item.submenu?.title = item.title }
                if let submenu = item.submenu, menuKeys[identity] != "Services" { update(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }
    private func captureOnboardingPreviews(to path: String) {
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for step in 0..<4 {
                    let view = NSHostingView(rootView: OnboardingView(state: state, initialStep: step, initialDomains: [.artificialIntelligence, .software])
                        .background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = view
                    window.setContentSize(NSSize(width: 740, height: 620))
                    try await Task.sleep(nanoseconds: 600_000_000)
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent("onboarding-\(step + 1).png"))
                }
                print("Rendered four isolated onboarding steps with synthetic authorized permissions.")
            } catch { fputs("Onboarding preview failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    private func capturePreviews(to path: String) {
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // AppKit's view caching draws scroll views in a full-size content view blank, so captures
                // use a standard title bar; the page layout is otherwise identical.
                window.styleMask.remove(.fullSizeContentView)
                // Main pages, then the settings overlay on each tab (over Home).
                let captures: [(name: String, page: String, tab: String?)] = [
                    ("studio", "Studio", nil), ("history", "History", nil), ("vocabulary", "Vocabulary", nil),
                    ("settings", "Settings", "Settings"), ("personalization", "Settings", "Personalization"),
                    ("models", "Settings", "Models"), ("usage", "Settings", "Usage"), ("sync", "Settings", "Sync"), ("about", "Settings", "About"), ("help", "Settings", "Help")
                ]
                for (name, page, tab) in captures {
                    if let tab {
                        if state.page != "Settings" { state.page = "Studio"; try await Task.sleep(nanoseconds: 200_000_000) }
                        state.openSettings(tab)
                    } else { state.page = page }
                    try await Task.sleep(nanoseconds: 600_000_000)
                    guard let view = window.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent(name + ".png"))
                }
                // Synthetic disconnected-device recovery: main page, new overlay, then an existing overlay.
                state.page = "Studio"
                state.error = "The selected audio input is unavailable. Reconnect it or choose another device."
                for name in ["input-error", "input-error-settings", "input-error-settings-repeat"] {
                    if name == "input-error-settings-repeat" {
                        state.openSettings("Usage")
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if name != "input-error" { state.openInputDeviceSettings() }
                    try await Task.sleep(nanoseconds: 600_000_000)
                    if let view = window.contentView {
                        view.layoutSubtreeIfNeeded()
                        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
                        }
                    }
                }
                state.error = ""
                // Home again at the window's minimum width, where its first row is narrowest.
                state.page = "Studio"
                let defaultSize = window.contentLayoutRect.size
                window.setContentSize(NSSize(width: 1080, height: defaultSize.height))
                try await Task.sleep(nanoseconds: 600_000_000)
                if let view = window.contentView {
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("studio-min-width.png"))
                    }
                }
                window.setContentSize(defaultSize)
                // The On-screen context section sits below the fold of the General tab; render it alone too.
                let section = NSHostingView(rootView: ScreenContextPreferences(state: state, screenRecordingAllowed: true)
                    .padding(30).frame(width: 900).background(VD.Palette.canvas))
                section.setFrameSize(section.fittingSize)
                section.layoutSubtreeIfNeeded()
                if let bitmap = section.bitmapImageRepForCachingDisplay(in: section.bounds) {
                    section.cacheDisplay(in: section.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-screen-context.png"))
                }
                print("Rendered three pages, Home at minimum width, seven settings tabs and the On-screen context section without accessing persisted data or Keychain.")
            } catch { fputs("Preview capture failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    @objc func showWindow() {
        if hudPreviewOnly {
            // Inspecting an app can issue a reopen event. Do not resurrect a
            // copied preview card; this also lets native checks observe dismissal.
            if !state.hudCopied { showHUD() }
            return
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func captureHUDPreviews(to path: String) {
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in ["recording", "locked", "starting", "live", "processing", "result", "long-result", "failure", "notice",
                             "screen-context", "screen-context-compact"] {
                    state.prepareHUDPreview(name); showHUD()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    guard let view = hud.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent(name + ".png"))
                }
                print("Rendered eleven synthetic HUD states without microphone, model, Keychain, screen, or persisted data access.")
            } catch { fputs("HUD preview failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    /// Renders every sheet's content alone, in an offscreen borderless window at the sheet's fixed
    /// `.vdSheet(width:)` width and its fitting height. Synthetic fixtures only: no Keychain, model,
    /// network, screen or persisted data access, and no scans run.
    private func captureSheetPreviews(to path: String) {
        let notes = ScreenContextApplication(pid: 0, bundleID: "com.apple.Notes", name: "Notes")
        let screenTerms = ["Kubernetes", "OAuth 2.0", "Grafana", "Lin Wei", "PostgreSQL", "VoiceDraft Sync"].map { AgentContextCandidate(text: $0, sources: []) }
        var agentScan = AgentContextScan()
        agentScan.sources = [.codex, .claude]; agentScan.filesRead = 42; agentScan.limited = true
        let agentTerms = [AgentContextCandidate(text: "VoiceDraftCore", sources: [.codex, .claude], isProject: true),
                          AgentContextCandidate(text: "modernc.org/sqlite", sources: [.codex]),
                          AgentContextCandidate(text: "ScreenContextReader", sources: [.claude], isProject: true),
                          AgentContextCandidate(text: "Bailian", sources: [.claude]),
                          AgentContextCandidate(text: "DashScope", sources: [.codex, .claude])]
        func review(_ fixture: VocabularyFileControls.ReviewFixture) -> AnyView { AnyView(VocabularyFileControls(state: state, fixture: fixture)) }
        var term = VocabularyEntry(text: "Kubernetes", boost: 70, priority: true)
        term.origin = .automatic; term.aliases = ["k8s", "kube"]; term.language = "en-US"
        let customWriting = ModelProfile(name: "OpenAI-compatible", role: .writing, endpoint: "https://api.example.com/v1/chat/completions",
                                         model: "example-chat-model", adapter: .chatCompletions)
        state.addPreviewProfile(customWriting)
        let sheets: [(name: String, view: AnyView)] = [
            ("profile-speech", AnyView(ProfileEditor(state: state, profile: state.settings.speech ?? state.settings.profiles[0]))),
            ("profile-writing", AnyView(ProfileEditor(state: state, profile: customWriting))),
            ("vocabulary-term", AnyView(VocabularyEntryEditor(entry: term, save: { _ in }))),
            ("style-editor", AnyView(StyleEditor(style: WritingStyle(name: "Concise email", prompt: "Keep it short and friendly. Use one greeting line, at most three sentences, and end with a clear next step."), save: { _ in true }))),
            ("bulk-add", AnyView(VocabularyBulkAddSheet(state: state, words: .constant("Kubernetes\nOAuth 2.0\nLin Wei"), isPresented: .constant(true)))),
            ("review-file", review(.init(context: nil, candidates: agentTerms.map { AgentContextCandidate(text: $0.text, sources: []) }))),
            ("review-agent", review(.init(context: .agent, scan: agentScan, candidates: agentTerms, filtered: (5, 9, "qwen-plus")))),
            ("review-agent-scanning", review(.init(context: .agent, scanning: true))),
            ("review-screen-reading", review(.init(context: .screen, app: notes, scanning: true))),
            ("review-screen-accessibility", review(.init(context: .screen, app: notes, screenScan: ScreenContextScan(candidates: screenTerms, source: .accessibility, applicationName: "Notes", charactersRead: 1800),
                                                         candidates: screenTerms, filtered: (6, 11, "qwen-plus")))),
            ("review-screen-ocr", review(.init(context: .screen, app: notes, screenScan: ScreenContextScan(candidates: screenTerms, source: .ocr, applicationName: "Notes", charactersRead: 950),
                                               candidates: screenTerms, filtered: (6, 8, "qwen-plus")))),
            ("review-screen-no-text", review(.init(context: .screen, app: notes, screenScan: ScreenContextScan(source: .ocr, applicationName: "Notes", charactersRead: 0)))),
            ("review-screen-no-candidates", review(.init(context: .screen, app: notes, screenScan: ScreenContextScan(source: .accessibility, applicationName: "Notes", charactersRead: 640))))
        ]
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let sheetWindow = SheetCaptureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                sheetWindow.isReleasedWhenClosed = false
                // Key and active, so native controls (the prominent default button) draw in their active state.
                NSApp.activate(ignoringOtherApps: true)
                sheetWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 800_000_000)
                for (name, sheet) in sheets {
                    let view = NSHostingView(rootView: sheet)
                    sheetWindow.contentView = view
                    sheetWindow.setContentSize(view.fittingSize)
                    NSApp.activate(ignoringOtherApps: true)
                    sheetWindow.makeKeyAndOrderFront(nil)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    sheetWindow.setContentSize(view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent("sheet-\(name).png"))
                }
                sheetWindow.orderOut(nil)
                // History's Clear history is a SwiftUI confirmationDialog, which macOS presents as an
                // alert; render the equivalent NSAlert (same message and buttons) as a stand-in.
                let alert = NSAlert()
                alert.messageText = L("Delete all local history?")
                alert.addButton(withTitle: L("Delete history")).hasDestructiveAction = true
                alert.addButton(withTitle: L("Cancel"))
                alert.layout()
                // View caching skips the alert's vibrant material, so draw its content over the
                // window background color of the alert's appearance.
                if let content = alert.window.contentView,
                   let foreground = content.bitmapImageRepForCachingDisplay(in: content.bounds),
                   let output = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: foreground)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
                    alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill(); content.bounds.fill()
                    }
                    foreground.draw(in: content.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    try output.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("sheet-history-clear.png"))
                }
                print("Rendered \(sheets.count) synthetic sheets and the Clear history confirmation without Keychain, model, network, screen or persisted data access.")
            } catch { fputs("Sheet preview failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    private func showHUD() {
        hudTransition += 1
        if !hud.isVisible {
            hudScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            hud.alphaValue = 0
            resizeHUD(state.hudKind, animated: false)
            hud.orderFrontRegardless()
        } else {
            // Already visible (or fading out): keep the screen and grow/shrink in place.
            resizeHUD(state.hudKind, animated: hudShown)
            hud.orderFrontRegardless()
        }
        hudShown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hud.animator().alphaValue = 1
        }
    }
    private func hideHUD() {
        guard hud.isVisible, hudShown else { return }
        hudShown = false
        hudTransition += 1
        let transition = hudTransition
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // A show that started during the fade owns the panel now.
                guard let self, self.hudTransition == transition, !self.hudShown else { return }
                self.hud.orderOut(nil)
            }
        })
    }
    /// Places the panel bottom-centre on the HUD screen; the bottom edge stays fixed so cards grow upward.
    private func resizeHUD(_ kind: DictationHUDKind, animated: Bool) {
        guard let hud else { return }
        let size = kind.size
        guard let screen = hudScreen ?? NSScreen.main else { hud.setContentSize(size); return }
        let frame = NSRect(x: (screen.visibleFrame.midX - size.width / 2).rounded(),
                           y: screen.visibleFrame.minY + 16, width: size.width, height: size.height)
        // Compare with the last requested frame: hud.frame lags behind an in-flight animation.
        guard frame != hudTargetFrame else { return }
        hudTargetFrame = frame
        if animated && hud.isVisible && hudShown {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                hud.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor in self?.hud.invalidateShadow() }
            })
        } else {
            hud.setFrame(frame, display: true)
        }
    }
    @objc private func toggleRecording() { state.toggle(external: true) }
    @objc private func insertLastResult() {
        // The status menu does not activate VoiceDraft, but let it finish closing
        // so focus capture sees the previously frontmost app's input.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.state.insertLastResult() }
    }
    @objc private func extractFromScreen() {
        guard !state.busy else { return }
        // Like Insert last result: let the menu close, then read the still-frontmost app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.state.extractFromScreen() }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(extractFromScreen) ? !state.busy : true
    }
    @objc private func quitApp() { state.cancel(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        escapeCancellation.uninstall(); shortcuts.uninstall(); state.cancel()
        state.screenContext.stopObserving(); state.screenContext.clearCache()
        TextInsertion.resetElectronAccessibility()
    }
}

// The recording/result controls must never replace the original editor's keyboard focus.
private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Offscreen, borderless host for sheet captures; it becomes key so controls render active.
private final class SheetCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

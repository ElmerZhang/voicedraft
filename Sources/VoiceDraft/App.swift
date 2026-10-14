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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var window: NSWindow!
    private var hud: NSPanel!
    private var hudObservation: AnyCancellable?
    private var hudScreen: NSScreen?
    private var hudPreviewOnly = false
    private var statusItem: NSStatusItem!
    private let shortcuts = GlobalShortcuts()
    private let escapeCancellation = EscapeCancellationMonitor()
    private var menuKeys: [ObjectIdentifier: String] = [:]
    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let previewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_PREVIEWS"]
        let onboardingPreviewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_ONBOARDING"]
        let hudPreviewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_HUD_PREVIEWS"]
        let hudPreview = ProcessInfo.processInfo.environment["VOICEDRAFT_HUD_PREVIEW"]
        hudPreviewOnly = hudPreview != nil
        let isolatedPreview = (Bundle.main.object(forInfoDictionaryKey: "VoiceDraftPreviewMode") as? Bool == true) || previewDirectory != nil || onboardingPreviewDirectory != nil || hudPreviewDirectory != nil || hudPreview != nil || ProcessInfo.processInfo.environment["VOICEDRAFT_PREVIEW"] == "1"
        state = AppState(preview: isolatedPreview)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceDraft"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DesktopRootView(state: state))
        window.center()
        hud = DictationPanel(contentRect: NSRect(origin: .zero, size: DictationHUDKind.compact.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        hud.title = "VoiceDraft Dictation"
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = NSHostingView(rootView: RecordingHUD(state: state))
        state.showMain = { [weak self] in self?.showWindow() }
        state.showHUD = { [weak self] in self?.showHUD() }
        state.hideHUD = { [weak self] in self?.hud.orderOut(nil) }
        hudObservation = state.$hudKind.sink { [weak self] kind in
            DispatchQueue.main.async { self?.resizeHUD(kind) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceDraft")
        updateStatusMenu()
        state.languageChanged = { [weak self] in self?.updateStatusMenu(); self?.updateMainMenu() }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateMainMenu() }
        }
        DispatchQueue.main.async { [weak self] in self?.updateMainMenu() }
        shortcuts.onEvent = { [weak self] action, down in self?.state.shortcutEvent(action, down: down) }
        escapeCancellation.onCancel = { [weak self] in self?.state.cancelActiveInput() ?? false }
        if !isolatedPreview { escapeCancellation.install() }
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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit VoiceDraft"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
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
                for page in ["Studio", "Models", "Vocabulary", "Sync", "History", "Settings"] {
                    state.page = page
                    try await Task.sleep(nanoseconds: 600_000_000)
                    guard let view = window.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent(page.lowercased() + ".png"))
                }
                print("Rendered all six native screens without accessing persisted data or Keychain.")
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
                for name in ["recording", "live", "processing", "result", "long-result", "failure"] {
                    state.prepareHUDPreview(name); showHUD()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    guard let view = hud.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent(name + ".png"))
                }
                print("Rendered six synthetic HUD states without microphone, model, Keychain, or persisted data access.")
            } catch { fputs("HUD preview failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    private func showHUD() {
        if !hud.isVisible { hudScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }
        resizeHUD(state.hudKind)
        hud.orderFrontRegardless()
    }
    private func resizeHUD(_ kind: DictationHUDKind) {
        guard let hud else { return }
        let size = kind.size
        if let screen = hudScreen ?? NSScreen.main {
            hud.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2,
                                y: screen.visibleFrame.minY + 16, width: size.width, height: size.height), display: true)
        } else { hud.setContentSize(size) }
    }
    @objc private func toggleRecording() { state.toggle(external: true) }
    @objc private func quitApp() { state.cancel(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { escapeCancellation.uninstall(); shortcuts.uninstall(); state.cancel() }
}

// The recording/result controls must never replace the original editor's keyboard focus.
private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit
import SwiftUI
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
    private var statusItem: NSStatusItem!
    private let shortcuts = GlobalShortcuts()
    private var menuKeys: [ObjectIdentifier: String] = [:]
    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let previewDirectory = ProcessInfo.processInfo.environment["VOICEDRAFT_CAPTURE_PREVIEWS"]
        state = AppState(preview: previewDirectory != nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceDraft"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(state: state))
        window.center()
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 516, height: 102), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = NSHostingView(rootView: RecordingHUD(state: state))
        state.showMain = { [weak self] in self?.showWindow() }
        state.showHUD = { [weak self] in self?.showHUD() }
        state.hideHUD = { [weak self] in self?.hud.orderOut(nil) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceDraft")
        updateStatusMenu()
        state.languageChanged = { [weak self] in self?.updateStatusMenu(); self?.updateMainMenu() }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateMainMenu() }
        }
        DispatchQueue.main.async { [weak self] in self?.updateMainMenu() }
        shortcuts.onTrigger = { [weak self] id in
            guard let self else { return }
            let modes: [WritingMode] = [.polish, .translate, .edit, .ask]
            self.state.toggle(mode: modes[min(Int(id), 3)], external: true)
        }
        if previewDirectory == nil {
            do { try shortcuts.install() } catch { state.error = .init(error: error) }
        }
        showWindow()
        if let previewDirectory { capturePreviews(to: previewDirectory) }
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
    private func capturePreviews(to path: String) {
        Task {
            do {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for page in ["Studio", "Models", "Vocabulary", "Sync", "History"] {
                    state.page = page
                    try await Task.sleep(nanoseconds: 600_000_000)
                    guard let view = window.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try data.write(to: directory.appendingPathComponent(page.lowercased() + ".png"))
                }
                print("Rendered all five native screens without accessing persisted data or Keychain.")
            } catch { fputs("Preview capture failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func showHUD() {
        if let screen = NSScreen.main {
            hud.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - hud.frame.width / 2, y: screen.visibleFrame.minY + 38))
        }
        hud.orderFrontRegardless()
    }
    @objc private func toggleRecording() { state.toggle(external: true) }
    @objc private func quitApp() { state.cancel(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { state.cancel() }
}

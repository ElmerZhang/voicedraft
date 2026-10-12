import AppKit
import SwiftUI
import VoiceDraftCore

@main
struct VoiceDraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var window: NSWindow!
    private var hud: NSPanel!
    private var statusItem: NSStatusItem!
    private let shortcuts = GlobalShortcuts()

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
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 446, height: 72), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = NSHostingView(rootView: RecordingHUD(state: state))
        state.showMain = { [weak self] in self?.showWindow() }
        state.showHUD = { [weak self] in self?.showHUD() }
        state.hideHUD = { [weak self] in self?.hud.orderOut(nil) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceDraft")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open VoiceDraft", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let record = NSMenuItem(title: "Start / stop dictation", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self; menu.addItem(record)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoiceDraft", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
        installMainMenu()
        shortcuts.onTrigger = { [weak self] id in
            guard let self else { return }
            let modes: [WritingMode] = [.polish, .translate, .edit, .ask]
            self.state.toggle(mode: modes[min(Int(id), 3)], external: true)
        }
        if previewDirectory == nil {
            do { try shortcuts.install() } catch { state.error = error.localizedDescription }
        }
        showWindow()
        if let previewDirectory { capturePreviews(to: previewDirectory) }
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
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu()
        app.addItem(withTitle: "Quit VoiceDraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
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

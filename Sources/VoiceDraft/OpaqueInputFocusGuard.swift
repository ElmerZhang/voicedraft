import AppKit
import VoiceDraftCore

/// An opaque editor cannot provide a field/selection identity. Any intervening
/// interaction invalidates this one take. No key text or mouse positions are kept.
@MainActor
final class OpaqueInputFocusGuard {
    private(set) var valid = true
    private var monitor: Any?
    private var activation: NSObjectProtocol?

    init(ignoring shortcuts: [ShortcutBinding]) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    var modifiers: UInt32 = 0
                    for (flag, bit) in [(NSEvent.ModifierFlags.shift, UInt32(1)), (.control, 2), (.option, 4), (.command, 8)] where event.modifierFlags.contains(flag) { modifiers |= bit }
                    if shortcuts.contains(where: { $0.enabled && $0.keyCode == UInt32(event.keyCode) && $0.modifiers == modifiers }) { return }
                }
                self?.valid = false
            }
        }
        if monitor == nil { valid = false }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.valid = false }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }
}

import AppKit
import Carbon

/// Separate from configurable shortcuts so cancellation also works without an Fn binding.
@MainActor
final class EscapeCancellationMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    var onCancel: (() -> Bool)?

    func install() {
        uninstall()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let cancelled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return cancelled ? nil : event
        }
        // Global monitors cover the destination app; local monitors cover VoiceDraft.
        // AppKit delivers both on the main thread, so cancel before queued work resumes.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) else { return false }
        return onCancel?() ?? false
    }

    func uninstall() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

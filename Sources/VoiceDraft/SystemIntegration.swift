import AppKit
import AVFoundation
import Carbon
import VoiceDraftCore

struct InputTarget {
    let pid: pid_t
    let name: String
    let element: AXUIElement?
    let range: CFRange?
    let selection: String
    let secure: Bool
}

@MainActor
enum TextInsertion {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func capture() -> InputTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let focused = attribute(root, kAXFocusedUIElementAttribute)
        let element: AXUIElement? = focused.flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        var range: CFRange?
        if let element, let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &r) { range = r }
        }
        let selection = element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? ""
        let secure = element.flatMap { attribute($0, kAXSubroleAttribute) as? String } == "AXSecureTextField"
        return InputTarget(pid: app.processIdentifier, name: app.localizedName ?? "App",
                           element: element, range: range, selection: selection, secure: secure)
    }
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    static func insert(_ text: String, into target: InputTarget) async throws {
        guard AXIsProcessTrusted() else { throw VoiceDraftError.message("Enable Accessibility to paste into other apps. The result is available here.") }
        guard !target.secure else { throw VoiceDraftError.message("Voice input is disabled in password fields.") }
        guard let current = capture(), current.pid == target.pid,
              let original = target.element, let focused = current.element, CFEqual(original, focused),
              current.selection == target.selection,
              rangesMatch(current.range, target.range) else {
            throw VoiceDraftError.message("The input focus or selection changed. Copy the result when ready.")
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(original, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(original, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return }

        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        board.clearContents(); board.setString(text, forType: .string)
        let generation = board.changeCount
        defer {
            if board.changeCount == generation {
                board.clearContents()
                let items = previous.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw VoiceDraftError.message("Could not send the paste shortcut.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Some editors read the clipboard asynchronously. Never overwrite a later user copy.
        try? await Task.sleep(nanoseconds: 800_000_000)
    }
    private static func rangesMatch(_ a: CFRange?, _ b: CFRange?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.location == b.location && a.length == b.length
        default: return false
        }
    }
}

@MainActor
final class GlobalShortcuts {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onTrigger: ((UInt32) -> Void)?
    func install() throws {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.onTrigger?(id.id) }
            return noErr
        }, 1, &spec, context, &handler)
        guard status == noErr else { throw VoiceDraftError.message("Could not install keyboard shortcuts.") }
        let keys = [kVK_Space, kVK_ANSI_T, kVK_ANSI_E, kVK_ANSI_A]
        for (index, code) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey),
                EventHotKeyID(signature: 0x56445246, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { throw VoiceDraftError.message("A VoiceDraft shortcut is already in use by another app.") }
            refs.append(ref)
        }
    }
}

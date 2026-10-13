import AppKit
import AVFoundation
import Carbon
import VoiceDraftCore

struct InputTarget {
    let pid: pid_t
    let name: String
    let element: AXUIElement?
    let window: AXUIElement?
    let range: CFRange?
    let selection: String
    let value: String?
    let secure: Bool
    let editable: Bool
    let keyboardSurface: Bool
}

enum TextInsertionOutcome: Equatable { case confirmed, sentToTerminal, sentWithoutConfirmation }

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
        let focused = uiElement(attribute(root, kAXFocusedUIElementAttribute))
        let window = uiElement(attribute(root, kAXFocusedWindowAttribute))
        let editor = focused.flatMap {
            FocusedInputResolver.resolve(from: $0, capabilities: capabilities,
                parent: { uiElement(attribute($0, kAXParentAttribute)) }, equals: { CFEqual($0, $1) })
        }
        // Warp's TTY surface does not consistently expose an AX text editor.
        // This is a narrow compatibility path: no browser/app-wide fallback,
        // no dialogs/buttons, and the window + exposed surface must stay focused.
        let terminalSurface = KeyboardSurfacePolicy.accepts(bundleIdentifier: app.bundleIdentifier,
            focused: focused.map(capabilities), editor: editor.map(capabilities),
            standardWindow: window.flatMap { attribute($0, kAXSubroleAttribute) as? String } == kAXStandardWindowSubrole,
            modalWindow: window.flatMap { attribute($0, kAXModalAttribute) as? Bool } == true)
        let element = editor ?? focused
        let range = element.flatMap(selectedRange)
        let selection = element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? ""
        let secure = element.flatMap { attribute($0, kAXSubroleAttribute) as? String } == "AXSecureTextField"
        return InputTarget(pid: app.processIdentifier, name: app.localizedName ?? "App",
                           element: element, window: window, range: range, selection: selection,
                           value: terminalSurface ? nil : editor.flatMap { attribute($0, kAXValueAttribute) as? String }, secure: secure,
                           editable: terminalSurface || (editor.map { capabilities($0).acceptsInsertion } ?? false),
                           keyboardSurface: terminalSurface)
    }
    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    private static func capabilities(_ element: AXUIElement) -> TextInputCapabilities {
        func isSettable(_ name: String) -> Bool {
            var value = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
        }
        return TextInputCapabilities(
            role: attribute(element, kAXRoleAttribute) as? String ?? "",
            enabled: attribute(element, kAXEnabledAttribute) as? Bool != false,
            secure: attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField",
            canReplaceSelection: isSettable(kAXSelectedTextAttribute),
            canSetValue: isSettable(kAXValueAttribute),
            canSetSelectionRange: isSettable(kAXSelectedTextRangeAttribute)
        )
    }
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    static func insert(_ text: String, into target: InputTarget, onPasteSent: () -> Void) async throws -> TextInsertionOutcome {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw VoiceDraftError.message("Enable Accessibility to paste into other apps. The result is available here.") }
        guard !target.secure else { throw VoiceDraftError.message("Voice input is disabled in password fields.") }
        guard let current = capture(), current.pid == target.pid else {
            throw VoiceDraftError.message("The active app changed. Copy the result when ready.")
        }
        guard sameElement(target.window, current.window) else {
            throw VoiceDraftError.message("The active window changed. Copy the result when ready.")
        }
        guard target.editable, current.editable, !current.secure,
              target.keyboardSurface == current.keyboardSurface, sameElement(target.element, current.element) else {
            throw VoiceDraftError.message("The focused input changed. Copy the result when ready.")
        }
        guard InputSelectionPolicy.matches(originalRange: nsRange(target.range), originalText: target.selection,
            originalValue: target.value, currentRange: nsRange(current.range), currentText: current.selection,
            currentValue: current.value, keyboardSurface: target.keyboardSurface) else {
            throw VoiceDraftError.message("The text selection changed. Copy the result when ready.")
        }
        let receiptRange = nsRange(current.range) ?? (current.value == "" ? NSRange(location: 0, length: 0) : nil)
        let receipt = TextInsertionReceipt(value: current.value, range: receiptRange, replacement: text)

        // Chromium can acknowledge AXSelectedText writes without implementing
        // the replacement action. Use the editor's normal paste path instead.
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        board.clearContents()
        let supplied = board.setString(text, forType: .string)
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
        guard supplied else { throw VoiceDraftError.message("Could not copy the result.") }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw VoiceDraftError.message("Could not send the paste shortcut.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // UI completion does not need to wait for AX confirmation. Keep the
        // clipboard alive below until the editor has had time to consume it.
        onPasteSent()
        // AX/event success only acknowledges delivery. Wait for the actual
        // field update before claiming success, without retrying and duplicating text.
        // Keep the clipboard available during cancellation as the paste is already queued.
        for _ in 0..<20 {
            await Task.detached { try? await Task.sleep(nanoseconds: 75_000_000) }.value
            if !target.keyboardSurface, let original = current.element,
               receipt.confirms(value: attribute(original, kAXValueAttribute) as? String,
                                range: nsRange(selectedRange(original))) { return .confirmed }
        }
        try Task.checkCancellation()
        // Terminal echo is not an AX value/selection replacement. Keep the
        // honest distinction between sending paste and observing inserted text.
        if target.keyboardSurface { return .sentToTerminal }
        // A rich editor can accept paste without exposing an exact AX receipt.
        // Missing confirmation is not a failed send: prompting Copy here can
        // duplicate text that already arrived. Keep it distinct from confirmed.
        return .sentWithoutConfirmation
    }
    private static func nsRange(_ range: CFRange?) -> NSRange? {
        range.map { NSRange(location: $0.location, length: $0.length) }
    }
    /// Observe only the same focused editor, for at most 45 seconds. No keyboard
    /// hooks, surrounding-document upload, terminal output, or focus reacquisition.
    static func observeCorrections(to text: String, in target: InputTarget,
                                   onCorrection: (VocabularyLearningSample) -> Void) async {
        guard target.editable, !target.secure, !target.keyboardSurface, target.window != nil, let element = target.element,
              let context = DictationCorrectionContext(value: target.value,
                  range: nsRange(target.range) ?? (target.value == "" ? NSRange(location: 0, length: 0) : nil), inserted: text) else { return }
        let clock = ContinuousClock(), started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(45))
        var confirmedInsertion = false, lastText = text, baseline = text, stableSince = started
        // Fresh observer objects get short timeouts; insertion's AX objects and
        // the process-wide accessibility timeout remain unchanged.
        func observerAttribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(node, 0.1)
            return attribute(node, name)
        }
        func observerCapabilities(_ node: AXUIElement) -> TextInputCapabilities {
            AXUIElementSetMessagingTimeout(node, 0.1)
            return capabilities(node)
        }
        while clock.now < deadline {
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard clock.now < deadline, !Task.isCancelled, AXIsProcessTrusted(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return }
            let root = AXUIElementCreateApplication(target.pid)
            guard sameElement(uiElement(observerAttribute(root, kAXFocusedWindowAttribute)), target.window),
                  let focused = uiElement(observerAttribute(root, kAXFocusedUIElementAttribute)),
                  let editor = FocusedInputResolver.resolve(from: focused, capabilities: observerCapabilities,
                    parent: { uiElement(observerAttribute($0, kAXParentAttribute)) }, equals: { CFEqual($0, $1) }),
                  CFEqual(editor, element), observerCapabilities(editor).acceptsInsertion,
                  let value = observerAttribute(editor, kAXValueAttribute) as? String else { return }
            if !confirmedInsertion {
                if value == target.value, clock.now < started.advanced(by: .seconds(2)) { continue }
                guard value == context.expectedValue else { return }
                confirmedInsertion = true
            }
            guard let edited = context.editedText(value: value, selection: nsRange(selectedRange(editor))) else { return }
            if edited != lastText { lastText = edited; stableSince = clock.now; continue }
            if clock.now >= stableSince.advanced(by: .seconds(2)), clock.now < deadline, edited != baseline {
                if let sample = VocabularyLearningSample(source: .editedDictation, before: baseline, after: edited) { onCorrection(sample) }
                baseline = edited
            }
        }
    }
    private static func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }
}

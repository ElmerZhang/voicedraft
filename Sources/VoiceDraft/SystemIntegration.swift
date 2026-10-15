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
    let opaqueApplication: Bool
    let focusGuard: OpaqueInputFocusGuard?
    /// VoiceDraft enabled this app's Electron accessibility tree, which may not
    /// have been built yet; a later capture can still find the editor.
    var accessibilityPending = false
}

enum TextInsertionOutcome: Equatable { case confirmed, sentToTerminal, sentWithoutConfirmation }

@MainActor
enum TextInsertion {
    private static var delivering = false
    /// Processes whose Electron accessibility VoiceDraft enabled, keyed by PID
    /// with the launch date guarding against PID reuse and the enable uptime.
    private static var electronEnabled: [pid_t: (launched: Date?, at: TimeInterval)] = [:]
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func capture(ignoring shortcuts: [ShortcutBinding] = [], trackOpaqueFocus: Bool = false) -> InputTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        var (rawFocus, focused, editor) = resolveFocus(root)
        if enableElectronAccessibility(app, root: root, candidate: editor ?? focused) {
            (rawFocus, focused, editor) = resolveFocus(root)
        }
        guard rawFocus == nil || focused != nil else { return nil }
        let window = uiElement(attribute(root, kAXFocusedWindowAttribute))
        // Warp's TTY surface does not consistently expose an AX text editor.
        // This is a narrow compatibility path: no browser/app-wide fallback,
        // no dialogs/buttons, and the window + exposed surface must stay focused.
        let standardWindow = window.flatMap { attribute($0, kAXSubroleAttribute) as? String } == kAXStandardWindowSubrole
        let modalWindow = window.flatMap { attribute($0, kAXModalAttribute) as? Bool } == true
        let terminalSurface = KeyboardSurfacePolicy.accepts(bundleIdentifier: app.bundleIdentifier,
            focused: focused.map(capabilities), editor: editor.map(capabilities),
            standardWindow: standardWindow, modalWindow: modalWindow)
        let candidate = editor ?? focused
        let paste = !terminalSurface && (candidate.map { capabilities($0).capability == .opaque }
            ?? (rawFocus == nil && app.bundleIdentifier == "com.tencent.xinWeChat"))
            ? nativePasteAvailability(root) : (present: false, enabled: false)
        let hasSelection = !(candidate.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? "").isEmpty
            || (candidate.flatMap(selectedRange)?.length ?? 0) > 0
        let genericOpaque = !hasSelection && KeyboardSurfacePolicy.acceptsOpaque(focused: candidate.map(capabilities),
            standardWindow: standardWindow, modalWindow: modalWindow, pasteEnabled: paste.enabled)
        let weChatOpaque = KeyboardSurfacePolicy.acceptsOpaqueWeChat(bundleIdentifier: app.bundleIdentifier,
            focused: focused.map(capabilities), editor: editor.map(capabilities),
            standardWindow: standardWindow, modalWindow: modalWindow,
            windowTitle: window.flatMap { attribute($0, kAXTitleAttribute) as? String },
            pasteAvailable: paste.present)
        let opaqueApplication = !terminalSurface && (genericOpaque || weChatOpaque)
        let element = editor ?? focused
        let range = element.flatMap(selectedRange)
        let selection = element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? ""
        let secure = element.flatMap { attribute($0, kAXSubroleAttribute) as? String } == "AXSecureTextField"
        // Focus can change while a remote AX provider answers traversal/menu reads.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              sameElement(rawFocus, uiElement(attribute(root, kAXFocusedUIElementAttribute))),
              sameElement(window, uiElement(attribute(root, kAXFocusedWindowAttribute))) else { return nil }
        let editable = terminalSurface || opaqueApplication || (editor.map { capabilities($0).acceptsInsertion } ?? false)
        return InputTarget(pid: app.processIdentifier, name: app.localizedName ?? "App",
                           element: element, window: window, range: range, selection: selection,
                           value: terminalSurface ? nil : editor.flatMap { attribute($0, kAXValueAttribute) as? String }, secure: secure,
                           editable: editable,
                           keyboardSurface: terminalSurface || opaqueApplication,
                           opaqueApplication: opaqueApplication,
                           focusGuard: opaqueApplication && trackOpaqueFocus ? OpaqueInputFocusGuard(ignoring: shortcuts) : nil,
                           accessibilityPending: ElectronAccessibilityPolicy.capturePending(
                               enabled: electronEnabled[app.processIdentifier] != nil, editable: editable))
    }
    /// Explicit focus, its resolved focus target and the editor ancestor.
    private static func resolveFocus(_ root: AXUIElement) -> (raw: AXUIElement?, focused: AXUIElement?, editor: AXUIElement?) {
        let raw = uiElement(attribute(root, kAXFocusedUIElementAttribute))
        let focused = raw.flatMap {
            FocusedInputResolver.focusedTarget(from: $0, capabilities: capabilities,
                nestedFocus: { uiElement(attribute($0, kAXFocusedUIElementAttribute)) },
                children: { children($0) },
                isFocused: { attribute($0, kAXFocusedAttribute) as? Bool == true },
                equals: { CFEqual($0, $1) })
        }
        let editor = focused.flatMap {
            FocusedInputResolver.resolve(from: $0, capabilities: capabilities,
                parent: { uiElement(attribute($0, kAXParentAttribute)) }, equals: { CFEqual($0, $1) })
        }
        return (raw, focused, editor)
    }
    /// Announces VoiceDraft to an Electron app once per process so it builds its
    /// accessibility tree, then waits briefly for a focused element. Returns
    /// true when focus should be resolved again. Never uses AXEnhancedUserInterface.
    private static func enableElectronAccessibility(_ app: NSRunningApplication, root: AXUIElement, candidate: AXUIElement?) -> Bool {
        electronEnabled = electronEnabled.filter { pid, entry in
            NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated && $0.launchDate == entry.launched } ?? false
        }
        let pid = app.processIdentifier
        guard electronEnabled[pid] == nil else { return false }
        let name = ElectronAccessibilityPolicy.attribute as CFString
        var settable = DarwinBoolean(false)
        let canSet = AXUIElementIsAttributeSettable(root, name, &settable) == .success && settable.boolValue
        guard ElectronAccessibilityPolicy.shouldEnable(manualAccessibilitySettable: canSet,
                  focusedCapability: candidate.map { capabilities($0).capability }),
              AXUIElementSetAttributeValue(root, name, kCFBooleanTrue) == .success else { return false }
        electronEnabled[pid] = (app.launchDate, ProcessInfo.processInfo.systemUptime)
        // Capture runs on the main thread at recording start: never wait longer.
        let deadline = ProcessInfo.processInfo.systemUptime + ElectronAccessibilityPolicy.captureWaitSeconds
        repeat {
            Thread.sleep(forTimeInterval: ElectronAccessibilityPolicy.capturePollSeconds)
            if uiElement(attribute(root, kAXFocusedUIElementAttribute)) != nil { break }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return true
    }
    /// Re-captures a pending Electron target until its editor appears, the app
    /// changes, or the bounded retry window ends. Returns a same-process editable
    /// target, or nil to keep the copy-card path. Stops guards it does not return.
    static func refreshPending(_ target: InputTarget, ignoring shortcuts: [ShortcutBinding],
                               trackOpaqueFocus: Bool) async -> InputTarget? {
        let deadline = ElectronAccessibilityPolicy.retryDeadline(enabledAt: electronEnabled[target.pid]?.at,
                                                                 now: ProcessInfo.processInfo.systemUptime)
        while true {
            let refreshed = capture(ignoring: shortcuts, trackOpaqueFocus: trackOpaqueFocus)
            if let refreshed, ElectronAccessibilityPolicy.acceptsRefreshed(originalPID: target.pid,
                   refreshedPID: refreshed.pid, refreshedEditable: refreshed.editable) { return refreshed }
            refreshed?.focusGuard?.stop()
            guard refreshed?.pid == target.pid || refreshed == nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  (try? await Task.sleep(nanoseconds: UInt64(ElectronAccessibilityPolicy.retryPollSeconds * 1_000_000_000))) != nil
            else { return nil }
        }
    }
    /// Best effort on quit: turn Electron accessibility back off in apps
    /// VoiceDraft enabled, unless VoiceOver needs it to stay on.
    static func resetElectronAccessibility() {
        defer { electronEnabled = [:] }
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        for (pid, entry) in electronEnabled {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, app.launchDate == entry.launched else { continue }
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.1)
            _ = AXUIElementSetAttributeValue(root, ElectronAccessibilityPolicy.attribute as CFString, kCFBooleanFalse)
        }
    }
    private static func nativePasteAvailability(_ root: AXUIElement) -> (present: Bool, enabled: Bool) {
        guard let menuBar = uiElement(attribute(root, kAXMenuBarAttribute)) else { return (false, false) }
        var level = [menuBar], remaining = 160
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        // Menu bar → top-level item → menu → command. No chat-tree traversal.
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for item in level {
                remaining -= 1
                guard remaining >= 0, ProcessInfo.processInfo.systemUptime < deadline else { return (false, false) }
                let command = attribute(item, kAXMenuItemCmdCharAttribute) as? String
                let identifier = attribute(item, kAXIdentifierAttribute) as? String
                let modifiers = (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue
                if (command?.lowercased() == "v" && modifiers == 0) || identifier == "paste:" {
                    // Enabled depends on the old clipboard contents, not just focus.
                    // The dictation supplies its own text immediately before pasting.
                    return (true, attribute(item, kAXEnabledAttribute) as? Bool == true)
                }
                next += children(item).prefix(max(0, remaining - next.count))
            }
            level = next
        }
        return (false, false)
    }
    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        let nodes = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for node in nodes.prefix(160) { AXUIElementSetMessagingTimeout(node, 0.1) }
        return Array(nodes.prefix(160))
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
        guard !delivering else { throw VoiceDraftError.message("Could not send the paste shortcut.") }
        delivering = true
        defer { delivering = false }
        guard AXIsProcessTrusted() else { throw VoiceDraftError.message("Enable Accessibility to paste into other apps. The result is available here.") }
        guard !target.secure else { throw VoiceDraftError.message("Voice input is disabled in password fields.") }
        let board = NSPasteboard.general
        guard let previous = await InsertionClipboardReader.shared.read(name: board.name) else {
            throw VoiceDraftError.message("Could not copy the result.")
        }
        // Clipboard providers can yield. Revalidate the original take's target
        // after the read; never follow a new caret into another application.
        try Task.checkCancellation()
        guard let current = capture(trackOpaqueFocus: false), current.pid == target.pid else {
            throw VoiceDraftError.message("The active app changed. Copy the result when ready.")
        }
        guard sameElement(target.window, current.window) else {
            throw VoiceDraftError.message("The active window changed. Copy the result when ready.")
        }
        guard target.editable, current.editable, !current.secure,
              target.opaqueApplication == current.opaqueApplication,
              (!target.opaqueApplication || target.focusGuard?.valid == true),
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
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw VoiceDraftError.message("Could not send the paste shortcut.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              board.changeCount == previous.generation else { throw VoiceDraftError.message("Could not copy the result.") }
        board.clearContents()
        let supplied = board.writeObjects([item])
        let generation = board.changeCount
        defer { previous.restore(board, ifGeneration: generation) }
        guard supplied else { throw VoiceDraftError.message("Could not copy the result.") }
        target.focusGuard?.stop()
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
        if target.keyboardSurface && !target.opaqueApplication { return .sentToTerminal }
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

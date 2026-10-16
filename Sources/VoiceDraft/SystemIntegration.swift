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
    /// A writable AX editor (not an opaque or terminal keyboard surface).
    var writable: Bool { editable && !keyboardSurface }
}

enum TextInsertionOutcome: Equatable { case confirmed, sentToTerminal, sentWithoutConfirmation }

/// A queued paste. `outcome` resolves when the receipt window ends and the
/// user's clipboard has been restored; the delivery lease is held until then.
struct TextInsertionDelivery {
    let outcome: Task<TextInsertionOutcome, Never>
}

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
        return classify(app, ignoring: shortcuts, trackOpaqueFocus: trackOpaqueFocus, trace: nil)
    }
    /// The classification behind `capture` for one running app. With `trace`
    /// nil (every production call) a failed guard returns nil; with a trace (the
    /// `VOICEDRAFT_PROBE_INPUT` diagnostic only) each decision is reported as a
    /// key/value pair and the failed guards are reported instead of stopping.
    /// Traced values are roles, flags and lengths, never text content.
    static func classify(_ app: NSRunningApplication, ignoring shortcuts: [ShortcutBinding] = [],
                         trackOpaqueFocus: Bool = false, trace: ((String, String) -> Void)?) -> InputTarget? {
        func report(_ key: String, _ value: @autoclosure () -> String) { trace?(key, value()) }
        func describe(_ c: TextInputCapabilities?) -> String {
            guard let c else { return "nil" }
            return "role=\(c.role) capability=\(c.capability) enabled=\(c.enabled) secure=\(c.secure) "
                + "canReplaceSelection=\(c.canReplaceSelection) canSetValue=\(c.canSetValue) "
                + "canSetSelectionRange=\(c.canSetSelectionRange) acceptsInsertion=\(c.acceptsInsertion)"
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        var (rawFocus, focused, editor) = resolveFocus(root)
        report("resolveFocus.initial", "raw=\(rawFocus != nil) focused=\(focused != nil) editor=\(editor != nil)")
        let electronRetried = enableElectronAccessibility(app, root: root, candidate: editor ?? focused)
        report("electronAccessibility.enabledAndRetried", "\(electronRetried)")
        if electronRetried {
            (rawFocus, focused, editor) = resolveFocus(root)
            report("resolveFocus.afterElectron", "raw=\(rawFocus != nil) focused=\(focused != nil) editor=\(editor != nil)")
        }
        let focusResolved = rawFocus == nil || focused != nil
        report("guard.rawFocusNilOrFocusedResolved", "\(focusResolved)")
        guard focusResolved || trace != nil else { return nil }
        let window = uiElement(attribute(root, kAXFocusedWindowAttribute))
        // Terminal allowlist (Warp, Ghostty): reported as "Paste sent to terminal".
        let standardWindow = window.flatMap { attribute($0, kAXSubroleAttribute) as? String } == kAXStandardWindowSubrole
        let modalWindow = window.flatMap { attribute($0, kAXModalAttribute) as? Bool } == true
        report("capabilities.focused", describe(focused.map(capabilities)))
        report("capabilities.editor", describe(editor.map(capabilities)))
        report("window.present", "\(window != nil)")
        report("standardWindow", "\(standardWindow)")
        report("modalWindow", "\(modalWindow)")
        let terminalSurface = KeyboardSurfacePolicy.accepts(bundleIdentifier: app.bundleIdentifier,
            focused: focused.map(capabilities), editor: editor.map(capabilities),
            standardWindow: standardWindow, modalWindow: modalWindow)
        report("KeyboardSurfacePolicy.accepts", "\(terminalSurface)")
        // Paste unless there is evidence the focus is not an input: an opaque
        // focus, or no focused element at all, is pasted into when a focused
        // window exists. Opaque targets are insertion-only: no selection or value.
        let candidate = editor ?? focused
        let opaqueApplication = !terminalSurface && KeyboardSurfacePolicy.acceptsOpaque(
            focused: candidate.map(capabilities), focusedWindow: window != nil)
        report("KeyboardSurfacePolicy.acceptsOpaque", "\(opaqueApplication)")
        let element = editor ?? focused
        let range = element.flatMap(selectedRange)
        let selection = opaqueApplication ? "" : element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? ""
        let secure = element.flatMap { attribute($0, kAXSubroleAttribute) as? String } == "AXSecureTextField"
        // Focus can change while a remote AX provider answers traversal reads.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        // Short-circuits like a single guard unless traced, so production reads stay the same.
        let sameFocus = (frontmost || trace != nil)
            && sameElement(rawFocus, uiElement(attribute(root, kAXFocusedUIElementAttribute)))
        let sameWindow = ((frontmost && sameFocus) || trace != nil)
            && sameElement(window, uiElement(attribute(root, kAXFocusedWindowAttribute)))
        report("guard.stillFrontmost", "\(frontmost)")
        report("guard.sameFocusedElement", "\(sameFocus)")
        report("guard.sameFocusedWindow", "\(sameWindow)")
        guard (frontmost && sameFocus && sameWindow) || trace != nil else { return nil }
        let writable = editor.map { capabilities($0).acceptsInsertion } ?? false
        let editable = terminalSurface || opaqueApplication || writable
        report("target.editable", "\(editable)")
        report("target.keyboardSurface", "\(terminalSurface || opaqueApplication)")
        report("target.opaqueApplication", "\(opaqueApplication)")
        report("target.secure", "\(secure)")
        report("target.selectionLength", "\(selection.utf16.count)")
        report("target.range", range.map { "location=\($0.location) length=\($0.length)" } ?? "nil")
        report("capture.wouldReturnTarget", "\(focusResolved && frontmost && sameFocus && sameWindow)")
        return InputTarget(pid: app.processIdentifier, name: app.localizedName ?? "App",
                           element: element, window: window, range: range, selection: selection,
                           value: terminalSurface || opaqueApplication ? nil : editor.flatMap { attribute($0, kAXValueAttribute) as? String }, secure: secure,
                           editable: editable,
                           keyboardSurface: terminalSurface || opaqueApplication,
                           opaqueApplication: opaqueApplication,
                           focusGuard: opaqueApplication && trackOpaqueFocus ? OpaqueInputFocusGuard(ignoring: shortcuts) : nil,
                           accessibilityPending: ElectronAccessibilityPolicy.capturePending(
                               enabled: electronEnabled[app.processIdentifier] != nil, writable: writable || terminalSurface))
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
    /// Re-captures a pending Electron target until a writable editor appears, the
    /// app changes, or the bounded retry window ends. Returns a same-process
    /// writable target, or nil to keep the original target (an opaque fallback
    /// paste, or the copy card when it is not editable). Stops guards it does not return.
    static func refreshPending(_ target: InputTarget, ignoring shortcuts: [ShortcutBinding],
                               trackOpaqueFocus: Bool) async -> InputTarget? {
        let deadline = ElectronAccessibilityPolicy.retryDeadline(enabledAt: electronEnabled[target.pid]?.at,
                                                                 now: ProcessInfo.processInfo.systemUptime)
        while true {
            let refreshed = capture(ignoring: shortcuts, trackOpaqueFocus: trackOpaqueFocus)
            if let refreshed, ElectronAccessibilityPolicy.acceptsRefreshed(originalPID: target.pid,
                   refreshedPID: refreshed.pid, refreshedWritable: refreshed.writable) { return refreshed }
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
    /// Sends one Command-V into the original target and returns as soon as it is
    /// queued. Every pre-post failure throws, releases the delivery lease and
    /// restores the clipboard if it was already written. After posting, an
    /// unstructured main-actor task (never a child of the caller, so cancelling the
    /// take cannot shorten it) observes the receipt per `InsertionReceiptPolicy`,
    /// restores the user's clipboard and releases the lease on every path.
    static func send(_ text: String, into target: InputTarget) async throws -> TextInsertionDelivery {
        try Task.checkCancellation()
        // A previous delivery's temporary text may still be on the clipboard. Wait
        // for its lease before reading the snapshot, or that text would later be
        // restored as the user's clipboard.
        var waited = 0
        while delivering {
            guard waited < 40 else { throw VoiceDraftError.message("Could not send the paste shortcut.") }
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            waited += 1
        }
        delivering = true
        var handedOff = false
        defer { if !handedOff { delivering = false } }
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
        guard supplied else {
            previous.restore(board, ifGeneration: generation)
            throw VoiceDraftError.message("Could not copy the result.")
        }
        target.focusGuard?.stop()
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        handedOff = true
        let policy = InsertionReceiptPolicy(keyboardSurface: target.keyboardSurface)
        let element = policy.observesAccessibility ? current.element : nil
        let keyboardSurface = target.keyboardSurface, opaqueApplication = target.opaqueApplication
        let outcome = Task { @MainActor () -> TextInsertionOutcome in
            // The paste is already queued: keep the clipboard available for the
            // whole bounded window regardless of cancellation, then restore it.
            defer { previous.restore(board, ifGeneration: generation); delivering = false }
            // AX/event success only acknowledges delivery. Wait for the actual
            // field update before claiming success, without retrying and duplicating text.
            for _ in 0..<policy.attempts {
                await Task.detached { try? await Task.sleep(nanoseconds: policy.intervalNanoseconds) }.value
                if let element, receipt.confirms(value: attribute(element, kAXValueAttribute) as? String,
                                                 range: nsRange(selectedRange(element))) { return .confirmed }
            }
            // Terminal echo is not an AX value/selection replacement. Keep the
            // honest distinction between sending paste and observing inserted text.
            if keyboardSurface && !opaqueApplication { return .sentToTerminal }
            // A rich editor can accept paste without exposing an exact AX receipt.
            // Missing confirmation is not a failed send: prompting Copy here can
            // duplicate text that already arrived. Keep it distinct from confirmed.
            return .sentWithoutConfirmation
        }
        return TextInsertionDelivery(outcome: outcome)
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

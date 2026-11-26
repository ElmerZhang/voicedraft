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
    /// VoiceDraft enabled this app's Electron accessibility tree, which may not
    /// have been built yet; a later capture can still find the editor.
    var accessibilityPending = false
    /// Captured with the target; never resolve the app from HUD focus or a reused PID.
    var bundleID: String? = nil
    /// AX role of the resolved element, or of the focused window when the
    /// window itself is the target (diagnostics only).
    var role: String? = nil
    /// A writable AX editor (not an opaque or terminal keyboard surface).
    var writable: Bool { editable && !keyboardSurface }
}

enum TextInsertionOutcome: Equatable { case confirmed, sentToTerminal, sentWithoutConfirmation }

/// A queued paste. `outcome` resolves when the receipt window ends and the
/// user's clipboard has been restored; the delivery lease is held at most until
/// then and is released with the restore, which may come earlier on consumption.
/// `target` is the input actually pasted into; the paste card, opaque decision,
/// per-app mute and correction observation use it, not the take-start capture.
struct TextInsertionDelivery {
    let outcome: Task<TextInsertionOutcome, Never>
    let target: InputTarget
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
    static func capture() -> InputTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return classify(app, trace: nil)
    }
    /// The classification behind `capture` for one running app. With `trace`
    /// nil (every production call) a failed guard returns nil; with a trace (the
    /// `VOICEDRAFT_PROBE_INPUT` diagnostic only) each decision is reported as a
    /// key/value pair and the failed guards are reported instead of stopping.
    /// Traced values are roles, flags and lengths, never text content.
    static func classify(_ app: NSRunningApplication, trace: ((String, String) -> Void)?) -> InputTarget? {
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
        let role = element.map { attribute($0, kAXRoleAttribute) as? String ?? "" }
            ?? window.map { attribute($0, kAXRoleAttribute) as? String ?? kAXWindowRole }
        return InputTarget(pid: app.processIdentifier, name: app.localizedName ?? "App",
                           element: element, window: window, range: range, selection: selection,
                           value: terminalSurface || opaqueApplication ? nil : editor.flatMap { attribute($0, kAXValueAttribute) as? String }, secure: secure,
                           editable: editable,
                           keyboardSurface: terminalSurface || opaqueApplication,
                           opaqueApplication: opaqueApplication,
                           accessibilityPending: ElectronAccessibilityPolicy.capturePending(
                               enabled: electronEnabled[app.processIdentifier] != nil, writable: writable || terminalSurface),
                           bundleID: app.bundleIdentifier, role: role)
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
    /// paste, or the copy card when it is not editable).
    static func refreshPending(_ target: InputTarget) async -> InputTarget? {
        let deadline = ElectronAccessibilityPolicy.retryDeadline(enabledAt: electronEnabled[target.pid]?.at,
                                                                 now: ProcessInfo.processInfo.systemUptime)
        while true {
            let refreshed = capture()
            if let refreshed, ElectronAccessibilityPolicy.acceptsRefreshed(originalPID: target.pid,
                   refreshedPID: refreshed.pid, refreshedWritable: refreshed.writable) { return refreshed }
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
    /// Sends one Command-V and returns as soon as it is queued. `binding` picks
    /// the input: `.currentInput` pastes into the focus current after the
    /// clipboard snapshot, in any app and window (ordinary dictation since
    /// 2026-11-04, after TypeFlux's published behaviour); `.selection` requires
    /// `start`'s app, window, input and selection to be unchanged (Edit, Style
    /// apply). Every pre-post failure throws `InsertionFailure`, releases the
    /// delivery lease and restores the clipboard if it was already written. After
    /// posting, an unstructured main-actor task (never a child of the caller, so
    /// cancelling the take cannot shorten it) observes the receipt per
    /// `InsertionReceiptPolicy`. The user's clipboard is restored and the lease
    /// released once, on the first of confirmation, the text's first pasteboard
    /// read plus a short grace, or the end of the window.
    static func send(_ text: String, binding: InsertionBinding, start: InputTarget? = nil) async throws -> TextInsertionDelivery {
        try await withDeliveryClipboard(waitForEditor: binding == .currentInput) { previous in
            let (target, fresh) = try validatedTarget(binding: binding, start: start)
            let outcome = try postPaste(text, previous: previous, fresh: fresh)
            return TextInsertionDelivery(outcome: outcome, target: target)
        }
    }

    /// An explicit user paste goes to the frontmost responder just like Command-V.
    static func pasteDirectly(_ text: String) async throws {
        try await withDeliveryClipboard(waitForEditor: false) { previous in
            _ = try postPaste(text, previous: previous, fresh: nil)
        }
    }

    /// Hold the lease across the snapshot and transfer it to the posted paste's restoration task.
    private static func withDeliveryClipboard<Result>(waitForEditor: Bool,
        post: (InsertionClipboardSnapshot) throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        // A previous delivery's temporary text may still be on the clipboard. Wait
        // for its lease before reading the snapshot, or that text would later be
        // restored as the user's clipboard.
        var waited = 0
        while delivering {
            guard waited < 40 else { throw InsertionFailure(.pasteEvent) }
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            waited += 1
        }
        delivering = true
        var handedOff = false
        defer { if !handedOff { delivering = false } }
        guard AXIsProcessTrusted() else { throw InsertionFailure(.accessibility) }
        // A first read of the delivery-time focus. An Electron app this read just
        // enabled, or one enabled at take start, may still be building its tree:
        // wait (bounded) for its editor here, before the clipboard snapshot, so the
        // wait never holds the snapshot.
        if waitForEditor, let pending = capture(), pending.accessibilityPending, !pending.writable {
            _ = await refreshPending(pending)
            try Task.checkCancellation()
        }
        let board = NSPasteboard.general
        guard let previous = await InsertionClipboardReader.shared.read(name: board.name) else {
            throw InsertionFailure(.clipboard)
        }
        try Task.checkCancellation()
        let result = try post(previous)
        handedOff = true
        return result
    }

    private static func validatedTarget(binding: InsertionBinding, start: InputTarget?) throws -> (target: InputTarget, fresh: InputTarget) {
        let current = capture()
        func snapshot(_ t: InputTarget?) -> InsertionTargetPolicy.Snapshot? {
            t.map { .init(pid: $0.pid, editable: $0.editable, secure: $0.secure, opaque: $0.opaqueApplication, keyboardSurface: $0.keyboardSurface) }
        }
        let decision = InsertionTargetPolicy.decide(binding: binding, start: snapshot(start), current: snapshot(current),
            sameWindow: sameElement(start?.window, current?.window), sameElement: sameElement(start?.element, current?.element),
            selectionMatches: start.map { start in current.map { InputSelectionPolicy.matches(
                originalRange: nsRange(start.range), originalText: start.selection, originalValue: start.value,
                currentRange: nsRange($0.range), currentText: $0.selection, currentValue: $0.value,
                keyboardSurface: start.keyboardSurface) } ?? false } ?? false)
        // `target` is what the caller sees as pasted into; the receipt observes the
        // delivery-time read of that same input (`fresh`).
        switch (decision, start, current) {
        case (.blocked(let reason), _, _): throw InsertionFailure(reason, deliveryRole: current?.role)
        case (.start, let start?, let now?): return (start, now)
        case (.current, _, let now?): return (now, now)
        default: throw InsertionFailure(.noFocus)
        }
    }

    static func postPaste(_ text: String, previous: InsertionClipboardSnapshot, fresh: InputTarget?,
                          board: NSPasteboard = .general, postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) throws -> Task<TextInsertionOutcome, Never> {
        // Chromium can acknowledge AXSelectedText writes without implementing
        // the replacement action. Use the editor's normal paste path instead.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw InsertionFailure(.pasteEvent, deliveryRole: fresh?.role)
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        // The text is supplied lazily so the first read marks consumption; the
        // transient marker stays eager so clipboard managers see it up front.
        let provider = InsertionClipboardProvider(text: text)
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              board.changeCount == previous.generation else { throw InsertionFailure(.clipboard, deliveryRole: fresh?.role) }
        board.clearContents()
        let supplied = board.writeObjects([item])
        let generation = board.changeCount
        guard supplied else {
            previous.restore(board, ifGeneration: generation)
            throw InsertionFailure(.clipboard, deliveryRole: fresh?.role)
        }
        postEvent(down); postEvent(up)
        let policy = InsertionReceiptPolicy(keyboardSurface: fresh?.keyboardSurface == true)
        let element = policy.observesAccessibility ? fresh?.element : nil
        let receipt = fresh.map { input in
            let range = nsRange(input.range) ?? (input.value == "" ? NSRange(location: 0, length: 0) : nil)
            return TextInsertionReceipt(value: input.value, range: range, replacement: text)
        }
        let restoration = InsertionClipboardRestoration(previous: previous, board: board, generation: generation) {
            delivering = false
        }
        // Once the pasteboard hands the text to a reader, restore after a short
        // grace instead of waiting out the receipt window. A reader that ignores
        // the transient marker and fetches first shortens the window to the grace.
        // Unstructured like the outcome task: cancelling the take must not shorten it.
        Task { @MainActor in
            await provider.waitForFirstRequest()
            guard !restoration.finished else { return }
            await Task.detached { try? await Task.sleep(nanoseconds: policy.consumptionGraceNanoseconds) }.value
            restoration.finish()
        }
        return Task { @MainActor () -> TextInsertionOutcome in
            // The paste is already queued: keep the clipboard available until it
            // is consumed or the bounded window ends, regardless of cancellation.
            // Receipt polling continues independently of the restore.
            defer { restoration.finish(); provider.stopWaiting() }
            // AX/event success only acknowledges delivery. Wait for the actual
            // field update before claiming success, without retrying and duplicating text.
            if let element, let receipt {
                for _ in 0..<policy.attempts {
                    await Task.detached { try? await Task.sleep(nanoseconds: policy.intervalNanoseconds) }.value
                    if receipt.confirms(value: attribute(element, kAXValueAttribute) as? String,
                                        range: nsRange(selectedRange(element))) { return .confirmed }
                }
            } else {
                let timeout = UInt64(policy.attempts) * policy.intervalNanoseconds
                await Task.detached { try? await Task.sleep(nanoseconds: timeout) }.value
            }
            // Terminal echo is not an AX value/selection replacement. Keep the
            // honest distinction between sending paste and observing inserted text.
            if let fresh, fresh.keyboardSurface && !fresh.opaqueApplication { return .sentToTerminal }
            // A rich editor can accept paste without exposing an exact AX receipt.
            // Missing confirmation is not a failed send: prompting Copy here can
            // duplicate text that already arrived. Keep it distinct from confirmed.
            return .sentWithoutConfirmation
        }
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

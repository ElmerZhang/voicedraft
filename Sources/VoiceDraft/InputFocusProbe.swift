import AppKit
import ApplicationServices

/// Hidden diagnostic launch mode `VOICEDRAFT_PROBE_INPUT=<bundle identifier>`.
/// Prints, with VoiceDraft's own Accessibility grant, the focused AX element of
/// another running app, its ancestors and window, then traces
/// `TextInsertion.classify`, the code path behind `capture`. It prints roles,
/// flags, attribute names and lengths only, never text content, and starts
/// nothing else: no settings, history, hotkeys, windows or updater.
@MainActor
enum InputFocusProbe {
    static let environmentKey = "VOICEDRAFT_PROBE_INPUT"

    /// Runs the probe and returns the process exit code.
    static func run(bundleIdentifier: String) -> Int32 {
        let trusted = AXIsProcessTrusted()
        emit("probe.bundleIdentifier", bundleIdentifier)
        emit("AXIsProcessTrusted", "\(trusted)")
        guard trusted else { emit("result", "not trusted"); return 2 }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated }) else { emit("result", "not running"); return 1 }
        emit("app.pid", "\(app.processIdentifier)")
        emit("app.isActive", "\(app.isActive)")
        emit("frontmost.bundleIdentifier", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        if let raw = element(TextInsertion.attribute(root, kAXFocusedUIElementAttribute)) {
            dump(raw, prefix: "focus")
            var node = raw
            for level in 1...8 {
                guard let parent = element(TextInsertion.attribute(node, kAXParentAttribute)) else { break }
                dump(parent, prefix: "ancestor\(level)")
                node = parent
            }
        } else {
            emit("focus", "nil")
        }
        if let window = element(TextInsertion.attribute(root, kAXFocusedWindowAttribute)) {
            emit("window.role", string(window, kAXRoleAttribute))
            emit("window.subrole", string(window, kAXSubroleAttribute))
            emit("window.modal", flag(window, kAXModalAttribute))
            emit("window.titleLength", (TextInsertion.attribute(window, kAXTitleAttribute) as? String).map { "\($0.utf16.count)" } ?? "nil")
        } else {
            emit("window", "nil")
        }

        let target = TextInsertion.classify(app, trace: { emit("classify.\($0)", $1) })
        emit("classify.returnedTarget", "\(target != nil)")
        target?.focusGuard?.stop()
        TextInsertion.resetElectronAccessibility()
        emit("result", "done")
        return 0
    }

    private static func dump(_ node: AXUIElement, prefix: String) {
        emit("\(prefix).role", string(node, kAXRoleAttribute))
        emit("\(prefix).subrole", string(node, kAXSubroleAttribute))
        let value = TextInsertion.attribute(node, kAXValueAttribute)
        emit("\(prefix).value", describe(value))
        emit("\(prefix).selectedTextLength",
             (TextInsertion.attribute(node, kAXSelectedTextAttribute) as? String).map { "\($0.utf16.count)" } ?? "nil")
        emit("\(prefix).selectedRange", range(node))
        emit("\(prefix).valueSettable", settable(node, kAXValueAttribute))
        emit("\(prefix).selectedTextSettable", settable(node, kAXSelectedTextAttribute))
        emit("\(prefix).selectedTextRangeSettable", settable(node, kAXSelectedTextRangeAttribute))
        emit("\(prefix).enabled", flag(node, kAXEnabledAttribute))
        emit("\(prefix).focused", flag(node, kAXFocusedAttribute))
        emit("\(prefix).attributes", names { AXUIElementCopyAttributeNames(node, &$0) })
        emit("\(prefix).parameterizedAttributes", names { AXUIElementCopyParameterizedAttributeNames(node, &$0) })
        emit("\(prefix).actions", names { AXUIElementCopyActionNames(node, &$0) })
    }

    /// Type and size only: strings report their UTF-16 length, never the text.
    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "absent" }
        if let text = value as? String { return "present type=string length=\(text.utf16.count)" }
        if let array = value as? [Any] { return "present type=array count=\(array.count)" }
        if let number = value as? NSNumber { return "present type=number" + (CFGetTypeID(number) == CFBooleanGetTypeID() ? " bool" : "") }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "present type=element" }
        if CFGetTypeID(value) == AXValueGetTypeID() { return "present type=axvalue kind=\(AXValueGetType(value as! AXValue).rawValue)" }
        return "present type=cftype id=\(CFGetTypeID(value))"
    }

    private static func range(_ node: AXUIElement) -> String {
        guard let value = TextInsertion.attribute(node, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return "nil" }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return "nil" }
        return "location=\(range.location) length=\(range.length)"
    }

    private static func settable(_ node: AXUIElement, _ name: String) -> String {
        var value = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(node, name as CFString, &value)
        return error == .success ? "\(value.boolValue)" : "error(\(error.rawValue))"
    }

    private static func flag(_ node: AXUIElement, _ name: String) -> String {
        (TextInsertion.attribute(node, name) as? Bool).map { "\($0)" } ?? "nil"
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String {
        TextInsertion.attribute(node, name) as? String ?? "nil"
    }

    private static func names(_ copy: (inout CFArray?) -> AXError) -> String {
        var array: CFArray?
        let error = copy(&array)
        guard error == .success else { return "error(\(error.rawValue))" }
        return ((array as? [String]) ?? []).joined(separator: ",")
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let node = value as! AXUIElement
        AXUIElementSetMessagingTimeout(node, 0.1)
        return node
    }

    private static func emit(_ key: String, _ value: String) {
        print("\(key)=\(value)")
        fflush(stdout)
    }
}

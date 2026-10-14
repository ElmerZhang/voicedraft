import Foundation

public enum TextInputCapability: Equatable { case writable, notWritable, opaque }

/// A focused editor can accept a paste even when AX cannot replace its text.
/// Chromium's editable web fields expose a writable selection range in that case.
public struct TextInputCapabilities {
    public var role: String
    public var enabled: Bool
    public var secure: Bool
    public var canReplaceSelection: Bool
    public var canSetValue: Bool
    public var canSetSelectionRange: Bool

    public init(role: String, enabled: Bool = true, secure: Bool = false,
                canReplaceSelection: Bool = false, canSetValue: Bool = false,
                canSetSelectionRange: Bool = false) {
        self.role = role; self.enabled = enabled; self.secure = secure
        self.canReplaceSelection = canReplaceSelection; self.canSetValue = canSetValue
        self.canSetSelectionRange = canSetSelectionRange
    }

    public var acceptsInsertion: Bool {
        capability == .writable
    }

    public var capability: TextInputCapability {
        guard enabled, !secure else { return .notWritable }
        if isTextControl {
            return canReplaceSelection || canSetValue || canSetSelectionRange ? .writable : .opaque
        }
        return ["AXGroup", "AXUnknown", "AXLayoutArea", "AXWebArea", "AXScrollArea",
                "AXWindow", "AXSplitGroup", "AXList", "AXOutline", "AXTable"].contains(role) ? .opaque : .notWritable
    }

    public var isTextControl: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) }
    public var canBeTextDescendant: Bool { ["AXStaticText", "AXGroup", "AXUnknown", "AXLayoutArea"].contains(role) }
}

/// Resolve explicit focus, then canonicalize focused paragraph/text children to
/// their editor ancestors. Never choose an unrelated editor in the window.
public enum FocusedInputResolver {
    /// Only explicit focus evidence can promote a descendant. Finding an editor
    /// elsewhere in the same window is not enough. Bounds also cover malformed trees.
    public static func focusedTarget<Node>(from root: Node, capabilities: (Node) -> TextInputCapabilities,
        nestedFocus: (Node) -> Node?, children: (Node) -> [Node], isFocused: (Node) -> Bool,
        equals: (Node, Node) -> Bool, limit: Int = 32, seconds: TimeInterval = 0.5,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Node? {
        let deadline = now() + seconds
        var remaining = limit
        var visited: [Node] = []
        func take(_ node: Node) -> Bool {
            guard remaining > 0, now() < deadline, !visited.contains(where: { equals($0, node) }) else { return false }
            remaining -= 1; visited.append(node); return true
        }
        var current = root
        while take(current) {
            let traits = capabilities(current)
            if traits.secure || !traits.enabled || traits.isTextControl { return current }
            // Known non-input controls cannot authorize searching another field.
            guard traits.capability == .opaque else { return current }
            if let nested = nestedFocus(current), !equals(nested, current) {
                if visited.contains(where: { equals($0, nested) }) { return nil }
                current = nested; continue
            }
            var pending = Array(children(current).prefix(max(0, remaining)))
            var index = 0
            while index < pending.count, remaining > 0, now() < deadline {
                let child = pending[index]; index += 1
                guard take(child) else { continue }
                if isFocused(child) { return child }
                let childTraits = capabilities(child)
                if childTraits.enabled, !childTraits.secure, childTraits.capability == .opaque {
                    pending.append(contentsOf: children(child).prefix(max(0, remaining - (pending.count - index))))
                }
            }
            return current
        }
        return nil
    }

    public static func resolve<Node>(from focused: Node, capabilities: (Node) -> TextInputCapabilities,
                                     parent: (Node) -> Node?, equals: (Node, Node) -> Bool) -> Node? {
        var node = focused
        var visited: [Node] = []
        for _ in 0..<16 {
            guard !visited.contains(where: { equals($0, node) }) else { return nil }
            visited.append(node)
            let traits = capabilities(node)
            // Stop at the nearest input, including disabled/password inputs;
            // never climb past one to find a more permissive outer editor.
            if traits.isTextControl || traits.secure { return node }
            guard traits.enabled, traits.canBeTextDescendant, let ancestor = parent(node) else { return nil }
            node = ancestor
        }
        return nil
    }
}

public enum InputSelectionPolicy {
    public static func matches(originalRange: NSRange?, originalText: String, originalValue: String?,
                               currentRange: NSRange?, currentText: String, currentValue: String?,
                               keyboardSurface: Bool) -> Bool {
        guard originalText == currentText else { return false }
        if originalRange == currentRange { return true }
        // Scrolling terminal output moves AX offsets, not the TTY input cursor.
        // A selected region still requires an exact match.
        if keyboardSurface, originalText.isEmpty,
           (originalRange?.length ?? 0) == 0, (currentRange?.length ?? 0) == 0 { return true }
        // Empty web editors sometimes publish their zero caret after AX focus.
        // Unknown selection in nonempty text remains unknown, never assumed zero.
        return originalText.isEmpty && originalValue == "" && currentValue == ""
            && (originalRange == nil || originalRange == NSRange(location: 0, length: 0))
            && (currentRange == nil || currentRange == NSRange(location: 0, length: 0))
    }
}

public enum KeyboardSurfacePolicy {
    /// A generic opaque target needs an actual focused control and an enabled
    /// native Paste command. Window-only compatibility stays separately scoped.
    public static func acceptsOpaque(focused: TextInputCapabilities?, standardWindow: Bool,
                                     modalWindow: Bool, pasteEnabled: Bool) -> Bool {
        guard let focused, focused.capability == .opaque, focused.role != "AXWindow",
              standardWindow, !modalWindow, pasteEnabled else { return false }
        return true
    }
    /// WeChat 4.x can expose only the main window and its standard controls.
    /// Require its native Paste command as an additional input signal.
    public static func acceptsOpaqueWeChat(bundleIdentifier: String?, focused: TextInputCapabilities?,
                                          editor: TextInputCapabilities?, standardWindow: Bool,
                                          modalWindow: Bool, windowTitle: String?, pasteAvailable: Bool) -> Bool {
        guard bundleIdentifier == "com.tencent.xinWeChat", standardWindow, !modalWindow,
              ["Weixin", "WeChat", "微信"].contains(windowTitle ?? ""), editor == nil, pasteAvailable else { return false }
        guard let focused else { return true }
        return focused.enabled && !focused.secure
            && ["AXWindow", "AXGroup", "AXUnknown", "AXLayoutArea"].contains(focused.role)
    }

    public static func accepts(bundleIdentifier: String?, focused: TextInputCapabilities?, editor: TextInputCapabilities?,
                               standardWindow: Bool, modalWindow: Bool) -> Bool {
        guard bundleIdentifier == "dev.warp.Warp-Stable", standardWindow, !modalWindow else { return false }
        guard focused?.enabled != false, focused?.secure != true, editor?.enabled != false, editor?.secure != true else { return false }
        if let editor {
            // A terminal's read-only AX text area represents the output grid;
            // keyboard input still goes to the TTY. Real form fields stay strict.
            return editor.role == "AXTextArea" && !editor.canSetValue
        }
        guard let focused else { return true }
        return ["AXGroup", "AXUnknown", "AXLayoutArea", "AXScrollArea"].contains(focused.role)
    }
}

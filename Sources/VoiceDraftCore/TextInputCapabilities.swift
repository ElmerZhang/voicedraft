import Foundation

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
        guard enabled, !secure, isTextControl else { return false }
        return canReplaceSelection || canSetValue || canSetSelectionRange
    }

    public var isTextControl: Bool { ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) }
    public var canBeTextDescendant: Bool { ["AXStaticText", "AXGroup", "AXUnknown", "AXLayoutArea"].contains(role) }
}

/// Resolve only the focused node's ancestors, never another editor elsewhere in
/// the window. Web composers can focus a replaceable paragraph/text child.
public enum FocusedInputResolver {
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

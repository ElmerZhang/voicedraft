import Foundation

public enum TextInputCapability: Equatable { case writable, notWritable, opaque }

/// A focused editor can accept a paste even when AX cannot replace its text.
/// Chromium's editable web fields expose a writable selection range in that case.
/// Classification follows "paste unless there is evidence the focus is not an
/// input": see `capability` and `nonInputRoles`.
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

    /// Roles that are known not to be text inputs. A focus on one of these is
    /// `.notWritable`; every other role (windows, groups, web areas, cells, lists,
    /// custom roles) is `.opaque` and receives a Command-V with a fallback card.
    /// Reviewable denylist: add a role only when focus on it is never an input.
    public static let nonInputRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXRadioGroup", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXSlider", "AXIncrementor",
        "AXProgressIndicator", "AXBusyIndicator", "AXLevelIndicator", "AXDisclosureTriangle",
        "AXColorWell", "AXScrollBar", "AXSplitter", "AXHandle", "AXGrowArea", "AXValueIndicator",
        "AXStaticText", "AXLink", "AXImage", "AXHeading", "AXToolbar", "AXTabGroup", "AXDockItem",
        "AXRuler", "AXRulerMarker", "AXHelpTag", "AXMatte", "AXRelevanceIndicator",
    ]

    /// Paste unless there is evidence the focus is not an input: disabled or
    /// secure focus and known non-input roles refuse; text roles with a settable
    /// value, selected text or selection range are writable; everything else is opaque.
    public var capability: TextInputCapability {
        guard enabled, !secure else { return .notWritable }
        if isTextControl {
            return canReplaceSelection || canSetValue || canSetSelectionRange ? .writable : .opaque
        }
        return Self.nonInputRoles.contains(role) ? .notWritable : .opaque
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
    /// An opaque focus (a window, group, web area, custom role or a text role
    /// without settable AX text) receives Command-V whenever the app has a
    /// focused window. With no focused element at all (`focused` nil) the
    /// focused window itself is the target. No focused window: not editable.
    /// The fallback result card is the safety net when the paste goes nowhere.
    public static func acceptsOpaque(focused: TextInputCapabilities?, focusedWindow: Bool) -> Bool {
        guard focusedWindow else { return false }
        guard let focused else { return true }
        return focused.capability == .opaque
    }

    /// Terminals whose standard, nonmodal window exposes the TTY grid as a text
    /// area without a writable value, or no editor at all. Ghostty's surface is an
    /// `AXTextArea` whose value is the screen contents, with no settable value or
    /// selection range (probed 2026-10-16). Such a surface would also be pasted
    /// into as generic opaque input; this allowlist is kept only because it yields
    /// the more precise "Paste sent to terminal" outcome.
    public static let terminalBundleIdentifiers: Set<String> = ["dev.warp.Warp-Stable", "com.mitchellh.ghostty"]

    public static func accepts(bundleIdentifier: String?, focused: TextInputCapabilities?, editor: TextInputCapabilities?,
                               standardWindow: Bool, modalWindow: Bool) -> Bool {
        guard let bundleIdentifier, terminalBundleIdentifiers.contains(bundleIdentifier), standardWindow, !modalWindow else { return false }
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

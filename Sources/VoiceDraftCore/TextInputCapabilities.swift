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
        guard enabled, !secure else { return false }
        if canReplaceSelection { return true }
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else { return false }
        return canSetValue || canSetSelectionRange
    }
}

import Foundation

/// Which input a finished result may be pasted into.
public enum InsertionBinding: Equatable, Sendable {
    /// Ordinary dictation and Insert last result: the focus that is current when
    /// the result is ready, in whatever app and window that is.
    case currentInput
    /// Edit and Style apply replace the selection captured at the start, so the
    /// same app, window, input and selection must still be focused.
    case selection
}

/// Stable machine keys for a refused insertion (`takes.jsonl`); never localized.
public enum InsertionBlockReason: String, Codable, Equatable, Sendable {
    case noFocus, notEditable, secureField, appChanged, windowChanged, inputChanged, selectionChanged
    case clipboard, accessibility, pasteEvent

    /// The existing user-facing message for the reason.
    public var message: LocalizedMessage {
        switch self {
        case .noFocus, .notEditable: return "No text field is focused. Copy the result instead."
        case .secureField: return "Voice input is disabled in password fields."
        case .appChanged: return "The active app changed. Copy the result when ready."
        case .windowChanged: return "The active window changed. Copy the result when ready."
        case .inputChanged: return "The focused input changed. Copy the result when ready."
        case .selectionChanged: return "The text selection changed. Copy the result when ready."
        case .clipboard: return "Could not copy the result."
        case .accessibility: return "Enable Accessibility to paste into other apps. The result is available here."
        case .pasteEvent: return "Could not send the paste shortcut."
        }
    }
}

/// A paste that was refused before Command-V was posted. `deliveryRole` is the
/// AX role of the delivery-time focus, when one was read (diagnostics only).
public struct InsertionFailure: LocalizedError, Equatable {
    public let reason: InsertionBlockReason
    public var deliveryRole: String?
    public init(_ reason: InsertionBlockReason, deliveryRole: String? = nil) {
        self.reason = reason; self.deliveryRole = deliveryRole
    }
    public var errorDescription: String? { L(reason.message) }
}

/// The pre-send decision over the take-start capture and the delivery-time
/// capture (taken after the clipboard snapshot). Identity comparisons need AX
/// objects, so the caller supplies them as booleans.
public enum InsertionTargetPolicy {
    public struct Snapshot: Equatable, Sendable {
        public var pid: Int32
        public var editable: Bool
        public var secure: Bool
        public var opaque: Bool
        public var keyboardSurface: Bool
        public init(pid: Int32, editable: Bool, secure: Bool, opaque: Bool, keyboardSurface: Bool) {
            self.pid = pid; self.editable = editable; self.secure = secure; self.opaque = opaque; self.keyboardSurface = keyboardSurface
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Paste into the delivery-time capture (`currentInput`).
        case current
        /// Paste into the validated start capture (`selection`).
        case start
        case blocked(InsertionBlockReason)
    }

    /// `sameWindow`/`sameElement` compare the two captures' AX identities and
    /// `selectionMatches` is `InputSelectionPolicy.matches`; all three are only
    /// consulted for `.selection`. A `currentInput` delivery never compares with
    /// the start: an opaque/writable flip, a new element, window or app is fine.
    public static func decide(binding: InsertionBinding, start: Snapshot?, current: Snapshot?,
                              sameWindow: Bool, sameElement: Bool, selectionMatches: Bool) -> Decision {
        switch binding {
        case .currentInput:
            guard let current else { return .blocked(.noFocus) }
            // Password fields are classified non-writable; name them first.
            if current.secure { return .blocked(.secureField) }
            return current.editable ? .current : .blocked(.notEditable)
        case .selection:
            guard let start else { return .blocked(.noFocus) }
            if start.secure { return .blocked(.secureField) }
            guard let current, current.pid == start.pid else { return .blocked(.appChanged) }
            guard sameWindow else { return .blocked(.windowChanged) }
            guard start.editable, current.editable, !current.secure, start.opaque == current.opaque,
                  start.keyboardSurface == current.keyboardSurface, sameElement else { return .blocked(.inputChanged) }
            return selectionMatches ? .start : .blocked(.selectionChanged)
        }
    }
}

import Foundation

/// A saved-key indicator is presentation state, never a credential value.
public struct APIKeyDraft {
    public let hasSavedKey: Bool
    public var replacement = ""
    public var removeSavedKey = false

    public init(hasSavedKey: Bool) { self.hasSavedKey = hasSavedKey }

    public var showsSavedKey: Bool {
        hasSavedKey && !removeSavedKey && replacement.isEmpty
    }

    /// nil preserves the existing item; an empty string explicitly removes it.
    public var credentialUpdate: String? {
        let value = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        return removeSavedKey ? "" : nil
    }

    public func keyForRequest(loadSavedKey: () throws -> String) rethrows -> String {
        if let update = credentialUpdate { return update }
        return try loadSavedKey()
    }
}

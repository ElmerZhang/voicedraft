import Foundation

/// Checks the editor's observable result, not the success of an AX/event send.
/// AX text offsets use UTF-16, including for mixed-language and emoji dictation.
public struct TextInsertionReceipt {
    private let originalValue: String?
    private let originalRange: NSRange?
    private let expectedValue: String?
    private let expectedRange: NSRange?

    public init(value: String?, range: NSRange?, replacement: String) {
        originalValue = value
        originalRange = range
        guard let range, range.location >= 0, range.length >= 0,
              range.location != NSNotFound,
              range.location <= Int.max - (replacement as NSString).length else {
            expectedValue = nil; expectedRange = nil; return
        }
        if let value {
            guard range.location <= (value as NSString).length,
                  range.length <= (value as NSString).length - range.location else {
                expectedValue = nil; expectedRange = nil; return
            }
            expectedValue = (value as NSString).replacingCharacters(in: range, with: replacement)
        } else { expectedValue = nil }
        expectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
    }

    public func confirms(value: String?, range: NSRange?) -> Bool {
        if let expectedValue {
            guard value == expectedValue else { return false }
            // Replacing a selection with identical text still needs evidence
            // that the editor consumed the paste and collapsed the selection.
            return expectedValue != originalValue || (range == expectedRange && range != originalRange)
        }
        // Some rich editors omit AXValue. A changed caret at the exact expected
        // UTF-16 offset can still confirm insertion; an absent/unchanged range cannot.
        return expectedRange != nil && range == expectedRange && range != originalRange
    }
}

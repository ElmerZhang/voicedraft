import Foundation

/// How long a queued Command-V keeps its temporary clipboard alive, and whether
/// the original field is observed for an exact Accessibility receipt meanwhile.
/// Keyboard surfaces (terminals) expose no AX receipt, so they only need a short
/// grace for the target to read the clipboard; text fields poll for confirmation.
public struct InsertionReceiptPolicy: Equatable, Sendable {
    public let attempts: Int
    public let intervalNanoseconds: UInt64
    public let observesAccessibility: Bool
    /// Delay between the pasteboard's first request for the temporary text and
    /// restoring the user's clipboard. The grace covers a non-target reader (a
    /// clipboard manager that ignores the transient marker) fetching the text
    /// before the target's paste handler does.
    public let consumptionGraceNanoseconds: UInt64 = 200_000_000

    public init(keyboardSurface: Bool) {
        if keyboardSurface {
            attempts = 1; intervalNanoseconds = 300_000_000; observesAccessibility = false
        } else {
            attempts = 20; intervalNanoseconds = 75_000_000; observesAccessibility = true
        }
    }

    /// Upper bound of the clipboard window in seconds.
    public var maximumSeconds: Double { Double(attempts) * Double(intervalNanoseconds) / 1_000_000_000 }
}

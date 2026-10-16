import Foundation

/// Electron (and Chromium-based shells built on it) build their accessibility
/// tree only after an assistive client announces itself through the
/// application element's `AXManualAccessibility` attribute. Until then the
/// focused element is missing and dictation cannot insert. These rules decide
/// when VoiceDraft announces itself and when a capture is worth repeating;
/// the AX calls stay in the app target. `AXEnhancedUserInterface` is
/// deliberately not used: it causes window-animation side effects in other apps.
public enum ElectronAccessibilityPolicy {
    public static let attribute = "AXManualAccessibility"
    /// Bounded synchronous wait after the first enable, on the main thread at capture.
    public static let captureWaitSeconds: TimeInterval = 0.3
    public static let capturePollSeconds: TimeInterval = 0.05
    /// Asynchronous re-capture window before insertion. A cold Electron tree
    /// was measured at about 2.2 seconds after the first enable.
    public static let retryWindowSeconds: TimeInterval = 2.5
    public static let retryPollSeconds: TimeInterval = 0.25

    /// Announce only to apps that accept the attribute, and only when no
    /// writable editor is already focused.
    public static func shouldEnable(manualAccessibilitySettable: Bool, focusedCapability: TextInputCapability?) -> Bool {
        manualAccessibilitySettable && focusedCapability != .writable
    }

    /// A capture from an app VoiceDraft just enabled may predate its tree, so a
    /// focus that is not yet a writable editor can still become one. Opaque
    /// focus is editable (pasted with a fallback card) but still pending here,
    /// so a cold Slack waits for its composer instead of pasting into its window.
    public static func capturePending(enabled: Bool, writable: Bool) -> Bool {
        enabled && !writable
    }

    /// Repeat the capture before inserting only for a pending target that is
    /// not a writable editor and whose result would be inserted automatically.
    public static func shouldRetryCapture(pending: Bool, writable: Bool, external: Bool,
                                          autoPaste: Bool, ask: Bool) -> Bool {
        pending && !writable && external && autoPaste && !ask
    }

    /// The retry window counts from the enable, so a capture long after the
    /// tree was built is repeated once instead of stalling delivery.
    public static func retryDeadline(enabledAt: TimeInterval?, now: TimeInterval) -> TimeInterval {
        max(now, (enabledAt ?? now) + retryWindowSeconds)
    }

    /// A refreshed capture replaces the original only in the same process and
    /// only once it is a writable editor; otherwise the original opaque target
    /// (if any) gets the fallback paste after the window ends.
    public static func acceptsRefreshed(originalPID: Int32, refreshedPID: Int32, refreshedWritable: Bool) -> Bool {
        originalPID == refreshedPID && refreshedWritable
    }
}

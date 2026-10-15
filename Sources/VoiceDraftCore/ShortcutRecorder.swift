import Foundation

/// Decides what the Settings shortcut recorder does with one keyboard event.
/// The app reads the event fields and applies the decision; keeping the rules
/// here lets tests replay real event sequences without AppKit.
///
/// Read `isRepeat` only from key events: AppKit raises an exception when
/// `NSEvent.isARepeat` is sent to a `flagsChanged` event, which is how Fn and
/// every other modifier arrive.
public enum ShortcutRecorder {
    public enum EventType: Equatable { case keyDown, flagsChanged }
    public enum Decision: Equatable {
        /// Esc: stop recording and keep the saved binding.
        case cancel
        /// A modifier other than Fn changed: show the held set and let the event through.
        case updateLiveModifiers(UInt32)
        /// Nothing to record (Fn's release edge, a key repeat): swallow the event.
        case ignore
        /// Validate and save these keys.
        case record(keyCode: UInt32, modifiers: UInt32)
    }
    public static let escapeKeyCode: UInt32 = 53

    /// - Parameters:
    ///   - modifiers: held Shift = 1, Control = 2, Option = 4, Command = 8.
    ///   - fnHeld: whether the event flags contain the secondary-Fn (function) flag.
    ///   - isRepeat: the key-repeat flag of a key-down; ignored for `flagsChanged`.
    public static func decide(eventType: EventType, keyCode: UInt32, modifiers: UInt32, fnHeld: Bool, isRepeat: Bool) -> Decision {
        let held = modifiers & 15
        switch eventType {
        case .keyDown:
            if keyCode == escapeKeyCode { return .cancel }
            return isRepeat ? .ignore : .record(keyCode: keyCode, modifiers: held)
        case .flagsChanged:
            guard keyCode == ShortcutBinding.fnKeyCode else { return .updateLiveModifiers(held) }
            // Fn's press edge records Fn with whatever modifiers are already held.
            return fnHeld ? .record(keyCode: keyCode, modifiers: held) : .ignore
        }
    }
}

import AVFoundation

/// Owns every `AVAudioSession` call in the app. One shared instance is injected into `IOSAudioCapture` (the
/// microphone engine) and `IOSPictureInPictureKeepAlive` (standby residency), so both run under one session
/// configuration and a standby take never changes the category.
///
/// Why: on iOS 27.0.1 a category change made from the background after the app's audio IO stopped was refused with
/// `OSStatus 560557684 '!int'` even though both categories were mixable (2026-10-22, see `docs/ios.md`). With one
/// configuration, set and activated by whichever starts first (normally in the foreground), a background take makes
/// no session call. During standby the session stays active between takes.
final class IOSAudioSessionController {
    static let category: AVAudioSession.Category = .playAndRecord
    static let mode: AVAudioSession.Mode = .measurement
    static let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .mixWithOthers, .defaultToSpeaker]

    private let session: AVAudioSession
    private let lock = NSLock()
    private var active = false
    private var observers: [NSObjectProtocol] = []

    /// Whether the controller believes the session is active: set by `activate`, cleared by `deactivate`, an
    /// interruption or a media-services reset.
    var isActive: Bool { lock.withLock { active } }

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        let center = NotificationCenter.default
        // Delivered synchronously (no queue), so the flag is cleared before the engines' observers react.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // The system deactivated the session.
            self?.markInactive()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: nil) { [weak self] _ in
            self?.markInactive()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Sets the configuration only when the session's current one differs, and activates only when the session is
    /// not believed active. A session already configured and active (the usual case for an engine swap in the
    /// background) makes no `AVAudioSession` call at all.
    func activate() throws {
        try lock.withLock {
            // `isSuperset` tolerates option bits the system may report on its own.
            if session.category != Self.category || session.mode != Self.mode
                || !session.categoryOptions.isSuperset(of: Self.options) {
                try AudioStepError.run("session: setCategory(playAndRecord)") {
                    try session.setCategory(Self.category, mode: Self.mode, options: Self.options)
                }
            }
            if !active {
                try AudioStepError.run("session: setActive") { try session.setActive(true) }
                active = true
            }
        }
    }

    /// Deactivates the session and lets other apps' audio resume. Called only when neither standby nor a take
    /// needs audio.
    func deactivate() {
        lock.withLock {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            active = false
        }
    }

    private func markInactive() { lock.withLock { active = false } }
}

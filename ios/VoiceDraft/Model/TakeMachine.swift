import Foundation

/// The phase of one take. `AppStatus.State` adds `listening`, which is a session property, not a take phase.
enum TakeState: String, Equatable {
    case idle, recording, processing
}

/// Pure take state machine. AppModel routes every take transition through it, so the allowed transitions
/// are testable without audio or network.
struct TakeMachine: Equatable {
    enum Event: Equatable {
        /// Recording begins (in-app button or keyboard `take.start`).
        case start
        /// Recording ends and the pipeline runs (button release or keyboard `take.stop`).
        case stop
        /// The pipeline produced a result.
        case complete
        /// Microphone, recognition or writing failed.
        case fail
        /// The user or the system abandoned the take.
        case cancel
    }

    private(set) var state: TakeState = .idle

    /// Applies `event` and returns true when the state changed. Events that do not apply are ignored.
    @discardableResult
    mutating func handle(_ event: Event) -> Bool {
        let next: TakeState?
        switch (state, event) {
        case (.idle, .start): next = .recording
        case (.recording, .stop): next = .processing
        case (.recording, .fail), (.recording, .cancel): next = .idle
        case (.processing, .complete), (.processing, .fail), (.processing, .cancel): next = .idle
        default: next = nil
        }
        guard let next else { return false }
        state = next
        return true
    }
}

/// Builds the `app-status.json` the keyboard reads.
enum AppStatusPolicy {
    /// How long a written status stays valid. The app refreshes it well before then while listening.
    static let lease: TimeInterval = 15 * 60

    /// A take in progress reports `recording` or `processing`; otherwise a listening session reports `listening`.
    /// Only a listening session makes the status available to the keyboard: without one the expiry lies in
    /// the past, because a suspended app could not answer `take.start`.
    /// `until` is the standby deadline: the lease never outlives it, so the keyboard stops offering hold-to-talk
    /// when standby ends even if the app is suspended before it can write an idle status.
    /// `takeID` names the take in progress; it is dropped when `take` is idle.
    static func status(take: TakeState, listening: Bool, until deadline: Date? = nil, takeID: UUID? = nil,
                       lastError: String? = nil, now: Date = Date()) -> AppStatus {
        let state: AppStatus.State
        switch take {
        case .recording: state = .recording
        case .processing: state = .processing
        case .idle: state = listening ? .listening : .idle
        }
        let leaseEnd = min(now.addingTimeInterval(lease), deadline ?? .distantFuture)
        let expiresAt = listening ? leaseEnd : now.addingTimeInterval(-1)
        return AppStatus(state: state, expiresAt: expiresAt, updatedAt: now, takeID: take == .idle ? nil : takeID,
                         lastError: lastError)
    }
}

/// Keyboard standby: after a keyboard take starts, the app keeps the microphone open until a deadline so the
/// next keyboard take works through Darwin notifications without opening the app again.
enum StandbyPolicy {
    /// "Start standby now" with standby set to 0 still needs a duration.
    static let manualFallbackMinutes = 15

    /// The deadline after a keyboard take starts at `now`. Standby only ever extends: an existing later deadline
    /// is kept. With `minutes` 0 the current deadline (possibly none) is unchanged.
    static func deadline(extending current: Date?, minutes: Int, now: Date = Date()) -> Date? {
        guard minutes > 0 else { return current }
        let proposed = now.addingTimeInterval(TimeInterval(minutes * 60))
        guard let current else { return proposed }
        return max(current, proposed)
    }

    /// The deadline for "Start standby now".
    static func manualDeadline(minutes: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval((minutes > 0 ? minutes : manualFallbackMinutes) * 60))
    }
}

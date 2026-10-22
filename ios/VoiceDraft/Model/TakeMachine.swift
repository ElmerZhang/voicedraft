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
    static func status(take: TakeState, listening: Bool, now: Date = Date()) -> AppStatus {
        let state: AppStatus.State
        switch take {
        case .recording: state = .recording
        case .processing: state = .processing
        case .idle: state = listening ? .listening : .idle
        }
        let expiresAt = listening ? now.addingTimeInterval(lease) : now.addingTimeInterval(-1)
        return AppStatus(state: state, expiresAt: expiresAt, updatedAt: now)
    }
}

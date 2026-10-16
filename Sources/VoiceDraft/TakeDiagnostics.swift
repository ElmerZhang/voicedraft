import Foundation
import VoiceDraftCore

/// One line of the opt-in take timing diagnostics file. Timings and gesture
/// decisions only: never transcript text, audio, selections, credentials, or
/// app names beyond the bundle identifier.
struct TakeDiagnosticRecord: Codable, Equatable {
    var v = 1
    /// Take start (wall clock).
    var date: Date
    var takeID: UUID
    /// The shortcut that started the take; nil for an in-app start.
    var action: String?
    var mode: String
    var external: Bool
    var bundleID: String?
    /// Press: processing time minus the key event's own time.
    var pressDelayMs: Int?
    /// The synchronous `TextInsertion.capture` in `toggle`.
    var captureMs: Int?
    /// From the press event (or the in-app start) to `phase = "starting"`.
    var startingMs: Int?
    /// To the microphone's first buffer (`captureDidStart`).
    var microphoneMs: Int?
    /// To the live session's `task-started` (`onReady`); live adapters only.
    var taskStartedMs: Int?
    /// Release: processing time minus the key event's own time.
    var releaseDelayMs: Int?
    /// Release event time minus press event time.
    var heldMs: Int?
    /// The gesture's effect on release: `none` or `finish`.
    var releaseEffect: String?
    var locked: Bool
    /// A finish arrived while starting and ran as soon as capture started.
    var finishWhenReady: Bool
    var audioSeconds: Double?
    /// `completed`, `failed`, `noSpeech` or `cancelled`.
    var outcome: String
    /// `ModelUsageFailure.message` of the error; nil when completed or cancelled.
    var failure: String?
}

/// The running take's timings on the uptime clock; turned into a record once.
struct TakeTrace {
    let takeID: UUID
    let date: Date
    /// The press event time, or `toggle`'s own time for an in-app start.
    let origin: TimeInterval
    var action: ShortcutAction?
    var mode: WritingMode
    var external: Bool
    var bundleID: String?
    var pressDelay: TimeInterval?
    var capture: TimeInterval?
    var starting: TimeInterval?
    var microphone: TimeInterval?
    var taskStarted: TimeInterval?
    var releaseDelay: TimeInterval?
    var held: TimeInterval?
    var releaseEffect: String?
    var locked = false
    var finishWhenReady = false

    init(takeID: UUID, date: Date = Date(), origin: TimeInterval, action: ShortcutAction?, mode: WritingMode, external: Bool) {
        self.takeID = takeID; self.date = date; self.origin = origin
        self.action = action; self.mode = mode; self.external = external
    }
    /// Seconds from `origin` to uptime `time`.
    func since(_ time: TimeInterval) -> TimeInterval { time - origin }

    func record(audioSeconds: Double?, outcome: String, failure: Error?) -> TakeDiagnosticRecord {
        func ms(_ value: TimeInterval?) -> Int? { value.map { Int(($0 * 1000).rounded()) } }
        return TakeDiagnosticRecord(date: date, takeID: takeID, action: action?.rawValue, mode: mode.rawValue, external: external,
            bundleID: bundleID, pressDelayMs: ms(pressDelay), captureMs: ms(capture), startingMs: ms(starting),
            microphoneMs: ms(microphone), taskStartedMs: ms(taskStarted), releaseDelayMs: ms(releaseDelay), heldMs: ms(held),
            releaseEffect: releaseEffect, locked: locked, finishWhenReady: finishWhenReady,
            audioSeconds: audioSeconds.map { ($0 * 100).rounded() / 100 }, outcome: outcome,
            failure: failure.map(ModelUsageFailure.message))
    }
}

/// Device-local take timing diagnostics, off unless the hidden `TakeDiagnostics`
/// user default is true:
///
///     defaults write com.voicedraft.mac TakeDiagnostics -bool true
///
/// Appends to `<data directory>/Diagnostics/takes.jsonl` with the usage log's
/// rules (folder 0700, file 0600, silent failures, never synced or shown).
final class TakeDiagnosticsLog: @unchecked Sendable {
    static let defaultsKey = "TakeDiagnostics"
    let fileURL: URL
    let isEnabled: () -> Bool
    private let queue = DispatchQueue(label: "com.voicedraft.take-diagnostics", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(directory: URL, isEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: TakeDiagnosticsLog.defaultsKey) }) {
        fileURL = directory.appendingPathComponent("takes.jsonl")
        self.isEnabled = isEnabled
    }
    convenience init?(store: LocalStore?) {
        guard let store else { return nil }
        self.init(directory: store.diagnosticsDirectory)
    }

    /// Enqueues the append when enabled; failures are silent and never interrupt a take.
    func record(_ record: TakeDiagnosticRecord) {
        guard isEnabled() else { return }
        let url = fileURL
        queue.async { [encoder] in try? JSONLines.append(record, to: url, encoder: encoder) }
    }

    /// Waits for queued appends (tests).
    func flush() { queue.sync {} }
}

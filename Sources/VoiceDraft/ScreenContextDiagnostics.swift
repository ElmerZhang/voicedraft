import Foundation
import VoiceDraftCore

/// One line of the opt-in on-screen context diagnostics file. It holds counts,
/// timings and the screen-derived terms offered to models, never the excerpt or
/// any other screen text.
struct ScreenContextDiagnosticRecord: Codable, Equatable {
    enum Kind: String, Codable { case take, extraction }
    var v = 1
    var kind: Kind
    /// Take start, or extraction time.
    var date: Date
    var takeID: UUID?
    var bundleID: String?
    /// "accessibility" and/or "ocr" (cached snapshots included).
    var sources: [String]
    var nodesVisited: Int
    var charactersCollected: Int
    var axElapsedMs: Int?
    var ocrElapsedMs: Int?
    var truncated: Bool
    /// Live adapters only: whether the 250 ms gate had terms to send.
    var gateHadTerms: Bool?
    /// Every term offered to speech or writing for a take; extraction candidates for an extraction.
    var termsOffered: [String]
    /// Characters of the writing excerpt; the excerpt itself is never written.
    var excerptLength: Int
    var asrTermsSent: Int
    var writingTerms: [String]
}

/// Device-local diagnostics for on-screen context, off unless the hidden
/// `ScreenContextDiagnostics` user default is true:
///
///     defaults write com.voicedraft.mac ScreenContextDiagnostics -bool true
///
/// Appends to `<data directory>/Diagnostics/screen-context.jsonl` with the usage
/// log's rules (folder 0700, file 0600, silent failures, never synced or shown).
final class ScreenContextDiagnosticsLog: @unchecked Sendable {
    static let defaultsKey = "ScreenContextDiagnostics"
    let fileURL: URL
    let isEnabled: () -> Bool
    private let queue = DispatchQueue(label: "com.voicedraft.screen-context-diagnostics", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(directory: URL, isEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: ScreenContextDiagnosticsLog.defaultsKey) }) {
        fileURL = directory.appendingPathComponent("screen-context.jsonl")
        self.isEnabled = isEnabled
    }
    convenience init?(store: LocalStore?) {
        guard let store else { return nil }
        self.init(directory: store.diagnosticsDirectory)
    }

    /// Enqueues the append when enabled; failures are silent and never interrupt a take.
    func record(_ record: ScreenContextDiagnosticRecord) {
        guard isEnabled() else { return }
        let url = fileURL
        queue.async { [encoder] in try? JSONLines.append(record, to: url, encoder: encoder) }
    }

    /// Waits for queued appends (tests).
    func flush() { queue.sync {} }
}

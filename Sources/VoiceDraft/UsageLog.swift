import Foundation
import VoiceDraftCore

/// Device-local, append-only model usage log: one JSON line per inference call in
/// `<data directory>/Usage/usage-YYYY-MM.jsonl`. Counts and timings only, never text.
/// Independent of History, its retention and "Clear history"; never synced or shown.
final class UsageLog: @unchecked Sendable {
    let directory: URL?
    private let queue = DispatchQueue(label: "com.voicedraft.usage-log", qos: .utility)
    private let calendar: Calendar
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// A nil directory (preview mode, or no local store) writes nothing.
    init(directory: URL?, timeZone: TimeZone = .current) {
        self.directory = directory
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        self.calendar = calendar
    }
    convenience init(store: LocalStore?) { self.init(directory: store?.usageDirectory) }

    func fileURL(for date: Date) -> URL? {
        guard let directory else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return directory.appendingPathComponent(String(format: "usage-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0))
    }

    /// Enqueues the append; failures are silent and never interrupt a take.
    func record(_ record: ModelUsageRecord) {
        guard let url = fileURL(for: record.date) else { return }
        queue.async { [encoder] in try? Self.append(record, to: url, encoder: encoder) }
    }

    /// Waits for queued appends (tests).
    func flush() { queue.sync {} }

    private static func append(_ record: ModelUsageRecord, to url: URL, encoder: JSONEncoder) throws {
        var line = try encoder.encode(record); line.append(0x0A)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

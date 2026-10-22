import Foundation
import VoiceDraftCore

/// Device-local, append-only model usage log, same shape as the Mac: one `ModelUsageRecord` JSON line per
/// inference call in `Usage/usage-YYYY-MM.jsonl`. Counts and timings only, never text. Never synced.
final class IOSUsageLog: @unchecked Sendable {
    let directory: URL?
    private let queue = DispatchQueue(label: "com.voicedraft.ios.usage-log", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// A nil directory writes nothing.
    init(directory: URL?) { self.directory = directory }

    func fileURL(for date: Date) -> URL? {
        guard let directory else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return directory.appendingPathComponent(String(format: "usage-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0))
    }

    /// Failures are silent and never interrupt a take.
    func record(_ record: ModelUsageRecord) {
        guard let url = fileURL(for: record.date) else { return }
        queue.async { [encoder] in
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.protectionKey: FileProtectionType.complete])
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }

    /// Waits for queued appends (tests).
    func flush() { queue.sync {} }
}

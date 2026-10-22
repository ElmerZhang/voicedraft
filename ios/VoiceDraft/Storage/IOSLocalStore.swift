import Foundation
import VoiceDraftCore

/// Plain JSON files in Application Support, mirroring the Mac `LocalStore`.
///
/// Files: `settings.json` (`SharedSettings`, which also carries the vocabulary so a synced snapshot
/// round-trips unchanged), `device.json` (`IOSDeviceSettings`), `history.json` (newest first, capped)
/// and `settings-before-sync.json` (recovery copy written before a download replaces settings).
/// Every file is written atomically with complete file protection.
final class IOSLocalStore {
    static let historyLimit = 500

    let directory: URL

    /// `directory` defaults to `Application Support/VoiceDraft`; tests pass a temporary directory.
    init(directory: URL? = nil) throws {
        let fileManager = FileManager.default
        self.directory = try directory ?? fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VoiceDraft", isDirectory: true)
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.complete])
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".json", isDirectory: false) }

    func read<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let url = url(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url(name), options: [.atomic, .completeFileProtection])
    }

    // MARK: Typed files

    func loadSettings() throws -> SharedSettings {
        let settings = try read("settings", fallback: SharedSettings())
        try settings.validate()
        return settings
    }

    func saveSettings(_ settings: SharedSettings) throws { try write(settings, name: "settings") }

    func loadDevice() throws -> IOSDeviceSettings { try read("device", fallback: IOSDeviceSettings()) }

    func saveDevice(_ device: IOSDeviceSettings) throws { try write(device, name: "device") }

    func loadHistory() throws -> [HistoryEntry] { try read("history", fallback: [HistoryEntry]()) }

    /// Keeps the newest `historyLimit` entries and returns what was written.
    @discardableResult
    func saveHistory(_ history: [HistoryEntry]) throws -> [HistoryEntry] {
        let capped = Array(history.sorted { $0.date > $1.date }.prefix(Self.historyLimit))
        try write(capped, name: "history")
        return capped
    }
}

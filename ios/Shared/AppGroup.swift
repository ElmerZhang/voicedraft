import Foundation

/// Identifiers shared by the VoiceDraft app and its keyboard extension.
enum AppGroup {
    static let identifier = "group.com.voicedraft"
}

/// The most recent transcription result handed from the app to the keyboard.
///
/// `id` and `mode` were added after the first release. Files written without them still decode:
/// a missing `id` gets a fresh UUID and a missing `mode` becomes an empty string.
struct SharedResult: Codable, Equatable {
    var id: UUID
    var text: String
    /// The writing mode that produced the text, for example `polish`, `translate` or `ask`.
    var mode: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, mode: String = "", createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.mode = mode
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, mode, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Stores the latest result as `latest-result.json` in the app-group container.
struct SharedResultStore {
    static let fileName = "latest-result.json"

    private let fileURL: URL?

    init(fileManager: FileManager = .default) {
        fileURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Creates a store backed by an explicit file, for previews and tests.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ result: SharedResult) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func write(text: String, mode: String = "", createdAt: Date = Date()) throws {
        try write(SharedResult(text: text, mode: mode, createdAt: createdAt))
    }

    func read() -> SharedResult? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedResult.self, from: data)
    }
}

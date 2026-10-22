import Foundation

/// Identifiers shared by the VoiceDraft app and its keyboard extension.
enum AppGroup {
    static let identifier = "group.com.voicedraft"
}

/// The most recent transcription result handed from the app to the keyboard.
struct SharedResult: Codable, Equatable {
    var text: String
    var createdAt: Date
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

    func write(text: String, createdAt: Date = Date()) throws {
        try write(SharedResult(text: text, createdAt: createdAt))
    }

    func read() -> SharedResult? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedResult.self, from: data)
    }
}

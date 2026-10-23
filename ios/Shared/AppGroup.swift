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

/// Written by the keyboard extension each time it appears with Full Access, so the app can tell the
/// keyboard has been enabled. iOS offers no public API for that, and the app never guesses from
/// `UITextInputMode`. A marker can go stale: it stays after the keyboard is removed or Full Access is
/// turned off, because the extension can no longer reach the container then.
struct KeyboardPresence: Codable, Equatable {
    var seenAt: Date
    var fullAccess: Bool
    /// The extension's `CFBundleShortVersionString`.
    var version: String
}

/// Stores the keyboard presence marker as `keyboard-presence.json` in the app-group container.
struct KeyboardPresenceStore {
    static let fileName = "keyboard-presence.json"

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

    func write(_ presence: KeyboardPresence) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(presence)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read() -> KeyboardPresence? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeyboardPresence.self, from: data)
    }
}

/// A dictation the keyboard asked the container app to record, written just before the keyboard opens
/// `voicedraft://record`. When the keyboard reappears it uses the marker to show "recording in VoiceDraft",
/// to offer Finish, and to insert the result whose `SharedResult.id` equals `id`.
struct PendingTake: Codable, Equatable {
    var id: UUID
    var startedAt: Date
    /// Always `keyboard` today; kept so other sources can share the file later.
    var source: String
    /// Validated against the keyboard host PID; used only for this take's immediate return trip.
    var hostBundleIdentifier: String?

    /// A marker older than this is abandoned: the take cap is ten minutes.
    static let maxAge: TimeInterval = 10 * 60

    init(id: UUID = UUID(), startedAt: Date = Date(), source: String = "keyboard", hostBundleIdentifier: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.source = source
        self.hostBundleIdentifier = hostBundleIdentifier
    }

    func permitsAutomaticReturn(for takeID: UUID, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(startedAt)
        return id == takeID && source == "keyboard" && age >= -2 && age <= 15
    }

    func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) > Self.maxAge
    }
}

/// Stores the pending keyboard take as `pending-take.json` in the app-group container.
struct PendingTakeStore {
    static let fileName = "pending-take.json"

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

    func write(_ take: PendingTake) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(take).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read() -> PendingTake? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingTake.self, from: data)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// What the keyboard does with a pending marker when it appears or polls. Pure, so it is unit-tested.
enum KeyboardResumeDecision: Equatable {
    /// No marker: normal idle keyboard.
    case none
    /// The marker is older than `PendingTake.maxAge`: delete it.
    case clear
    /// The app is not recording or processing this take (it never started, crashed or was killed): delete the
    /// marker and say the last take did not start.
    case notStarted
    /// The app is still recording or processing this take: show "recording in VoiceDraft" with Finish.
    case resume(PendingTake)
    /// The app delivered this take's result: insert it (an empty text means the take failed) and delete the marker.
    case insert(SharedResult)

    static func decide(pending: PendingTake?, latest: SharedResult?, status: AppStatus?,
                       now: Date = Date()) -> KeyboardResumeDecision {
        guard let pending else { return .none }
        if let latest, latest.id == pending.id { return .insert(latest) }
        if pending.isStale(at: now) { return .clear }
        guard let status, status.isWorking(onTake: pending.id, at: now) else { return .notStarted }
        return .resume(pending)
    }
}

/// `voicedraft://record?take=<uuid>&source=keyboard`: the keyboard asks the container app to record.
enum KeyboardRecordLink {
    static let scheme = "voicedraft"
    static let host = "record"

    static func url(for take: PendingTake) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "take", value: take.id.uuidString),
                                 URLQueryItem(name: "source", value: take.source)]
        return components.url
    }

    /// The take id, or nil when the URL is not a record link.
    static func takeID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "source" })?.value == "keyboard",
              let value = items.first(where: { $0.name == "take" })?.value else { return nil }
        return UUID(uuidString: value)
    }
}

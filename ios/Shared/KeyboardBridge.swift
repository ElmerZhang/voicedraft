import Foundation

/// Darwin notifications that connect the keyboard extension to the container app.
///
/// Darwin notifications carry no payload and may be coalesced, so every notification only means
/// "look at the app group again". The data itself lives in `app-status.json` and `latest-result.json`.
enum KeyboardBridge {
    /// Keyboard to app: start a take in the running listening session.
    static let takeStart = "com.voicedraft.ios.take.start"
    /// Keyboard to app: stop the current take and process it.
    static let takeStop = "com.voicedraft.ios.take.stop"
    /// App to keyboard: `latest-result.json` was rewritten.
    static let resultUpdated = "com.voicedraft.ios.result.updated"
    /// App to keyboard: `app-status.json` was rewritten.
    static let statusUpdated = "com.voicedraft.ios.status.updated"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Calls `handler` on the main queue whenever `name` is posted, until the returned token is released
    /// or `cancel()` is called.
    static func observe(_ name: String, handler: @escaping () -> Void) -> Observation {
        Observation(name: name, handler: handler)
    }

    final class Observation {
        let name: String
        private let handler: () -> Void
        private var isActive = false

        fileprivate init(name: String, handler: @escaping () -> Void) {
            self.name = name
            self.handler = handler
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let observation = Unmanaged<Observation>.fromOpaque(observer).takeUnretainedValue()
                    observation.fire()
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
            isActive = true
        }

        private func fire() {
            if Thread.isMainThread {
                handler()
            } else {
                DispatchQueue.main.async { [handler] in handler() }
            }
        }

        func cancel() {
            guard isActive else { return }
            isActive = false
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name as CFString),
                nil
            )
        }

        deinit { cancel() }
    }
}

/// What the container app is doing, as seen by the keyboard.
struct AppStatus: Codable, Equatable {
    enum State: String, Codable {
        case idle, listening, recording, processing
    }

    var state: State
    /// The app refreshes this while alive. A status past its expiry means the app was suspended or killed.
    var expiresAt: Date
    var updatedAt: Date

    init(state: State, expiresAt: Date, updatedAt: Date = Date()) {
        self.state = state
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
    }

    /// The keyboard may send take notifications only when this is true.
    func isAvailable(at now: Date = Date()) -> Bool {
        state != .idle && expiresAt > now
    }
}

/// Stores the app status as `app-status.json` in the app-group container.
struct AppStatusStore {
    static let fileName = "app-status.json"

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

    func write(_ status: AppStatus) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read() -> AppStatus? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppStatus.self, from: data)
    }

    /// True when the app is alive and listening, recording or processing.
    func isAppAvailable(at now: Date = Date()) -> Bool {
        read()?.isAvailable(at: now) ?? false
    }
}

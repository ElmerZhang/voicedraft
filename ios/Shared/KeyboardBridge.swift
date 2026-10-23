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
    static let appCheckRequested = "com.voicedraft.ios.app-check.requested"
    static let appCheckReplied = "com.voicedraft.ios.app-check.replied"

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

/// A persisted standby deadline is not proof of process liveness. Every check uses a fresh challenge.
struct KeyboardAppCheckRequest: Codable, Equatable {
    var id = UUID()
    var createdAt = Date().timeIntervalSince1970

    func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - createdAt
        return age >= 0 && age <= 3
    }
}

struct KeyboardAppCheckReply: Codable, Equatable {
    enum State: String, Codable { case ready, unavailable, busy }
    let requestID: UUID
    let state: State
    let takeID: UUID?
}

struct KeyboardAppCheckStore {
    private let directory: URL?
    init(fileManager: FileManager = .default) {
        directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
    }
    init(directory: URL) { self.directory = directory }

    func writeRequest(_ request: KeyboardAppCheckRequest) throws { try write(request, name: "app-check-request.json") }
    func readRequest() -> KeyboardAppCheckRequest? { read(name: "app-check-request.json") }
    func writeReply(_ reply: KeyboardAppCheckReply) throws { try write(reply, name: "app-check-reply.json") }
    func readReply() -> KeyboardAppCheckReply? { read(name: "app-check-reply.json") }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name),
                                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<T: Decodable>(name: String) -> T? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Main-thread request/reply check with a bounded deadline. Old replies and cancelled checks cannot activate a take.
@MainActor
final class KeyboardAppCheck {
    nonisolated static let timeout: TimeInterval = 0.5
    private let store: KeyboardAppCheckStore
    private let post: (String) -> Void
    private var requestID: UUID?
    private var completion: ((KeyboardAppCheckReply?) -> Void)?
    private var observation: KeyboardBridge.Observation?
    private var timer: Timer?
    var isChecking: Bool { requestID != nil }

    init(store: KeyboardAppCheckStore = KeyboardAppCheckStore(), post: @escaping (String) -> Void = KeyboardBridge.post) {
        self.store = store
        self.post = post
    }

    func start(timeout: TimeInterval = KeyboardAppCheck.timeout, completion: @escaping (KeyboardAppCheckReply?) -> Void) {
        cancel()
        let request = KeyboardAppCheckRequest()
        requestID = request.id
        self.completion = completion
        observation = KeyboardBridge.observe(KeyboardBridge.appCheckReplied) { [weak self] in
            MainActor.assumeIsolated { self?.receiveReply() }
        }
        do { try store.writeRequest(request) } catch { finish(nil); return }
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        post(KeyboardBridge.appCheckRequested)
    }

    func receiveReply() {
        guard let requestID, let reply = store.readReply(), reply.requestID == requestID else { return }
        finish(reply)
    }

    func cancel() {
        requestID = nil
        completion = nil
        timer?.invalidate()
        timer = nil
        observation = nil
    }

    private func finish(_ reply: KeyboardAppCheckReply?) {
        let callback = completion
        cancel()
        callback?(reply)
    }

    deinit { timer?.invalidate() }
}

/// What the container app is doing, as seen by the keyboard.
struct AppStatus: Codable, Equatable {
    enum State: String, Codable {
        case idle, listening, recording, processing
    }

    var state: State
    /// Persisted standby deadline. Force-quit leaves it behind, so it is not proof of process liveness.
    var expiresAt: Date
    var updatedAt: Date
    /// The take being recorded or processed, nil when idle. Added after the first release; older files decode as nil.
    var takeID: UUID?
    /// Why standby ended on its own, for the keyboard's status line. Nil when there is nothing to report; older
    /// files decode as nil.
    var lastError: String?

    /// A status older than this does not prove the app is still working on a take. The app rewrites the status at
    /// least every 30 s while a take records.
    static let liveTakeWindow: TimeInterval = 2 * 60

    init(state: State, expiresAt: Date, updatedAt: Date = Date(), takeID: UUID? = nil, lastError: String? = nil) {
        self.state = state
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
        self.takeID = takeID
        self.lastError = lastError
    }

    /// Standby eligibility only. Starting a take also requires a reply to a fresh app check.
    func isAvailable(at now: Date = Date()) -> Bool {
        state != .idle && expiresAt > now
    }

    /// True when the app is recording or processing the take `id` (or a take it did not name) and wrote this status
    /// within `liveTakeWindow`. The keyboard resumes or finishes a take it opened the app for only then.
    func isWorking(onTake id: UUID, at now: Date = Date()) -> Bool {
        (state == .recording || state == .processing)
            && now.timeIntervalSince(updatedAt) <= Self.liveTakeWindow
            && (takeID == nil || takeID == id)
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

    /// Persisted eligibility; callers must not interpret this as a process-liveness check.
    func isAppAvailable(at now: Date = Date()) -> Bool {
        read()?.isAvailable(at: now) ?? false
    }
}

/// Only the latest measured amplitude crosses the process boundary, never PCM or a recording history.
/// Numeric seconds preserve the subsecond freshness needed by a live meter.
struct RecordingMeterSample: Codable, Equatable {
    let takeID: UUID
    let level: Double
    let sampledAt: TimeInterval
    static let freshness: TimeInterval = 0.4

    init(takeID: UUID, level: Double, sampledAt: Date) {
        self.takeID = takeID
        self.level = level
        self.sampledAt = sampledAt.timeIntervalSince1970
    }

    func usableLevel(for expectedTakeID: UUID?, after start: Date, at now: Date = Date()) -> Double? {
        let age = now.timeIntervalSince1970 - sampledAt
        guard expectedTakeID == nil || expectedTakeID == takeID,
              sampledAt >= start.timeIntervalSince1970,
              age >= 0, age <= Self.freshness, level.isFinite else { return nil }
        return min(1, max(0, level))
    }
}

/// Replaced at most 10 times/second during keyboard recording; removed on stop/cancel/failure.
/// Separate from app-status.json so meter updates cannot extend a take's status lease.
struct RecordingMeterStore {
    static let fileName = "recording-meter.json"
    private let fileURL: URL?

    init(fileManager: FileManager = .default) {
        fileURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    init(fileURL: URL) { self.fileURL = fileURL }

    func write(_ sample: RecordingMeterSample) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(sample).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read() -> RecordingMeterSample? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RecordingMeterSample.self, from: data)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

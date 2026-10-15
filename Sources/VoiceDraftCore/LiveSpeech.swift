import Foundation

/// 100 ms, 16 kHz mono signed little-endian PCM frames. At most five seconds queue up.
/// Backpressure is an explicit failure: never silently omit part of the user's speech.
public final class LiveAudioFeed: @unchecked Sendable {
    public let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var pending = Data()
    private var ended = false
    private var archive = Data()
    private let retainAudio: Bool
    public var archivedWAV: Data? { lock.withLock { retainAudio && !archive.isEmpty ? WaveAudio.encode(archive) : nil } }
    public init(bufferedFrames: Int = 50, retainAudio: Bool = false) {
        self.retainAudio = retainAudio
        var producer: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(max(1, bufferedFrames))) { producer = $0 }
        continuation = producer
    }
    public func append(_ pcm: Data) throws {
        try lock.withLock {
            guard !ended else { throw CancellationError() }
            guard pcm.count <= 64_000, pcm.count.isMultiple(of: 2) else {
                throw VoiceDraftError.message("The recording format is unsupported. Choose another audio input device.")
            }
            if retainAudio {
                guard archive.count + pcm.count <= 19_300_000 else { throw FeatureError("Recording exceeded 10 minutes.") }
                archive.append(pcm)
            }
            pending.append(pcm)
            while pending.count >= 3200 {
                let frame = Data(pending.prefix(3200)); pending.removeFirst(3200)
                try emit(frame)
            }
        }
    }
    public func finish() throws {
        try lock.withLock {
            guard !ended else { throw CancellationError() }
            if !pending.isEmpty { try emit(pending); pending.removeAll() }
            ended = true; continuation.finish()
        }
    }
    public func cancel(_ error: Error = CancellationError()) {
        lock.withLock {
            guard !ended else { return }
            ended = true; pending.removeAll(); continuation.finish(throwing: error)
        }
    }
    private func emit(_ frame: Data) throws {
        switch continuation.yield(frame) {
        case .enqueued: return
        case .dropped:
            let error = VoiceDraftError.message("The connection is too slow for live transcription. Please try again.")
            ended = true; pending.removeAll(); continuation.finish(throwing: error); throw error
        case .terminated: ended = true; pending.removeAll(); throw CancellationError()
        @unknown default: throw CancellationError()
        }
    }
    deinit { continuation.finish() }
}

extension SpeechClient {
    public static func transcribeLive(profile: ModelProfile, key: String, audio: AsyncThrowingStream<Data, Error>,
                                      vocabulary: AppVocabulary,
                                      screenTerms: @escaping @Sendable () async -> [String] = { [] },
                                      onReady: @escaping @Sendable () async throws -> Void,
                                      onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        if profile.adapter == .doubao {
            return try await DoubaoSpeech.live(profile: profile, key: key, audio: audio, vocabulary: vocabulary,
                                               screenTerms: screenTerms, onReady: onReady, onUpdate: onUpdate)
        }
        let request = try MessageASRRequests.connection(profile: profile, key: key)
        let taskID = UUID().uuidString
        // Configuration errors still throw before any socket opens.
        _ = try MessageASRRequests.start(profile: profile, vocabulary: vocabulary, taskID: taskID, live: true)
        // The socket handshake starts now; the terms provider (gated by the app)
        // overlaps it and is awaited immediately before the start frame is sent.
        let socket = NativeASRWebSocket(request: request)
        return try await MessageASRSession.transcribeLive(socket: socket, start: {
            let terms = await screenTerms()
            return try MessageASRRequests.start(profile: profile, vocabulary: vocabulary, taskID: taskID, live: true, screenTerms: terms)
        }, audio: audio, taskID: taskID, onReady: onReady, onUpdate: onUpdate)
    }
}

private final class LiveUploadFence: @unchecked Sendable {
    private let lock = NSLock()
    private var finishing = false
    func beginFinish() { lock.withLock { finishing = true } }
    var hasFinishedAudio: Bool { lock.withLock { finishing } }
}

extension MessageASRSession {
    static func transcribeLive(socket: any ASRWebSocket, start: String, audio: AsyncThrowingStream<Data, Error>, taskID: String,
                               startTimeout: UInt64 = 15_000_000_000, finishTimeout: UInt64 = 30_000_000_000,
                               totalTimeout: UInt64 = 660_000_000_000,
                               onReady: @escaping @Sendable () async throws -> Void = {},
                               onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await transcribeLive(socket: socket, start: { start }, audio: audio, taskID: taskID, startTimeout: startTimeout,
                                 finishTimeout: finishTimeout, totalTimeout: totalTimeout, onReady: onReady, onUpdate: onUpdate)
    }

    /// `start` builds the run-task frame; it is awaited immediately before it is sent,
    /// inside the start deadline, so `onReady` still follows `task-started`.
    static func transcribeLive(socket: any ASRWebSocket, start: @escaping @Sendable () async throws -> String,
                               audio: AsyncThrowingStream<Data, Error>, taskID: String,
                               startTimeout: UInt64 = 15_000_000_000, finishTimeout: UInt64 = 30_000_000_000,
                               totalTimeout: UInt64 = 660_000_000_000,
                               onReady: @escaping @Sendable () async throws -> Void = {},
                               onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            defer { socket.cancel() }
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await liveExchange(socket: socket, start: start, audio: audio, taskID: taskID,
                        startTimeout: startTimeout, finishTimeout: finishTimeout, onReady: onReady, onUpdate: onUpdate)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: totalTimeout)
                    throw VoiceDraftError.message("Speech recognition timed out. Try a shorter recording.")
                }
                defer { group.cancelAll(); socket.cancel() }
                return try await group.next()!
            }
        } onCancel: { socket.cancel() }
    }

    private static func liveExchange(socket: any ASRWebSocket, start: @escaping @Sendable () async throws -> String, audio: AsyncThrowingStream<Data, Error>, taskID: String,
                                     startTimeout: UInt64, finishTimeout: UInt64,
                                     onReady: @escaping @Sendable () async throws -> Void,
                                     onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        var results = MessageASRResults(taskID: taskID)
        let acknowledgement = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try Task.checkCancellation()
                let frame = try await start()
                try Task.checkCancellation()
                try await socket.sendText(frame)
                return try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: startTimeout)
                throw VoiceDraftError.message("Speech recognition timed out. Try a shorter recording.")
            }
            defer { group.cancelAll() }
            do { return try await group.next()! }
            catch { socket.cancel(); throw error }
        }
        try results.accept(acknowledgement)
        guard results.started else { throw VoiceDraftError.message("The speech service did not start the task.") }
        try Task.checkCancellation()
        try await onReady()
        try Task.checkCancellation()
        let fence = LiveUploadFence()
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await frame in audio {
                    try Task.checkCancellation()
                    guard !frame.isEmpty, frame.count <= 3200, frame.count.isMultiple(of: 2) else {
                        throw VoiceDraftError.message("The recording format is unsupported. Choose another audio input device.")
                    }
                    try await socket.sendAudio(frame)
                }
                try Task.checkCancellation()
                fence.beginFinish()
                try await socket.sendText(MessageASRRequests.finish(taskID: taskID))
                return nil
            }
            group.addTask {
                var received = results
                var previous = ""
                while !received.finished {
                    try received.accept(await socket.receive())
                    try Task.checkCancellation()
                    if received.finished && !fence.hasFinishedAudio {
                        throw VoiceDraftError.message("The speech connection ended before the final result.")
                    }
                    if previous != received.preview {
                        previous = received.preview
                        await onUpdate(previous)
                    }
                }
                return try received.transcript()
            }
            defer { group.cancelAll(); socket.cancel() }
            var uploaded = false
            var transcript: String?
            while let next = try await group.next() {
                if let next { transcript = next }
                else {
                    uploaded = true
                    group.addTask {
                        try await Task.sleep(nanoseconds: finishTimeout)
                        throw VoiceDraftError.message("Speech recognition timed out. Try a shorter recording.")
                    }
                }
                if uploaded, let transcript { return transcript }
            }
            throw VoiceDraftError.message("The speech connection closed without a final result.")
        }
    }
}

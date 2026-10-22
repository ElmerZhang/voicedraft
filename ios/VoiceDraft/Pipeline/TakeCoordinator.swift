import Foundation
import VoiceDraftCore

/// Everything one take needs, resolved and validated before the microphone opens, mirroring the checks in
/// the Mac `AppState.toggle`.
struct TakeConfiguration {
    let id: UUID
    let mode: WritingMode
    /// The selected style is already applied as `stylePrompt` (`SharedSettings.resolved(for: nil)`).
    let settings: SharedSettings
    let speech: ModelProfile
    let writing: ModelProfile
    let speechKey: String
    let writingKey: String
    /// Passed to the writing prompt. Keyboard takes cannot know their host app, so they send none.
    let application: String

    static func make(settings: SharedSettings, mode: WritingMode, credentials: CredentialStore,
                     application: String, id: UUID = UUID()) throws -> TakeConfiguration {
        guard IOSDeviceSettings.modes.contains(mode) else {
            throw VoiceDraftError.message("This mode is not available on iPhone.")
        }
        guard let speech = settings.speech, let writing = settings.writing else {
            throw VoiceDraftError.message("Choose your speech and writing models.")
        }
        try speech.validateForInference()
        try settings.vocabulary.validate()
        try writing.validateForInference()
        let speechKey = try credentials.read(CredentialAccount.profile(speech.id))
        let writingKey = try credentials.read(CredentialAccount.profile(writing.id))
        guard !speechKey.isEmpty else { throw FeatureError("Add a credential for your speech model in Models first.") }
        guard !writingKey.isEmpty else { throw VoiceDraftError.message("Add an API key for the writing model first.") }
        var resolved = settings.resolved(for: nil)
        resolved.recentInputContext = ""
        return TakeConfiguration(id: id, mode: mode, settings: resolved, speech: speech, writing: writing,
                                 speechKey: speechKey, writingKey: writingKey, application: application)
    }
}

/// Runs one take's recognition and writing through the shared Core clients, the way the Mac `AppState`
/// does: WebSocket adapters stream through a `LiveAudioFeed` while recording, HTTP adapters receive one
/// WAV after the take, then the writing model rewrites the transcript for the selected mode. Every call is
/// timed and recorded as a `ModelUsageRecord`.
final class TakeCoordinator: @unchecked Sendable {
    let configuration: TakeConfiguration
    /// Non-nil for WebSocket speech adapters.
    let feed: LiveAudioFeed?
    private let usageLog: IOSUsageLog
    private var liveTask: Task<String, Error>?

    init(configuration: TakeConfiguration, usageLog: IOSUsageLog) {
        self.configuration = configuration
        self.usageLog = usageLog
        feed = configuration.speech.adapter.isWebSocket ? LiveAudioFeed() : nil
    }

    /// Opens the live recognition session in parallel with the microphone. Audio captured before the
    /// provider is ready queues in the feed. `onFailure` fires once if the session fails while recording.
    func startLiveSession(audioSeconds: @escaping @Sendable () -> Double,
                          onUpdate: @escaping @Sendable (String) async -> Void,
                          onFailure: @escaping @Sendable (Error) async -> Void) {
        guard let feed, liveTask == nil else { return }
        let configuration = configuration
        liveTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                return try await self.metered(.speech, source: .dictationLiveSpeech, profile: configuration.speech,
                                              streamed: true, audioSeconds: audioSeconds) { usage in
                    try await SpeechClient.transcribeLive(profile: configuration.speech, key: configuration.speechKey,
                                                          audio: feed.stream, vocabulary: configuration.settings.vocabulary,
                                                          onReady: {}, onUpdate: onUpdate, usage: usage)
                }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { await onFailure(error) }
                throw error
            }
        }
    }

    /// The raw transcript: the live session's final text, or one HTTP request with the take's WAV.
    func transcribe(pcm: Data, duration: Double) async throws -> String {
        if let liveTask { return try await liveTask.value }
        let configuration = configuration
        let wav = WaveAudio.encode(pcm)
        return try await metered(.speech, source: .dictationSpeech, profile: configuration.speech,
                                 audioSeconds: { duration }) { usage in
            try await SpeechClient.transcribe(profile: configuration.speech, key: configuration.speechKey, wav: wav,
                                              vocabulary: configuration.settings.vocabulary, usage: usage)
        }
    }

    /// Rewrites `raw` for the take's mode with the shared prompts.
    func write(_ raw: String, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        let configuration = configuration
        let request = try QwenRequests.writing(profile: configuration.writing, key: configuration.writingKey, text: raw,
                                               mode: configuration.mode, settings: configuration.settings,
                                               application: configuration.application)
        var output = try await metered(.writing, source: .dictationWriting, profile: configuration.writing,
                                       mode: configuration.mode, streamed: true) { usage in
            try await WritingClient.complete(request, profile: configuration.writing, key: configuration.writingKey,
                                             onUpdate: onUpdate, usage: usage)
        }
        if configuration.mode == .polish { output = SingleWordOutput.finalize(output, transcript: raw) }
        return output
    }

    func cancel() {
        liveTask?.cancel()
        feed?.cancel()
    }

    /// Times one inference call and appends its usage record, success or failure, like the Mac `metered`.
    private func metered<T>(_ kind: ModelUsageKind, source: ModelUsageSource, profile: ModelProfile,
                            mode: WritingMode? = nil, streamed: Bool = false,
                            audioSeconds: (@Sendable () -> Double)? = nil,
                            _ call: (@escaping @Sendable (ProviderUsage) -> Void) async throws -> T) async throws -> T {
        let collector = ProviderUsageCollector(), date = Date(), start = ContinuousClock.now
        let result: Result<T, Error>
        do { result = .success(try await call(collector.sink)) } catch { result = .failure(error) }
        let elapsed = (ContinuousClock.now - start).components
        let latency = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        var failure: Error?
        if case .failure(let error) = result { failure = error }
        usageLog.record(ModelUsageRecord(date: date, kind: kind, source: source, profile: profile, mode: mode,
                                         streamed: streamed, audioSeconds: audioSeconds?(), latencyMs: latency,
                                         failure: failure, takeID: configuration.id, usage: collector.usage))
        return try result.get()
    }
}

import Foundation
import UIKit
import VoiceDraftCore

/// Who started a take. Keyboard takes always deliver a result file, even an empty one on failure, so the
/// keyboard stops waiting.
enum TakeSource: Equatable { case app, keyboard }

/// The container app's state: settings, history, the take pipeline, the listening session and sync.
///
/// Every take transition goes through `TakeMachine`. Every take or listening change rewrites
/// `app-status.json` and posts `status.updated`; every finished keyboard take rewrites `latest-result.json`
/// and posts `result.updated`.
@MainActor
final class AppModel: ObservableObject {
    /// Same ten-minute cap as the Mac. Core's speech clients split long WAVs to fit provider limits.
    static let maxTakeSeconds: Double = 600
    /// Refresh interval for the listening status lease.
    static let statusRefreshInterval: TimeInterval = 60

    struct Dependencies {
        var store: IOSLocalStore?
        var credentials: CredentialStore
        var statusStore: AppStatusStore
        var resultStore: SharedResultStore
        var audio: AudioCapturing
        var usageLog: IOSUsageLog
        /// Posts a Darwin notification.
        var post: (String) -> Void
        /// Registers the keyboard's `take.start` and `take.stop` observers.
        var observeKeyboard: Bool

        static func live() -> Dependencies {
            let store = try? IOSLocalStore()
            return Dependencies(store: store, credentials: IOSKeychainStore(), statusStore: AppStatusStore(),
                                resultStore: SharedResultStore(), audio: IOSAudioCapture(),
                                usageLog: IOSUsageLog(directory: store?.directory.appendingPathComponent("Usage", isDirectory: true)),
                                post: KeyboardBridge.post, observeKeyboard: true)
        }
    }

    // MARK: Published state

    @Published private(set) var settings = SharedSettings()
    @Published private(set) var device = IOSDeviceSettings()
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var takeState: TakeState = .idle
    @Published private(set) var takeSource: TakeSource?
    @Published private(set) var listening = false
    @Published private(set) var listeningEndsAt: Date?
    @Published private(set) var transcript = ""
    /// Streaming writing output while processing, then the final result.
    @Published private(set) var resultText = ""
    @Published private(set) var lastResult: SharedResult?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published var errorMessage: LocalizedMessage = ""
    @Published var notice: LocalizedMessage = ""
    @Published private(set) var syncStatus: LocalizedMessage = "Not connected"
    @Published private(set) var syncing = false
    @Published private(set) var language: AppLanguage = L10n.language
    @Published var showingOnboarding = false

    var mode: WritingMode { device.mode }
    var busy: Bool { takeState != .idle }

    // MARK: Private state

    let dependencies: Dependencies
    private var machine = TakeMachine()
    private var coordinator: TakeCoordinator?
    private let router = PCMRouter()
    private var takeTask: Task<Void, Never>?
    private var tick: Timer?
    private var statusTimer: Timer?
    private var idleTimer: Timer?
    private var observations: [KeyboardBridge.Observation] = []

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
        let router = router
        dependencies.audio.onPCM = { router.accept($0) }
        dependencies.audio.onInterruption = { [weak self] error in
            Task { @MainActor in self?.audioInterrupted(error) }
        }
        load()
        if dependencies.observeKeyboard {
            observations = [
                KeyboardBridge.observe(KeyboardBridge.takeStart) { [weak self] in
                    MainActor.assumeIsolated { self?.keyboardRequestedStart() }
                },
                KeyboardBridge.observe(KeyboardBridge.takeStop) { [weak self] in
                    MainActor.assumeIsolated { self?.keyboardRequestedStop() }
                },
            ]
        }
        publishStatus()
    }

    private func load() {
        guard let store = dependencies.store else {
            errorMessage = "Could not load local data."
            return
        }
        do {
            settings = try store.loadSettings()
            // Default profiles get fresh IDs on every decode-less load; persist them once so keys stored
            // under those IDs survive the next launch.
            if !FileManager.default.fileExists(atPath: store.url("settings").path) { try store.saveSettings(settings) }
            device = try store.loadDevice()
            history = try store.loadHistory().sorted { $0.date > $1.date }
        } catch {
            errorMessage = "Could not load local data: \(error.localizedDescription)"
        }
        lastResult = dependencies.resultStore.read()
        showingOnboarding = !device.onboardingCompleted
        if !device.serverURL.isEmpty, device.lastSyncedAt != nil {
            syncStatus = syncedStatus()
        }
    }

    // MARK: Device options

    func setMode(_ mode: WritingMode) {
        guard IOSDeviceSettings.modes.contains(mode), mode != device.mode else { return }
        device.mode = mode
        persistDevice()
    }

    func setKeepHistory(_ keep: Bool) {
        device.keepHistory = keep
        persistDevice()
    }

    func setListeningTimeout(minutes: Int) {
        device.listeningTimeoutMinutes = min(max(minutes, IOSDeviceSettings.listeningTimeoutRange.lowerBound),
                                             IOSDeviceSettings.listeningTimeoutRange.upperBound)
        persistDevice()
        if listening { resetIdleTimer() }
    }

    func completeOnboarding() {
        device.onboardingCompleted = true
        persistDevice()
        showingOnboarding = false
    }

    func setLanguage(_ value: AppLanguage) {
        L10n.language = value
        language = value
    }

    func persistDevice() {
        do { try dependencies.store?.saveDevice(device) } catch { errorMessage = .init(error: error) }
    }

    // MARK: Shared settings

    /// Validates and saves settings, like the Mac `AppState.save`. Marks the device dirty for the next upload.
    @discardableResult
    func save(_ updated: SharedSettings) -> Bool {
        do {
            var updated = updated
            updated.profiles = updated.profiles.map(\.normalizedInput)
            updated.targetLanguage = updated.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            try updated.validate()
            try dependencies.store?.saveSettings(updated)
            settings = updated
            device.dirty = true
            persistDevice()
            errorMessage = ""
            return true
        } catch {
            errorMessage = .init(error: error)
            return false
        }
    }

    func selectProfile(_ id: UUID, role: ModelRole) {
        var updated = settings
        if role == .speech { updated.speechID = id } else { updated.writingID = id }
        save(updated)
    }

    func selectStyle(_ id: UUID?) {
        var updated = settings
        updated.selectedStyleID = id
        save(updated)
    }

    func setTargetLanguage(_ value: String) {
        var updated = settings
        updated.targetLanguage = value
        save(updated)
    }

    func hasKey(for profile: ModelProfile) -> Bool {
        (try? dependencies.credentials.contains(CredentialAccount.profile(profile.id))) ?? false
    }

    func setKey(_ value: String, for profile: ModelProfile) {
        do {
            try dependencies.credentials.write(value.trimmingCharacters(in: .whitespacesAndNewlines),
                                               account: CredentialAccount.profile(profile.id))
            device.dirty = true
            persistDevice()
            errorMessage = ""
            notice = "Saved on this iPhone"
        } catch { errorMessage = .init(error: error) }
    }

    // MARK: Vocabulary

    func setVocabularyEnabled(_ enabled: Bool) {
        var updated = settings
        updated.vocabulary.enabled = enabled
        save(updated)
    }

    func addVocabulary(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = settings
        updated.vocabulary.appendLines(text)
        save(updated)
    }

    func setVocabularyEntry(_ id: UUID, enabled: Bool) {
        var updated = settings
        guard let index = updated.vocabulary.entries.firstIndex(where: { $0.id == id }) else { return }
        updated.vocabulary.entries[index].enabled = enabled
        save(updated)
    }

    func deleteVocabularyEntry(_ id: UUID) {
        var updated = settings
        updated.vocabulary.removeEntry(id)
        save(updated)
    }

    // MARK: History

    func deleteHistory(_ id: UUID) {
        let remaining = history.filter { $0.id != id }
        do {
            history = try dependencies.store?.saveHistory(remaining) ?? remaining
        } catch { errorMessage = .init(error: error) }
    }

    func clearHistory() {
        do {
            history = try dependencies.store?.saveHistory([]) ?? []
        } catch { errorMessage = .init(error: error) }
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        notice = "Copied"
    }

    private func appendHistory(mode: WritingMode, original: String, output: String, duration: Double,
                               configuration: TakeConfiguration, source: TakeSource) {
        guard device.keepHistory else { return }
        var entry = HistoryEntry(mode: mode, original: original, result: output,
                                 application: source == .keyboard ? "Keyboard" : "VoiceDraft", duration: duration)
        entry.speechModel = configuration.speech.model
        entry.writingModel = configuration.writing.model
        entry.styleName = configuration.settings.styles.first { $0.prompt == configuration.settings.stylePrompt }?.name
        var updated = history
        updated.insert(entry, at: 0)
        do {
            history = try dependencies.store?.saveHistory(updated) ?? Array(updated.prefix(IOSLocalStore.historyLimit))
        } catch { errorMessage = "Could not save history: \(error.localizedDescription)" }
    }

    // MARK: Takes

    /// Starts recording. Returns false when the take could not start; the reason is in `errorMessage`.
    @discardableResult
    func startTake(source: TakeSource = .app) -> Bool {
        guard machine.state == .idle else { return false }
        errorMessage = ""
        notice = ""
        transcript = ""
        resultText = ""
        let configuration: TakeConfiguration
        do {
            configuration = try TakeConfiguration.make(settings: settings, mode: device.mode,
                                                       credentials: dependencies.credentials,
                                                       application: source == .keyboard ? "" : "VoiceDraft")
        } catch {
            errorMessage = .init(error: error)
            if source == .keyboard { deliverToKeyboard("", mode: device.mode) }
            return false
        }
        machine.handle(.start)
        takeState = machine.state
        takeSource = source
        elapsed = 0
        level = 0
        idleTimer?.invalidate()
        let coordinator = TakeCoordinator(configuration: configuration, usageLog: dependencies.usageLog)
        self.coordinator = coordinator
        router.begin(feed: coordinator.feed, maxSeconds: Self.maxTakeSeconds)
        let id = configuration.id
        let router = router
        coordinator.startLiveSession(audioSeconds: { router.elapsed }, onUpdate: { [weak self] text in
            await self?.updateTranscript(text, id: id)
        }, onFailure: { [weak self] error in
            await self?.fail(error, id: id)
        })
        publishStatus()
        let audio = dependencies.audio
        takeTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if !audio.isRunning { try await audio.start() }
                guard let self else { return }
                // The take may have stopped or been cancelled while the microphone was opening.
                guard self.isCurrent(id), self.takeState == .recording else { self.stopAudioIfUnused(); return }
                self.startTick(id: id)
            } catch {
                self?.fail(error, id: id)
            }
        }
        return true
    }

    /// Stops recording and runs recognition and writing.
    func stopTake() {
        guard machine.state == .recording, let coordinator else { return }
        tick?.invalidate()
        tick = nil
        let duration = router.elapsed
        let pcm = router.end()
        machine.handle(.stop)
        takeState = machine.state
        elapsed = duration
        level = 0
        stopAudioIfUnused()
        publishStatus()
        let id = coordinator.configuration.id
        takeTask = Task { [weak self] in
            await self?.process(coordinator: coordinator, pcm: pcm, duration: duration, id: id)
        }
    }

    /// Abandons the current take without a result.
    func cancelTake() {
        guard let id = coordinator?.configuration.id else { return }
        finishTake(id: id, event: .cancel)
    }

    private func process(coordinator: TakeCoordinator, pcm: Data, duration: Double, id: UUID) async {
        let configuration = coordinator.configuration
        do {
            guard duration >= 0.25 else { throw VoiceDraftError.message("The recording was too short. Try again.") }
            let raw = try await coordinator.transcribe(pcm: pcm, duration: duration)
            try Task.checkCancellation()
            guard isCurrent(id) else { return }
            transcript = raw
            var output = raw
            do {
                output = try await coordinator.write(raw) { [weak self] text in
                    await self?.updateResult(text, id: id)
                }
            } catch {
                try Task.checkCancellation()
                guard isCurrent(id) else { return }
                resultText = raw
                appendHistory(mode: .verbatim, original: raw, output: raw, duration: duration,
                              configuration: configuration, source: takeSource ?? .app)
                throw VoiceDraftError.message("Writing failed. Your transcript is preserved. \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            guard isCurrent(id) else { return }
            complete(output: output, raw: raw, duration: duration, configuration: configuration)
        } catch {
            fail(error, id: id)
        }
    }

    private func complete(output: String, raw: String, duration: Double, configuration: TakeConfiguration) {
        let source = takeSource ?? .app
        resultText = output
        appendHistory(mode: configuration.mode, original: raw, output: output, duration: duration,
                      configuration: configuration, source: source)
        deliverToKeyboard(output, mode: configuration.mode)
        finishTake(id: configuration.id, event: .complete)
    }

    /// Mirrors the Mac `fail`: no speech ends quietly, cancellation is silent, anything else is shown.
    func fail(_ error: Error, id: UUID) {
        guard isCurrent(id) else { return }
        let noSpeech: Bool
        if case SpeechRecognitionError.noSpeech = error { noSpeech = true } else { noSpeech = false }
        if !noSpeech, !(error is CancellationError) { errorMessage = .init(error: error) }
        finishTake(id: id, event: error is CancellationError ? .cancel : .fail)
    }

    private func finishTake(id: UUID, event: TakeMachine.Event) {
        guard isCurrent(id) else { return }
        let source = takeSource
        let mode = coordinator?.configuration.mode ?? device.mode
        if event != .complete {
            coordinator?.cancel()
            router.cancel()
            takeTask?.cancel()
            if source == .keyboard { deliverToKeyboard("", mode: mode) }
        }
        tick?.invalidate()
        tick = nil
        machine.handle(event)
        takeState = machine.state
        coordinator = nil
        takeSource = nil
        level = 0
        stopAudioIfUnused()
        if listening { resetIdleTimer() }
        publishStatus()
    }

    private func isCurrent(_ id: UUID) -> Bool { coordinator?.configuration.id == id }

    private func updateTranscript(_ text: String, id: UUID) {
        guard isCurrent(id) else { return }
        transcript = text
    }

    private func updateResult(_ text: String, id: UUID) {
        guard isCurrent(id), takeState == .processing else { return }
        resultText = text
    }

    private func startTick(id: UUID) {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(id), self.takeState == .recording else { return }
                if let failure = self.router.failure { self.fail(failure, id: id); return }
                self.elapsed = self.router.elapsed
                self.level = self.router.level
                if self.elapsed >= Self.maxTakeSeconds { self.stopTake() }
            }
        }
    }

    /// Writes the latest result for the keyboard. Keyboard failures write an empty text, which the keyboard
    /// treats as "finished, nothing to insert".
    private func deliverToKeyboard(_ text: String, mode: WritingMode) {
        let result = SharedResult(text: text, mode: mode.rawValue)
        do {
            try dependencies.resultStore.write(result)
            if !text.isEmpty { lastResult = result }
        } catch {
            // The app group is unavailable (for example an unsigned build); the in-app result is unaffected.
        }
        dependencies.post(KeyboardBridge.resultUpdated)
    }

    // MARK: Keyboard bridge

    func keyboardRequestedStart() {
        guard listening, takeState == .idle else { return }
        startTake(source: .keyboard)
    }

    func keyboardRequestedStop() {
        guard takeState == .recording else { return }
        stopTake()
    }

    /// Rewrites `app-status.json` and posts `status.updated`.
    func publishStatus(now: Date = Date()) {
        try? dependencies.statusStore.write(AppStatusPolicy.status(take: takeState, listening: listening, now: now))
        dependencies.post(KeyboardBridge.statusUpdated)
    }

    // MARK: Listening session

    /// Starts or ends the listening session. While it runs the microphone stays open, buffers outside a take
    /// are discarded, and the keyboard can start takes while the app is in the background.
    func setListening(_ enabled: Bool) async {
        if enabled {
            guard !listening else { return }
            do {
                if !dependencies.audio.isRunning { try await dependencies.audio.start() }
            } catch {
                errorMessage = .init(error: error)
                return
            }
            listening = true
            resetIdleTimer()
            statusTimer?.invalidate()
            statusTimer = Timer.scheduledTimer(withTimeInterval: Self.statusRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishStatus() }
            }
            publishStatus()
        } else {
            endListening()
        }
    }

    func endListening() {
        guard listening else { return }
        listening = false
        listeningEndsAt = nil
        idleTimer?.invalidate()
        idleTimer = nil
        statusTimer?.invalidate()
        statusTimer = nil
        stopAudioIfUnused()
        publishStatus()
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let timeout = TimeInterval(device.listeningTimeoutMinutes * 60)
        listeningEndsAt = Date().addingTimeInterval(timeout)
        idleTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.listening else { return }
                if self.takeState == .idle { self.endListening() } else { self.resetIdleTimer() }
            }
        }
    }

    private func stopAudioIfUnused() {
        guard !listening, takeState != .recording, dependencies.audio.isRunning else { return }
        dependencies.audio.stop()
    }

    private func audioInterrupted(_ error: Error) {
        if let id = coordinator?.configuration.id, takeState == .recording { fail(error, id: id) }
        if listening {
            endListening()
            if errorMessage.isEmpty { errorMessage = .init(error: error) }
        }
    }

    /// Called when the scene becomes active: re-read the shared result and refresh the status lease.
    func sceneBecameActive() {
        lastResult = dependencies.resultStore.read() ?? lastResult
        publishStatus()
    }

    // MARK: Sync support (see AppModel+Sync.swift)

    func applySyncedState(settings: SharedSettings, device: IOSDeviceSettings) {
        self.settings = settings
        self.device = device
    }

    func setSync(status: LocalizedMessage) { syncStatus = status }
    func setSyncing(_ value: Bool) { syncing = value }
    func updateDevice(_ change: (inout IOSDeviceSettings) -> Void) {
        change(&device)
        persistDevice()
    }

    func syncedStatus() -> LocalizedMessage {
        let time = (device.lastSyncedAt ?? Date()).formatted(.dateTime.hour().minute().locale(L10n.locale))
        return "Synced · revision \(device.syncRevision) · \(time)"
    }
}

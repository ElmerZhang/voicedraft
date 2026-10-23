import AVFoundation
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
        var presenceStore: KeyboardPresenceStore
        var audio: AudioCapturing
        /// The Picture in Picture window that keeps the app resident during standby while the microphone is closed.
        var keepAlive: StandbyKeepAlive
        var usageLog: IOSUsageLog
        /// Posts a Darwin notification.
        var post: (String) -> Void
        /// Registers the keyboard's `take.start` and `take.stop` observers.
        var observeKeyboard: Bool
        var pendingTakeStore: PendingTakeStore? = nil
        var returnToHost: (@MainActor (String?) -> String)? = nil
        var isForegroundActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
        var meterStore: RecordingMeterStore? = nil
        var appCheckStore: KeyboardAppCheckStore? = nil

        static func live() -> Dependencies {
            let store = try? IOSLocalStore()
            // One session controller for the microphone and the keep-alive, so they share one session configuration.
            let session = IOSAudioSessionController()
            return Dependencies(store: store, credentials: IOSKeychainStore(), statusStore: AppStatusStore(),
                                resultStore: SharedResultStore(), presenceStore: KeyboardPresenceStore(),
                                audio: IOSAudioCapture(sessionController: session),
                                keepAlive: IOSPictureInPictureKeepAlive(sessionController: session),
                                usageLog: IOSUsageLog(directory: store?.directory.appendingPathComponent("Usage", isDirectory: true)),
                                post: KeyboardBridge.post, observeKeyboard: true,
                                pendingTakeStore: PendingTakeStore(),
                                returnToHost: { VDHostNavigation.returnToHost($0, application: UIApplication.shared) },
                                meterStore: RecordingMeterStore(), appCheckStore: KeyboardAppCheckStore())
        }
    }

    // MARK: Published state

    @Published private(set) var settings = SharedSettings()
    @Published private(set) var device = IOSDeviceSettings()
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var takeState: TakeState = .idle
    @Published private(set) var takeSource: TakeSource?
    @Published private(set) var listening = false
    /// The standby deadline while `listening` is on.
    @Published private(set) var listeningEndsAt: Date?
    /// Why standby ended on its own (for example iOS refused to start recording in the background). Written to
    /// `AppStatus.lastError` for the keyboard; cleared when standby or a take starts again.
    @Published private(set) var standbyError: String?
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
    /// A parsed pairing link waiting for the user to confirm. Never persisted.
    @Published var pendingPairing: SyncPairing?
    /// The keyboard's presence marker, re-read whenever the scene becomes active.
    @Published private(set) var keyboardPresence: KeyboardPresence?
    /// Hides the Home setup banner until the app is relaunched.
    @Published var keyboardBannerDismissed = false
    /// The take the keyboard opened the app for (`voicedraft://record`). Drives the full-screen recording view
    /// until the user closes it.
    @Published var keyboardTakeID: UUID?

    var keyboardSetup: KeyboardSetupStatus { KeyboardSetupStatus(presence: keyboardPresence) }

    var mode: WritingMode { device.mode }
    var busy: Bool { takeState != .idle }
    var standbyWindowHint: String {
        if IOSPictureInPictureKeepAlive.hidesWindowByDefault {
            return AppText.t("Starting standby briefly prepares the microphone. Standby hides automatically without a floating window or edge arrow. Turn off standby here to end it.")
        }
        return AppText.t("Starting standby briefly opens the microphone to prepare it. After you leave VoiceDraft, a small Picture in Picture window keeps standby available. Drag it to the screen edge to tuck it away; closing it ends standby.")
    }

    // MARK: Private state
    private var keyboardReturnTask: Task<Void, Never>?
    private var standbyActivation: UUID?

    let dependencies: Dependencies
    private var machine = TakeMachine()
    private var coordinator: TakeCoordinator?
    private let router = PCMRouter()
    private var takeTask: Task<Void, Never>?
    /// When `app-status.json` was last written; a recording take rewrites it every `takeStatusRefreshInterval`.
    private var statusPublishedAt = Date.distantPast
    static let takeStatusRefreshInterval: TimeInterval = 30
    private var tick: Timer?
    private var lastMeterSampleAt: TimeInterval?
    private var statusTimer: Timer?
    private var standbyTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observations: [KeyboardBridge.Observation] = []

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
        let router = router
        dependencies.audio.onPCM = { router.accept($0) }
        dependencies.audio.onInterruption = { [weak self] error in
            Task { @MainActor in self?.audioInterrupted(error) }
        }
        dependencies.keepAlive.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.standbyAudioEvent(event) }
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
                KeyboardBridge.observe(KeyboardBridge.appCheckRequested) { [weak self] in
                    MainActor.assumeIsolated { self?.replyToKeyboardAppCheck() }
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
        keyboardPresence = dependencies.presenceStore.read()
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

    func setKeyboardStandby(minutes: Int) {
        guard IOSDeviceSettings.standbyOptions.contains(minutes) else { return }
        device.keyboardStandbyMinutes = minutes
        persistDevice()
    }

    /// Fallback: keep the microphone open for the whole standby window (the previous behaviour). A running standby
    /// switches over at once and keeps its deadline.
    func setStandbyKeepsMicrophoneOpen(_ keep: Bool) async {
        guard device.standbyKeepsMicrophoneOpen != keep else { return }
        device.standbyKeepsMicrophoneOpen = keep
        persistDevice()
        guard listening, takeState == .idle else { return }
        if keep, !dependencies.audio.isRunning {
            do { try await dependencies.audio.start() } catch {
                errorMessage = .init(error: error)
                endListening()
                return
            }
        }
        settleStandbyAudio()
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
    /// `id` names the take; a keyboard take opened through `voicedraft://record` passes the keyboard's id so the
    /// `SharedResult` it produces carries the same id.
    @discardableResult
    func startTake(source: TakeSource = .app, id takeID: UUID = UUID()) -> Bool {
        guard machine.state == .idle else { return false }
        errorMessage = ""
        notice = ""
        transcript = ""
        resultText = ""
        let configuration: TakeConfiguration
        do {
            configuration = try TakeConfiguration.make(settings: settings, mode: device.mode,
                                                       credentials: dependencies.credentials,
                                                       application: source == .keyboard ? "" : "VoiceDraft", id: takeID)
        } catch {
            errorMessage = .init(error: error)
            if source == .keyboard { deliverToKeyboard("", mode: device.mode, id: takeID) }
            return false
        }
        machine.handle(.start)
        takeState = machine.state
        dependencies.keepAlive.setRecording(true)
        takeSource = source
        elapsed = 0
        level = 0
        lastMeterSampleAt = nil
        dependencies.meterStore?.clear()
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
                // On standby a fresh microphone engine starts from the background while the Picture in Picture
                // keep-alive (and the active session it holds) keeps running; the keep-alive is not stopped for the
                // take. If the start throws, `microphoneFailed` ends standby and `settleStandbyAudio` stops the
                // keep-alive and deactivates the session.
                if !audio.isReadyForRecording { try await audio.start() }
                guard let self else { return }
                // The take may have stopped or been cancelled while the microphone was opening; settling then stops
                // the microphone (keeping the session active while standby is on).
                guard self.isCurrent(id), self.takeState == .recording else { self.settleStandbyAudio(); return }
                self.standbyError = nil
                self.settleStandbyAudio()
                self.startTick(id: id)
                self.publishStatus()
            } catch {
                self?.microphoneFailed(error, id: id)
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
        settleStandbyAudio()
        if takeSource == .keyboard, backgroundTask == .invalid {
            // The keyboard usually stops the take while the app is in the background. Without standby the
            // microphone just closed, so ask for time to finish recognition and writing.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceDraft keyboard take") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
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
        deliverToKeyboard(output, mode: configuration.mode, id: configuration.id)
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
        keyboardReturnTask?.cancel()
        keyboardReturnTask = nil
        let source = takeSource
        let mode = coordinator?.configuration.mode ?? device.mode
        if event != .complete {
            coordinator?.cancel()
            router.cancel()
            takeTask?.cancel()
            if source == .keyboard { deliverToKeyboard("", mode: mode, id: id) }
        }
        tick?.invalidate()
        tick = nil
        machine.handle(event)
        takeState = machine.state
        coordinator = nil
        takeSource = nil
        level = 0
        // Standby that reached its deadline during the take ends now.
        if listening, let end = listeningEndsAt, end <= Date() { endListening() }
        settleStandbyAudio()
        publishStatus()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
                if self.takeSource == .keyboard, let sample = self.router.recordingMeter(takeID: id),
                   sample.sampledAt != self.lastMeterSampleAt {
                    try? self.dependencies.meterStore?.write(sample)
                    self.lastMeterSampleAt = sample.sampledAt
                }
                // Keeps `updatedAt` fresh without standby, so the keyboard can tell the take is still running.
                if Date().timeIntervalSince(self.statusPublishedAt) >= Self.takeStatusRefreshInterval { self.publishStatus() }
                if self.elapsed >= Self.maxTakeSeconds { self.stopTake() }
            }
        }
    }

    /// Writes the latest result for the keyboard. Keyboard failures write an empty text, which the keyboard
    /// treats as "finished, nothing to insert".
    private func deliverToKeyboard(_ text: String, mode: WritingMode, id: UUID) {
        let result = SharedResult(id: id, text: text, mode: mode.rawValue)
        do {
            try dependencies.resultStore.write(result)
            if !text.isEmpty { lastResult = result }
        } catch {
            // The app group is unavailable (for example an unsigned build); the in-app result is unaffected.
        }
        dependencies.post(KeyboardBridge.resultUpdated)
    }

    // MARK: Keyboard bridge

    func replyToKeyboardAppCheck() {
        guard let store = dependencies.appCheckStore, let request = store.readRequest(), request.isFresh() else { return }
        let ready = listening && (device.standbyKeepsMicrophoneOpen
                                 ? dependencies.audio.isRunning : dependencies.keepAlive.isReadyForBackground)
        let state: KeyboardAppCheckReply.State = takeState != .idle ? .busy : (ready ? .ready : .unavailable)
        let reply = KeyboardAppCheckReply(requestID: request.id, state: state, takeID: coordinator?.configuration.id)
        guard (try? store.writeReply(reply)) != nil else { return }
        dependencies.post(KeyboardBridge.appCheckReplied)
    }

    func keyboardRequestedStart() {
        guard listening, takeState == .idle else { return }
        if startTake(source: .keyboard) { extendStandbyForKeyboardTake() }
    }

    /// Handles `voicedraft://record?take=<id>&source=keyboard`. Returns false for other URLs.
    /// No confirmation: the user just tapped the keyboard's talk button. The take starts at once (the microphone
    /// permission prompt comes from the audio start) and the full-screen recording view opens.
    @discardableResult
    func receiveRecordLink(_ url: URL) -> Bool {
        guard let id = KeyboardRecordLink.takeID(from: url) else { return false }
        // Onboarding would cover the recording view; skip it for this session only.
        showingOnboarding = false
        keyboardTakeID = id
        guard takeState == .idle else { return true }
        if startTake(source: .keyboard, id: id) {
            extendStandbyForKeyboardTake()
            if let request = dependencies.pendingTakeStore?.read(), request.permitsAutomaticReturn(for: id) {
                scheduleKeyboardReturn(request)
            }
        }
        return true
    }

    /// Return only for a fresh, matching hand-off written by our keyboard. No URL may choose a destination.
    private func scheduleKeyboardReturn(_ request: PendingTake) {
        guard let returnToHost = dependencies.returnToHost else { return }
        keyboardReturnTask?.cancel()
        keyboardReturnTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled, Date() < deadline {
                guard let self, self.isCurrent(request.id), self.takeState == .recording,
                      request.permitsAutomaticReturn(for: request.id) else { return }
                let standbyReady = self.device.keyboardStandbyMinutes == 0 ||
                    (self.listening && (self.device.standbyKeepsMicrophoneOpen || self.dependencies.keepAlive.isPreparedForBackgroundTransition))
                if self.dependencies.audio.isReadyForRecording, standbyReady, self.dependencies.isForegroundActive() {
                    KeyboardDiagnostics.record("return.attempt", "take=\(request.id) host=\(request.hostBundleIdentifier ?? "system-back")")
                    let result = returnToHost(request.hostBundleIdentifier)
                    KeyboardDiagnostics.record("return.result", result)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            KeyboardDiagnostics.record("return.not-ready", "take=\(request.id)")
        }
    }

    /// Closes the keyboard take view. A take still recording is cancelled.
    func dismissKeyboardTake() {
        if takeState == .recording, takeSource == .keyboard { cancelTake() }
        keyboardTakeID = nil
    }


    func keyboardRequestedStop() {
        guard takeState == .recording else { return }
        stopTake()
    }

    /// Rewrites `app-status.json` and posts `status.updated`.
    func publishStatus(now: Date = Date()) {
        if takeState != .recording { dependencies.meterStore?.clear() }
        let ready = listening && (device.standbyKeepsMicrophoneOpen
                                  ? dependencies.audio.isRunning : dependencies.keepAlive.isReadyForBackground)
        // Losing standby must not strand an already-running keyboard take or its background processing wait.
        let working = (takeState == .recording && dependencies.audio.isReadyForRecording) ||
            (takeState == .processing && backgroundTask != .invalid)
        try? dependencies.statusStore.write(AppStatusPolicy.status(take: takeState, listening: ready || working,
                                                                     until: ready ? listeningEndsAt : now.addingTimeInterval(AppStatus.liveTakeWindow),
                                                                     takeID: coordinator?.configuration.id,
                                                                     lastError: standbyError, now: now))
        statusPublishedAt = now
        dependencies.post(KeyboardBridge.statusUpdated)
    }

    // MARK: Standby (listening session)

    /// "Start standby now" (`true`) or end standby (`false`). During standby the app stays resident in the
    /// background with a Picture in Picture window and the microphone closed; the microphone opens only for a keyboard take
    /// (`standbyKeepsMicrophoneOpen` keeps it open instead). It ends at a fixed deadline; it is not refreshed by use.
    func setListening(_ enabled: Bool) async {
        if enabled {
            guard !listening else { return }
            await startStandby(until: StandbyPolicy.manualDeadline(minutes: device.keyboardStandbyMinutes))
        } else {
            endListening()
        }
    }

    /// Starts or extends standby after a keyboard take started, for `keyboardStandbyMinutes` (0: no standby).
    private func extendStandbyForKeyboardTake() {
        guard let deadline = StandbyPolicy.deadline(extending: listening ? listeningEndsAt : nil,
                                                    minutes: device.keyboardStandbyMinutes) else { return }
        Task { await startStandby(until: deadline) }
    }

    /// Opens standby until `deadline`, or moves the deadline of a running standby.
    func startStandby(until deadline: Date) async {
        if !listening {
            let activation = UUID()
            standbyActivation = activation
            if device.standbyKeepsMicrophoneOpen {
                // A recording take already holds the microphone; starting it twice would install a second tap.
                if takeState != .recording, !dependencies.audio.isRunning {
                    do { try await dependencies.audio.start() } catch {
                        errorMessage = .init(error: error)
                        return
                    }
                }
            } else {
                // A new standby session establishes microphone IO once while foreground-active. On device,
                // cold background-only engine.start could succeed yet deliver zero buffers. All PCM outside
                // a take is discarded by the router; the mic closes again after this preparation.
                if takeState != .recording, !dependencies.audio.isReadyForRecording {
                    do { try await dependencies.audio.start() }
                    catch {
                        guard standbyActivation == activation else { return }
                        dependencies.keepAlive.stop(deactivatingSession: true)
                        errorMessage = .init(error: error)
                        return
                    }
                    guard standbyActivation == activation else { settleStandbyAudio(); return }
                }
                // Also during a recording take: Picture in Picture can only be created in the foreground, which is
                // where a keyboard take opened through `voicedraft://record` extends standby. It runs through takes.
                do { try dependencies.keepAlive.start() } catch {
                    dependencies.keepAlive.stop(deactivatingSession: !dependencies.audio.isRunning)
                    settleStandbyAudio()
                    errorMessage = .init(error: error)
                    return
                }
            }
            guard standbyActivation == activation else { settleStandbyAudio(); return }
            listening = true
            standbyError = nil
            statusTimer?.invalidate()
            statusTimer = Timer.scheduledTimer(withTimeInterval: Self.statusRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishStatus() }
            }
        }
        listeningEndsAt = deadline
        if takeState != .recording { settleStandbyAudio() }
        standbyTimer?.invalidate()
        standbyTimer = Timer.scheduledTimer(withTimeInterval: max(deadline.timeIntervalSinceNow, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.standbyDeadlinePassed() }
        }
        publishStatus()
    }

    /// The standby timer fired. A take in progress finishes first; `finishTake` then ends standby.
    func standbyDeadlinePassed() {
        guard listening, takeState == .idle else { return }
        endListening()
    }

    func endListening() {
        standbyActivation = nil
        guard listening else { settleStandbyAudio(); return }
        listening = false
        listeningEndsAt = nil
        standbyTimer?.invalidate()
        standbyTimer = nil
        statusTimer?.invalidate()
        statusTimer = nil
        settleStandbyAudio()
        publishStatus()
    }

    /// Brings the audio hardware in line with the take and standby state. The microphone and the Picture in
    /// Picture keep-alive share one session configuration (`IOSAudioSessionController`):
    /// - recording: the microphone runs; on standby the keep-alive keeps running through the take;
    /// - standby, no recording: the keep-alive runs (started first if needed), then the microphone engine is
    ///   discarded keeping the session active (or the microphone stays open with `standbyKeepsMicrophoneOpen`, which
    ///   does not use the keep-alive);
    /// - no standby, no recording: everything stops and the session is deactivated.
    /// The session is deactivated only when standby ends or an in-app take without standby ends.
    private func settleStandbyAudio() {
        let audio = dependencies.audio
        let keepAlive = dependencies.keepAlive
        keepAlive.setRecording(takeState == .recording)
        if takeState == .recording { return }
        guard listening else {
            if audio.isRunning {
                if keepAlive.isRunning { keepAlive.stop(deactivatingSession: false) }
                audio.stop()
            } else {
                // Also when a failed microphone start left the session active.
                keepAlive.stop(deactivatingSession: true)
            }
            return
        }
        if device.standbyKeepsMicrophoneOpen {
            if keepAlive.isRunning { keepAlive.stop(deactivatingSession: false) }
            return
        }
        if !keepAlive.isRunning {
            do {
                try keepAlive.start()
            } catch {
                if audio.isRunning { audio.stop(keepingSessionActive: true) }
                standbyFailed(error)
                return
            }
        }
        if audio.isRunning { audio.stop(keepingSessionActive: true) }
    }

    /// The microphone could not start. For a keyboard take on standby this usually means iOS refused to start
    /// recording in the background (`AVAudioSession.ErrorCode.cannotStartRecording`, '!rec'): standby ends and the
    /// error reaches the keyboard through `AppStatus.lastError`, so its next tap opens the app instead.
    private func microphoneFailed(_ error: Error, id: UUID) {
        guard isCurrent(id) else { return }
        if listening, takeSource == .keyboard {
            standbyError = Self.backgroundStartMessage(error)
            endListening()
        }
        fail(error, id: id)
    }

    /// Standby lost its keep-alive and could not restart it.
    private func standbyFailed(_ error: Error) {
        standbyError = Self.backgroundStartMessage(error)
        endListening()
    }

    /// The error text names the failed step and the OSStatus code, for example
    /// `take: setActive failed: OSStatus 561145187 '!rec'`.
    static func backgroundStartMessage(_ error: Error) -> String {
        let detail = AudioStepError.describe(error)
        return AppText.t("VoiceDraft could not keep standby in the background: {0}. The next tap opens VoiceDraft.", detail)
    }

    /// Events from the keep-alive. An interruption (a call, Siri, another app's non-mixable audio) deactivates the
    /// session but leaves the Picture in Picture window up; when it ends, or after a media-services reset, the
    /// session is activated again (a recording take is failed by the microphone's own interruption handler). The
    /// window closing without a return to the app ends standby at once, so the keyboard stops offering
    /// hold-to-talk; a window that failed to start ends standby with the reason for the keyboard.
    func standbyAudioEvent(_ event: StandbyAudioEvent) {
        let keepAlive = dependencies.keepAlive
        switch event {
        case .readinessChanged:
            publishStatus()
        case .interruptionBegan:
            break
        case .interruptionEnded, .mediaServicesReset:
            if listening, keepAlive.isRunning, takeState != .recording {
                do { try keepAlive.start() } catch {
                    standbyFailed(error)
                    return
                }
            }
            settleStandbyAudio()
        case .keepAliveEnded:
            endListening()
            settleStandbyAudio()
        case .keepAliveFailed(let detail):
            guard listening else { settleStandbyAudio(); return }
            standbyError = AppText.t("VoiceDraft could not keep standby in the background: {0}. The next tap opens VoiceDraft.", detail)
            endListening()
        }
    }

    private func audioInterrupted(_ error: Error) {
        if let id = coordinator?.configuration.id, takeState == .recording { fail(error, id: id) }
        if listening {
            endListening()
            if errorMessage.isEmpty { errorMessage = .init(error: error) }
        }
    }

    /// Called when the scene becomes active, for example after returning from Settings: re-read the shared
    /// result and the keyboard presence marker, and refresh the status lease.
    func sceneBecameActive() {
        lastResult = dependencies.resultStore.read() ?? lastResult
        keyboardPresence = dependencies.presenceStore.read()
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

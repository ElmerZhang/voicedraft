import AppKit
import AVFoundation
import SwiftUI
import CryptoKit
import VoiceDraftCore

/// A status-menu request to extract words from an app's window.
struct ScreenExtractionRequest: Equatable {
    let id = UUID()
    let app: ScreenContextApplication
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings = SharedSettings()
    @Published private(set) var device = DeviceSettings()
    @Published private(set) var history: [HistoryEntry] = []
    @Published var page = "Studio"
    /// Tab shown when `page` is "Settings". Models and Sync are settings tabs, not pages.
    @Published var settingsTab = "Settings"
    @Published private(set) var interfaceLanguage = L10n.language
    var languageChanged: (() -> Void)?
    func setLanguage(_ value: AppLanguage) {
        L10n.language = value
        interfaceLanguage = value
        languageChanged?()
    }
    @Published var mode: WritingMode = .polish
    @Published var transcript = ""
    @Published var result = ""
    @Published var selection = ""
    @Published var status: LocalizedMessage = "Ready when you are"
    @Published var error: LocalizedMessage = ""
    @Published private(set) var phase = "idle"
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var syncStatus: LocalizedMessage = "Not connected"
    @Published private(set) var syncing = false
    @Published var notice: LocalizedMessage = ""
    @Published private(set) var vocabularyLearningStatus = ""
    private var vocabularyLearningTask: Task<Void, Never>?
    private var correctionObservationTask: Task<Void, Never>?
    private var resultCorrectionTask: Task<Void, Never>?
    private var vocabularyLearningID = UUID()
    private var resultBeforeCorrection: String?
    private var vocabularyDiscoveries = VocabularyDiscoveryTracker()
    private var store: LocalStore?
    /// Device-local model usage log; writes nothing in preview mode.
    private(set) var usageLog = UsageLog(directory: nil)
    let updater = UpdateController()
    let preview: Bool
    private let recorder = AudioRecorder()
    private let liveRecorder = LiveAudioRecorder()
    private var liveFeed: LiveAudioFeed?
    private var runAudio: Data?
    private var runRetainAudio = false
    private let effects = RecordingEffects()
    private var gesture = RecordingGesture()
    private var heldAction: ShortcutAction?
    private var finishWhenReady = false
    private var recentInputs = RecentInputContext()
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    @Published var playingAudioID: UUID?
    @Published var showingOnboarding = false
    var configureShortcuts: (([ShortcutBinding]) throws -> Void)?
    var chooseSelectionStyle: (() -> Void)?
    var pendingStyleTarget: InputTarget?
    private var stopTask: Task<Void, Never>?
    @Published private(set) var liveTranscript = ""
    @Published private(set) var recordingLocked = false
    @Published private(set) var hudKind = DictationHUDKind.compact
    @Published private(set) var hudText = ""
    @Published private(set) var hudCopied = false
    private var runAutoPaste = false
    private var runExternal = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var defaultInputID: String?
    @Published private(set) var recordingDeviceName = ""
    /// On-screen context for dictation into other apps; memory only, never persisted or synced.
    let screenContext = ScreenContextCoordinator()
    /// Screen terms offered to the current take, for the HUD indicator; nil when none.
    @Published private(set) var screenContextTermCount: Int?
    /// The last external app, which Vocabulary's "Extract from %@" reads.
    @Published private(set) var screenContextApplication: ScreenContextApplication?
    /// Set by the status menu; Vocabulary opens its review sheet in screen mode.
    @Published var screenExtractionRequest: ScreenExtractionRequest?
    private var inputObservers: [NSObjectProtocol] = []
    func refreshInputDevices() {
        guard !preview else { return }
        inputDevices = AudioRecorder.devices(); defaultInputID = AudioRecorder.defaultDeviceID
    }
    func selectInputDevice(_ id: String) {
        guard !busy else { return }
        var updated = device
        updated.inputDeviceID = id.isEmpty ? nil : id
        updated.inputDeviceName = inputDevices.first { $0.id == id }?.name
        do { try store?.write(updated, name: "device"); device = updated }
        catch { self.error = .init(error: error) }
    }
    private var tick: Timer?
    private var syncTimer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var target: InputTarget?
    private var runSettings: SharedSettings?
    /// The running take's mode; the compact HUD shows it while recording.
    @Published private(set) var runMode: WritingMode = .polish
    private var runSelection = ""
    private var runSpeechKey = ""
    private var runWritingKey = ""
    var showMain: (() -> Void)?
    var showHUD: (() -> Void)?
    var hideHUD: (() -> Void)?
    var busy: Bool { phase != "idle" || updater.installing }
    var recording: Bool { phase == "recording" }
    var insertionAuthorized: Bool { preview || AXIsProcessTrusted() }

    func scanAgentContext() async throws -> AgentContextScan {
        guard !preview else { return AgentContextScan() }
        let known = Set(settings.vocabulary.entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.map(AppVocabulary.automaticTermKey))
        let worker = Task.detached(priority: .utility) {
            try AgentContextScanner.scan(excluding: known)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// `source` tells agent-context discovery from on-screen extraction in the usage log.
    func filterAgentContext(_ candidates: [AgentContextCandidate], source: ModelUsageSource) async throws -> (terms: [String], model: String) {
        guard !preview else { return ([], "Preview") }
        guard let profile = settings.writing else { throw FeatureError("Choose a writing model in Models to filter vocabulary.") }
        let credential = try key(for: profile)
        let terms = try await metered(.vocabularyFilter, source: source, profile: profile) { usage in
            try await ContextVocabularyFilter.filter(candidates: candidates.map(\.text), profile: profile, key: credential,
                projectNames: Set(candidates.filter(\.isProject).map(\.text)), usage: usage)
        }
        try Task.checkCancellation()
        return (terms, profile.name)
    }

    /// Synthetic UI fixtures only; this path cannot load keys, record, or call a model.
    func prepareHUDPreview(_ name: String) {
        guard preview else { return }
        phase = "idle"; elapsed = 12; level = 0.45; hudCopied = false; error = ""; recordingLocked = false; screenContextTermCount = nil
        recordingDeviceName = "Preview microphone"
        liveTranscript = "周二下午三点开会。\n不对，把刚才的周二改成周四，时间不变。"
        hudText = "周四下午三点开会。"; result = hudText
        switch name {
        case "starting": phase = "starting"; hudKind = .compact
        case "recording": phase = "recording"; hudKind = .compact
        case "locked": phase = "recording"; hudKind = .compact; recordingLocked = true; elapsed = 83
        case "live": phase = "recording"; hudKind = .live
        case "screen-context": phase = "recording"; hudKind = .live; screenContextTermCount = 12
        case "screen-context-compact": phase = "recording"; hudKind = .compact; screenContextTermCount = 12
        case "processing": phase = "processing"; hudKind = .live
        case "failure": hudKind = .failure; hudText = liveTranscript; error = "The speech connection ended before the final result."
        case "notice": hudKind = .notice; hudText = ""; error = "Nothing to insert yet. Dictate first."
        case "long-result": hudKind = .result; hudText = Array(repeating: "这是用于检查长文本滚动的示例，不会发送到任何模型。", count: 18).joined(separator: "\n")
        default: hudKind = .result
        }
    }

    init(preview: Bool = false) {
        self.preview = preview
        screenContext.onTakeUpdate = { [weak self] take in
            guard let self, self.generation == take else { return }
            self.screenContextTermCount = self.screenContext.termCount(take: take)
        }
        screenContext.onApplicationChange = { [weak self] app in self?.screenContextApplication = app }
        if preview {
            inputDevices = [.init(id: "preview-microphone", name: "MacBook Pro Microphone")]
            defaultInputID = "preview-microphone"
            if ProcessInfo.processInfo.environment["VOICEDRAFT_PREVIEW_FIXTURES"] == "1" {
                settings.vocabulary = AppVocabulary(words: "VoiceDraft\nQwen\nSwiftUI\nBailian\nWebSocket\nmacOS\nAPI")
                settings.vocabulary.entries[2].priority = true
                settings.vocabulary.entries[6].enabled = false
                settings.vocabulary.entries[0].origin = .automatic
                settings.vocabulary.entries[3].origin = .automatic
                history = [
                    HistoryEntry(mode: .polish, original: "A sample voice note", result: "A sample voice note, ready to use.", application: "VoiceDraft Preview", duration: 12),
                    HistoryEntry(mode: .translate, original: "这是用于界面检查的示例。", result: "This is a sample for checking the interface.", application: "VoiceDraft Preview", duration: 8),
                    HistoryEntry(mode: .ask, original: "How can I organize my notes?", result: "Group related ideas and give each group a short heading.", application: "VoiceDraft Preview", duration: 5)
                ]
                history[1].date = Date().addingTimeInterval(-3600)
                history[2].date = Date().addingTimeInterval(-86400)
                // Show the whole On-screen context section in captures; nothing is read in preview.
                device.features.screenContext = true
                device.features.screenContextOCR = true
                device.features.screenContextExcludedApps = ["com.tencent.xinWeChat"]
                screenContextApplication = ScreenContextApplication(pid: 0, bundleID: "com.apple.Notes", name: "Notes")
            }
            return
        }
        do {
            let store = try LocalStore(); self.store = store
            usageLog = UsageLog(store: store)
            screenContext.diagnostics = ScreenContextDiagnosticsLog(store: store)
            settings = try store.read("settings", fallback: SharedSettings())
            try settings.validate()
            device = try store.read("device", fallback: DeviceSettings())
            history = try store.read("history", fallback: [HistoryEntry]())
            try store.removeOrphanedAudio(referenced: Set(history.compactMap(\.audioID)))
        } catch { self.error = "Could not load local data: \(error.localizedDescription)" }
        pruneHistory()
        updater.configure(device.features, preview: preview)
        showingOnboarding = !device.features.onboardingCompleted
        refreshInputDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification, NSApplication.didBecomeActiveNotification] {
            inputObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshInputDevices() }
            })
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.busy { self.pruneHistory() }
                guard self.device.autoSync, !self.busy,
                      self.page == "Studio" || self.page == "History" else { return }
                await self.sync()
            }
        }
    }

    func key(for profile: ModelProfile) throws -> String { preview ? "" : try KeychainStore.read(profile.id.uuidString) }
    func hasKey(for profile: ModelProfile) throws -> Bool { preview ? false : try KeychainStore.contains(profile.id.uuidString) }
    func syncToken() throws -> String { preview ? "" : try KeychainStore.read("sync-token") }
    func syncPassphrase() throws -> String { preview ? "" : try KeychainStore.read("sync-passphrase") }
    /// Preview-only, in memory: lets sheet captures show an inactive (deletable) profile.
    func addPreviewProfile(_ profile: ModelProfile) {
        guard preview else { return }
        settings.profiles.append(profile)
    }
    private func persistDevice() throws { try store?.write(device, name: "device") }

    func save(_ settings: SharedSettings, credential: (UUID, String)? = nil) {
        do {
            var settings = settings
            settings.profiles = settings.profiles.map(\.normalizedInput)
            settings.targetLanguage = settings.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = credential.map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            try settings.validate()
            let previousKey = try credential.map { try KeychainStore.read($0.0.uuidString) }
            do {
                if let (id, value) = credential { try KeychainStore.write(value, account: id.uuidString) }
                try store?.write(settings, name: "settings")
            } catch {
                if let (id, _) = credential, let previousKey { try? KeychainStore.write(previousKey, account: id.uuidString) }
                throw error
            }
            self.error = ""
            if settings.writing != self.settings.writing || settings.vocabulary.enabled != self.settings.vocabulary.enabled
                || settings.vocabulary.learnFromCorrections != self.settings.vocabulary.learnFromCorrections
                || settings.vocabulary.discoverFromDictation != self.settings.vocabulary.discoverFromDictation {
                stopVocabularyLearning()
            }
            self.settings = settings; device.dirty = true; try persistDevice()
            notice = "Saved on this Mac"
            if device.autoSync { Task { await sync() } }
        } catch { self.error = .init(error: error) }
    }
    func saveDevice(autoPaste: Bool, history: Bool) {
        device.autoPaste = autoPaste; device.keepHistory = history
        do { try persistDevice() } catch { self.error = .init(error: error) }
    }
    func configureSync(url: String, token: String, passphrase: String, automatic: Bool) {
        do {
            let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !syncing else { throw VoiceDraftError.message("Wait for the current sync to finish before changing the connection.") }
            _ = try SyncClient(baseURL: url, token: token)
            guard passphrase.count >= 12 else { throw VoiceDraftError.message("Choose a sync passphrase with at least 12 characters.") }
            let identity = SHA256.hash(data: Data((url + "|" + token).utf8)).map { String(format: "%02x", $0) }.joined()
            if identity != device.syncIdentity {
                device.syncRevision = 0; device.syncIdentity = identity; device.dirty = true
            }
            try KeychainStore.write(token, account: "sync-token")
            try KeychainStore.write(passphrase, account: "sync-passphrase")
            device.serverURL = url; device.autoSync = automatic
            try persistDevice(); syncStatus = "Connection saved. Sync or download to continue."
        } catch { self.error = .init(error: error) }
    }
    private func snapshot() throws -> SyncSnapshot {
        var keys: [String: String] = [:]
        for profile in settings.profiles { keys[profile.id.uuidString] = try key(for: profile) }
        return SyncSnapshot(settings: settings, credentials: keys)
    }
    private func apply(_ incoming: SyncSnapshot, revision: Int) throws {
        try incoming.validate()
        // Keep a local recovery copy before an explicit remote replacement.
        try store?.write(settings, name: "settings-before-sync")
        var old: [String: String] = [:]
        for profile in incoming.settings.profiles { old[profile.id.uuidString] = try key(for: profile) }
        do {
            for profile in incoming.settings.profiles {
                try KeychainStore.write(incoming.credentials[profile.id.uuidString] ?? "", account: profile.id.uuidString)
            }
            try store?.write(incoming.settings, name: "settings")
        } catch {
            for (id, value) in old { try? KeychainStore.write(value, account: id) }
            throw error
        }
        stopVocabularyLearning()
        settings = incoming.settings; device.syncRevision = revision; device.dirty = false
        try persistDevice()
    }
    func sync(download: Bool = false) async {
        guard !syncing, !busy else { return }
        syncing = true; defer { syncing = false }
        do {
            let client = try SyncClient(baseURL: device.serverURL, token: syncToken())
            let passphrase = try syncPassphrase()
            let before = try snapshot()
            let remote = try await client.fetch()
            guard download || remote.revision >= device.syncRevision else {
                throw VoiceDraftError.message("The server revision moved backwards. Check the server backup before downloading explicitly.")
            }
            let decoded: SyncSnapshot?
            if let envelope = remote.payload {
                decoded = try await Task.detached { try SyncCrypto.decrypt(envelope, passphrase: passphrase) }.value
            } else { decoded = nil }
            guard try snapshot() == before, !busy else {
                throw VoiceDraftError.message("Settings changed during sync. Try again.")
            }
            if download {
                guard let decoded else { throw VoiceDraftError.message("The server is empty. Upload this Mac's settings first.") }
                try apply(decoded, revision: remote.revision)
            } else if decoded == before {
                device.syncRevision = remote.revision; device.dirty = false; try persistDevice()
            } else if device.dirty {
                guard remote.revision == device.syncRevision else {
                    throw VoiceDraftError.message("Both this Mac and the server have changes. Download the server copy explicitly, then reapply local edits. Nothing was overwritten.")
                }
                let envelope = try await Task.detached { try SyncCrypto.encrypt(before, passphrase: passphrase) }.value
                let saved = try await client.upload(envelope, revision: remote.revision)
                device.syncRevision = saved.revision
                device.dirty = try snapshot() != before
                try persistDevice()
            } else if remote.revision != device.syncRevision, let decoded {
                guard page == "Studio" || page == "History" else {
                    throw VoiceDraftError.message("A server update is available. Leave the settings page to apply it automatically, or download the server copy explicitly.")
                }
                try apply(decoded, revision: remote.revision)
            }
            syncStatus = "Synced · revision \(device.syncRevision) · \(Date().formatted(.dateTime.hour().minute().locale(L10n.locale)))"
        } catch { syncStatus = .init(error: error) }
    }

    func toggle(mode override: WritingMode? = nil, external: Bool = false) {
        if recording { finish(); return }
        guard !busy else { return }
        stopCorrectionObservation()
        player?.stop(); playingAudioID = nil
        runAudio = nil; runRetainAudio = device.keepHistory && device.features.retainAudio
        if let override { mode = override }
        error = ""; notice = ""; liveTranscript = ""; hudText = ""; hudCopied = false; hudKind = .compact; screenContextTermCount = nil
        generation = UUID(); let id = generation
        target?.focusGuard?.stop()
        target = external ? TextInsertion.capture(ignoring: device.features.shortcuts, trackOpaqueFocus: true) : nil
        let targetBundleID = target.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier }
        runMode = mode; runSettings = settings.resolved(for: targetBundleID);
        if device.features.recentContext { runSettings?.recentInputContext = recentInputs.text(application: target?.name ?? "VoiceDraft") }
        runAutoPaste = device.autoPaste; runExternal = external
        runSelection = external ? (target?.selection ?? "") : selection
        do {
            if target?.secure == true { throw VoiceDraftError.message("Voice input is disabled in password fields.") }
            guard let speech = settings.speech, let writing = settings.writing else {
                throw VoiceDraftError.message("Choose your speech and writing models.")
            }
            try speech.validateForInference(); try settings.vocabulary.validate()
            if mode != .verbatim { try writing.validateForInference() }
            runSpeechKey = try key(for: speech); runWritingKey = try key(for: writing)
            guard !runSpeechKey.isEmpty else { throw FeatureError("Add a credential for your speech model in Models first.") }
            if mode != .verbatim, runWritingKey.isEmpty { throw VoiceDraftError.message("Add an API key for the writing model first.") }
            if mode == .edit && runSelection.isEmpty { throw VoiceDraftError.message("Select text in the destination app before using Edit selection.") }
        } catch { fail(error, id: id); return }
        // Starts the background AX walk (and OCR when allowed) alongside microphone startup.
        // Home takes, preview mode, excluded apps and secure fields never read the screen.
        if external, !preview, let target {
            screenContext.begin(take: id, target: target, bundleID: targetBundleID, mode: mode,
                                options: device.features, vocabulary: settings.vocabulary)
        }
        let screenGate = ContinuousClock.now.advanced(by: .milliseconds(Int(screenContext.limits.asrGateSeconds * 1000)))
        let coordinator = screenContext
        let inputDeviceID = device.inputDeviceID
        recordingDeviceName = ""; elapsed = 0; level = 0
        phase = "starting"; status = "Opening microphone…"
        showHUD?()
        if let speech = settings.speech, speech.adapter.isWebSocket {
            let feed = LiveAudioFeed(retainAudio: runRetainAudio), vocabulary = settings.vocabulary, speechKey = runSpeechKey
            liveFeed = feed
            task = Task { [self] in
                do {
                    // The recording duration is final by the time the live call returns.
                    let raw = try await metered(.speech, source: .dictationLiveSpeech, profile: speech, streamed: true, takeID: id, audioSeconds: elapsed) { usage in
                        try await SpeechClient.transcribeLive(profile: speech, key: speechKey, audio: feed.stream, vocabulary: vocabulary,
                            // Overlaps the socket handshake; never waits past t0 + 250 ms.
                            screenTerms: { await coordinator.asrTerms(take: id, until: screenGate) },
                            onReady: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try await self.beginLiveCapture(id: id, inputID: inputDeviceID, feed: feed)
                            }, onUpdate: { [weak self] text in
                                await self?.updateLiveTranscript(text, id: id)
                            }, usage: usage)
                    }
                    try Task.checkCancellation(); guard generation == id else { return }
                    guard phase == "processing", elapsed >= 0.25 else {
                        throw VoiceDraftError.message("The recording was too short. Try again.")
                    }
                    runAudio = feed.archivedWAV
                    try await deliverTranscript(raw, id: id, duration: elapsed, source: .dictationWriting)
                } catch { fail(error, id: id) }
            }
        } else {
            liveFeed = nil
            task = Task { [self] in
                do {
                    try await effects.begin(options: device.features)
                    let input = try await recorder.start(preferredID: inputDeviceID)
                    try Task.checkCancellation(); guard generation == id else { return }
                    captureDidStart(input, id: id)
                } catch { fail(error, id: id) }
            }
        }
    }
    private func beginLiveCapture(id: UUID, inputID: String?, feed: LiveAudioFeed) async throws {
        guard generation == id, phase == "starting" else { throw CancellationError() }
        try await effects.begin(options: device.features)
        let input = try await liveRecorder.start(preferredID: inputID, feed: feed)
        try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
        captureDidStart(input, id: id)
    }
    private func captureDidStart(_ input: AudioInputDevice, id: UUID) {
        recordingDeviceName = input.name; phase = "recording"; status = "Listening · speak naturally"
        if finishWhenReady { finishWhenReady = false; finish(); return }
        tick = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id, self.recording else { return }
                let failure = self.liveFeed != nil ? self.liveRecorder.failure : self.recorder.failure
                if let failure { self.fail(failure, id: id); return }
                self.elapsed = self.liveFeed != nil ? self.liveRecorder.elapsed : self.recorder.elapsed
                self.level = self.liveFeed != nil ? self.liveRecorder.level : self.recorder.level
                if self.elapsed >= 600 { self.finish() }
            }
        }
    }
    private func updateWriting(_ text: String, id: UUID) {
        guard generation == id, busy else { return }
        result = text; hudText = text
        if !text.isEmpty { liveTranscript = text; hudKind = .live }
    }
    private func updateLiveTranscript(_ text: String, id: UUID) {
        guard generation == id, busy else { return }
        liveTranscript = text
        if !text.isEmpty { hudKind = .live }
    }
    func finish() {
        guard recording, let configuration = runSettings, let speech = configuration.speech else { return }
        tick?.invalidate(); tick = nil
        elapsed = liveFeed != nil ? liveRecorder.elapsed : recorder.elapsed
        let duration = elapsed, id = generation, speechKey = runSpeechKey
        phase = "processing"; status = .init(key: F("Recognizing speech…", "正在识别语音…"))
        gesture.reset(); recordingLocked = false; heldAction = nil
        if liveFeed != nil {
            // Closing capture flushes the last PCM frame; the existing receive task waits for finals.
            stopTask = Task {
                do {
                    try await liveRecorder.stop()
                    if generation == id { effects.end(sound: device.features.sounds) }
                }
                catch { fail(error, id: id) }
            }
        } else {
            task = Task {
                do {
                    let wav = try await recorder.stop()
                    try Task.checkCancellation(); guard generation == id else { return }
                    effects.end(sound: device.features.sounds)
                    if runRetainAudio { runAudio = wav }
                    guard duration >= 0.25 else { throw VoiceDraftError.message("The recording was too short. Try again.") }
                    let screenTerms = screenContext.currentASRTerms(take: id)
                    let raw = try await metered(.speech, source: .dictationSpeech, profile: speech, takeID: id, audioSeconds: duration) { usage in
                        try await SpeechClient.transcribe(profile: speech, key: speechKey, wav: wav, vocabulary: configuration.vocabulary,
                                                          screenTerms: screenTerms, usage: usage)
                    }
                    try Task.checkCancellation(); guard generation == id else { return }
                    try await deliverTranscript(raw, id: id, duration: duration, source: .dictationWriting)
                } catch { fail(error, id: id) }
            }
        }
    }
    /// `source` names the caller's writing call site in the usage log.
    private func deliverTranscript(_ raw: String, id: UUID, duration: Double, source: ModelUsageSource) async throws {
        guard generation == id, let configuration = runSettings else { throw CancellationError() }
        // The take's screen text is dropped on every exit; reprocess and style edits have none.
        defer { screenContext.end(take: id) }
        let mode = runMode, selected = runSelection, writingKey = runWritingKey
        var destination = target
        transcript = raw; result = ""
        var output = raw
        if mode != .verbatim, let writing = configuration.writing {
            status = "Writing with \(writing.name)…"
            // Usually ready already; never waits past the take's OCR deadline.
            let screen = await screenContext.writingContext(take: id, mode: mode)
            try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
            let request = try QwenRequests.writing(profile: writing, key: writingKey, text: raw, mode: mode,
                settings: configuration, selection: selected, application: destination?.name ?? "VoiceDraft", screenContext: screen)
            do { output = try await metered(.writing, source: source, profile: writing, mode: mode, streamed: true, takeID: id) { usage in
                try await WritingClient.complete(request, profile: writing, key: writingKey, onUpdate: { [weak self] text in
                    await self?.updateWriting(text, id: id)
                }, usage: usage)
            } }
            catch {
                try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
                result = raw; hudText = raw
                saveHistory(mode: .verbatim, original: raw, output: raw, app: destination?.name ?? "VoiceDraft", duration: duration)
                throw VoiceDraftError.message("Writing failed. Your transcript is preserved. \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
        result = output
        if device.features.recentContext { recentInputs.append(output, application: destination?.name ?? "VoiceDraft") }
        recordVocabularyUsage(output)
        saveHistory(mode: mode, original: raw, output: output, app: destination?.name ?? "VoiceDraft", duration: duration)
        var delivery: TextInsertionOutcome?
        defer { destination?.focusGuard?.stop() }
        // An Electron app enabled at capture may have built its tree since; its
        // fresh value and range are what the insertion receipt observes.
        if let pending = destination, ElectronAccessibilityPolicy.shouldRetryCapture(pending: pending.accessibilityPending,
               editable: pending.editable, external: runExternal, autoPaste: runAutoPaste, ask: mode == .ask), insertionAuthorized,
           let refreshed = await TextInsertion.refreshPending(pending, ignoring: device.features.shortcuts, trackOpaqueFocus: true) {
            try Task.checkCancellation()
            guard generation == id else { refreshed.focusGuard?.stop(); throw CancellationError() }
            pending.focusGuard?.stop(); destination = refreshed
        }
        if runExternal, runAutoPaste, mode != .ask, !insertionAuthorized {
            self.error = "Enable Accessibility to paste into other apps. The result is available here."
            status = "Result ready · open VoiceDraft to copy"
        } else if let destination, destination.editable, runAutoPaste, mode != .ask {
            status = "Inserting text…"
            do {
                let outcome = try await TextInsertion.insert(output, into: destination) { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.hideHUD?()
                    if (mode == .polish || mode == .verbatim), configuration.vocabulary.learnFromCorrections {
                        self.observeCorrections(to: output, in: destination, configuration: configuration)
                    }
                }
                try Task.checkCancellation(); guard generation == id else { return }
                delivery = outcome
                switch outcome {
                case .confirmed: status = "Text inserted"
                case .sentToTerminal: status = "Paste sent to terminal"
                case .sentWithoutConfirmation: status = "Paste sent · check the input field"
                }
            } catch {
                try Task.checkCancellation(); guard generation == id else { return }
                self.error = .init(error: error); status = "Result ready · open VoiceDraft to copy"
            }
        } else { status = "Your text is ready" }
        gesture.reset(); recordingLocked = false; heldAction = nil; finishWhenReady = false
        phase = "idle"; level = 0; runSpeechKey = ""; runWritingKey = ""; liveFeed = nil
        if delivery != nil { hudKind = .compact; hideHUD?() }
        else { hudText = output; hudKind = .result; showHUD?() }
        if mode == .polish || mode == .verbatim {
            resultBeforeCorrection = output
            if let sample = VocabularyLearningSample(source: .dictation, before: raw, after: output) {
                // Terms the screen offered cannot be promoted by discovery for this take.
                learnVocabulary(from: sample, configuration: configuration, excluding: screenContext.learningExclusions(take: id))
            }
        }
    }
    @discardableResult
    func cancelActiveInput() -> Bool {
        // `busy` also includes update installation, which Escape must not cancel.
        guard phase != "idle" else { return false }
        cancel()
        return true
    }
    func cancel() {
        target?.focusGuard?.stop()
        effects.end(sound: false); gesture.reset(); recordingLocked = false; heldAction = nil; finishWhenReady = false; runAudio = nil
        player?.stop(); playingAudioID = nil
        stopCorrectionObservation()
        screenContext.end(take: generation); screenContextTermCount = nil
        generation = UUID(); task?.cancel(); stopTask?.cancel(); liveFeed?.cancel(); liveFeed = nil
        recorder.cancel(); liveRecorder.cancel(); tick?.invalidate(); tick = nil
        phase = "idle"; level = 0; status = "Cancelled"; runSpeechKey = ""; runWritingKey = ""
        liveTranscript = ""; hudText = ""; hudKind = .compact; hideHUD?()
    }
    func dismissHUD() { if busy { cancel() } else { hideHUD?() } }
    /// Escape rule: cancel an active input run; otherwise, when idle, close a visible HUD card
    /// the way its close button does. An update installation (`busy` while idle) is untouched.
    /// Returning true only consumes VoiceDraft's own local Escape; the global monitor observes.
    @discardableResult
    func handleEscape(hudVisible: Bool) -> Bool {
        if cancelActiveInput() { return true }
        guard hudVisible, !busy else { return false }
        dismissHUD()
        return true
    }
    /// A failure without transcript text uses the compact notice card.
    private var failureKind: DictationHUDKind {
        hudText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notice : .failure
    }
    func copyHUDResult() {
        guard !hudText.isEmpty, copyResult(hudText) else { return }
        hudCopied = true
        hideHUD?()
    }
    private func fail(_ error: Error, id: UUID) {
        guard generation == id else { return }
        target?.focusGuard?.stop()
        screenContext.end(take: id)
        if case SpeechRecognitionError.noSpeech = error {
            cancel()
            self.error = ""; status = "Ready when you are"
            return
        }
        effects.end(sound: device.features.sounds); gesture.reset(); recordingLocked = false; heldAction = nil; finishWhenReady = false
        if runAudio == nil { runAudio = liveFeed?.archivedWAV }
        if runAudio != nil, !(error is CancellationError) { saveHistory(mode: .verbatim, original: liveTranscript, output: liveTranscript, app: target?.name ?? "VoiceDraft", duration: elapsed) }
        runAudio = nil
        generation = UUID(); task?.cancel(); stopTask?.cancel(); liveFeed?.cancel(); liveFeed = nil
        recorder.cancel(); liveRecorder.cancel(); tick?.invalidate(); tick = nil; phase = "idle"; level = 0
        runSpeechKey = ""; runWritingKey = ""
        if error is CancellationError { status = "Cancelled"; hideHUD?() }
        else {
            self.error = .init(error: error); status = "Something needs attention"
            if hudText.isEmpty { hudText = liveTranscript }
            hudKind = failureKind; showHUD?()
        }
    }
    private func saveHistory(mode: WritingMode, original: String, output: String, app: String, duration: Double) {
        guard device.keepHistory else { return }
        var entry = HistoryEntry(mode: mode, original: original, result: output, application: app, duration: duration)
        entry.speechModel = runSettings?.speech?.model; entry.writingModel = runSettings?.writing?.model
        entry.styleName = runSettings?.styles.first { $0.prompt == runSettings?.stylePrompt }?.name
        do {
            if let runAudio, let store { entry.audioID = try store.saveAudio(runAudio) }
            self.runAudio = nil
            var updated = history; updated.insert(entry, at: 0)
            try store?.write(updated, name: "history"); history = updated
            pruneHistory()
        } catch { self.error = "Could not save history: \(error.localizedDescription)" }
    }
    func deleteHistory(_ id: UUID? = nil) {
        let removed = history.filter { id == nil || $0.id == id }
        let remaining = history.filter { entry in !removed.contains(where: { $0.id == entry.id }) }
        do {
            try store?.write(remaining, name: "history"); history = remaining
            for entry in removed { if let audioID = entry.audioID { try store?.deleteAudio(audioID) } }
            player?.stop(); playingAudioID = nil
        } catch { self.error = .init(error: error) }
    }
    @discardableResult
    func copyResult(_ text: String? = nil) -> Bool {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text ?? result, forType: .string) else {
            error = "Could not copy the result."
            return false
        }
        notice = "Copied"
        return true
    }
    func processText() {
        guard !busy, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopCorrectionObservation()
        liveTranscript = ""; hudText = ""; hudCopied = false; hideHUD?()
        generation = UUID(); let id = generation
        phase = "processing"; status = .init(key: F("Writing…", "正在写作…")); error = ""
        runAudio = nil; runSettings = settings.resolved(for: nil)
        let configuration = runSettings!, mode = mode, raw = transcript, selected = selection
        task = Task {
            do {
                guard let writing = configuration.writing else { throw VoiceDraftError.message("Choose a writing model in Models.") }
                let output: String
                if mode == .verbatim { output = raw }
                else {
                    let request = try QwenRequests.writing(profile: writing, key: key(for: writing), text: raw,
                        mode: mode, settings: configuration, selection: selected)
                    let writingKey = try key(for: writing)
                    output = try await metered(.writing, source: .studioWriting, profile: writing, mode: mode, streamed: true, takeID: id) { usage in
                        try await WritingClient.complete(request, profile: writing, key: writingKey, onUpdate: { [weak self] text in
                            await self?.updateWriting(text, id: id)
                        }, usage: usage)
                    }
                }
                try Task.checkCancellation(); guard generation == id else { return }
                result = output; phase = "idle"; status = "Your text is ready"
                saveHistory(mode: mode, original: raw, output: output, app: "VoiceDraft", duration: 0)
                if mode == .polish || mode == .verbatim {
                    resultBeforeCorrection = output
                    if let sample = VocabularyLearningSample(source: .dictation, before: raw, after: output) {
                        learnVocabulary(from: sample, configuration: configuration)
                    }
                }
            } catch { fail(error, id: id) }
        }
    }
    func editResult(_ text: String) {
        result = text
        resultCorrectionTask?.cancel()
        guard !busy, let before = resultBeforeCorrection else { return }
        let configuration = settings
        resultCorrectionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, !self.busy, self.result == text, self.resultBeforeCorrection == before else { return }
            if let sample = VocabularyLearningSample(source: .editedDictation, before: before, after: text) {
                self.learnVocabulary(from: sample, configuration: configuration)
            }
            self.resultBeforeCorrection = text
        }
    }

    private func stopCorrectionObservation() {
        correctionObservationTask?.cancel(); correctionObservationTask = nil
        resultCorrectionTask?.cancel(); resultCorrectionTask = nil; resultBeforeCorrection = nil
    }
    private func stopVocabularyLearning() {
        vocabularyLearningID = UUID(); vocabularyLearningTask?.cancel(); vocabularyLearningTask = nil
        vocabularyDiscoveries = VocabularyDiscoveryTracker()
        stopCorrectionObservation(); vocabularyLearningStatus = ""
    }
    private func observeCorrections(to output: String, in target: InputTarget, configuration: SharedSettings) {
        guard !preview, settings.vocabulary.enabled, settings.vocabulary.learnFromCorrections,
              !target.keyboardSurface, !target.secure else { return }
        correctionObservationTask?.cancel()
        correctionObservationTask = Task { [weak self] in
            await TextInsertion.observeCorrections(to: output, in: target) { [weak self] sample in
                self?.learnVocabulary(from: sample, configuration: configuration)
            }
        }
    }
    private func learnVocabulary(from sample: VocabularyLearningSample, configuration: SharedSettings, excluding: Set<String> = []) {
        let corrections = configuration.vocabulary.learnFromCorrections && settings.vocabulary.learnFromCorrections
        let discovery = configuration.vocabulary.discoverFromDictation && settings.vocabulary.discoverFromDictation && sample.source == .dictation
        let correction = corrections && (sample.source == .editedDictation || sample.hasSpokenCorrection)
        // Corrections are never prefiltered; discovery-only takes skip the model call
        // (and its usage-log line) when the local prefilter finds nothing term-like.
        guard !preview, configuration.vocabulary.enabled, settings.vocabulary.enabled,
              correction || (discovery && VocabularyLearningPrefilter.shouldClassify(sample)),
              let profile = configuration.writing, settings.writing == profile else { return }
        vocabularyLearningTask?.cancel()
        let id = UUID(), takeID = generation; vocabularyLearningID = id
        vocabularyLearningStatus = ""
        vocabularyLearningTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try QwenRequests.vocabularyLearning(profile: profile, key: self.key(for: profile), sample: sample)
                let learningKey = try self.key(for: profile)
                let response = try await self.metered(.learning, source: .vocabularyLearning, profile: profile, takeID: takeID) { usage in
                    try await WritingClient.complete(request, profile: profile, key: learningKey, usage: usage)
                }
                try Task.checkCancellation()
                guard self.vocabularyLearningID == id, self.settings.writing == profile,
                      self.settings.vocabulary.enabled else { return }
                // Merge into current settings, never the capture-time snapshot. Disabled
                // entries and deletion suppression also cover in-flight responses.
                var updated = self.settings
                var added = corrections ? updated.vocabulary.learn(VocabularyLearning.terms(from: response, sample: sample)) : []
                if discovery, updated.vocabulary.discoverFromDictation {
                    let candidates = VocabularyLearning.discoveries(from: response, sample: sample)
                    let confirmed = self.vocabularyDiscoveries.confirmed(candidates, takeID: takeID, excluding: excluding)
                    added += updated.vocabulary.learn(confirmed, fromDiscovery: true)
                }
                guard !added.isEmpty else { return }
                try updated.validate()
                try self.store?.write(updated, name: "settings")
                self.settings = updated; self.device.dirty = true
                try self.persistDevice()
                self.vocabularyLearningStatus = D("Added to vocabulary:") + " " + added.joined(separator: ", ")
                if self.device.autoSync { await self.sync() }
            } catch {
                guard !(error is CancellationError), self.vocabularyLearningID == id else { return }
                // Learning is optional: never turn a completed dictation into a failure.
                self.vocabularyLearningStatus = D("Could not learn words this time. Your dictation is unaffected.")
            }
        }
    }
}

extension AppState {
    func saveFeatures(_ options: DesktopOptions) {
        guard !busy else { return }
        do {
            try options.validate()
            if options.shortcuts != device.features.shortcuts { try configureShortcuts?(options.shortcuts) }
            var updated = device; updated.features = options
            do { try store?.write(updated, name: "device") }
            catch { try? configureShortcuts?(device.features.shortcuts); throw error }
            let previous = device.features
            if (previous.screenContext && !options.screenContext) || (previous.screenContextOCR && !options.screenContextOCR)
                || previous.screenContextExcludedApps != options.screenContextExcludedApps {
                screenContext.clearCache()
            }
            device = updated
            updater.configure(options, preview: preview)
            if !options.recentContext { recentInputs.clear() }
            pruneHistory(); notice = "Saved on this Mac"
        } catch { self.error = .init(error: error) }
    }
    func clearRecentContext() { recentInputs.clear(); notice = "Saved on this Mac" }
    /// "Extract from this screen" for Vocabulary's review sheet. Preview mode never reads the screen.
    func scanScreenContext(app: ScreenContextApplication) async throws -> ScreenContextScan {
        guard !preview else { return ScreenContextScan(applicationName: app.name) }
        return try await screenContext.extract(app: app, options: device.features, vocabulary: settings.vocabulary)
    }
    /// Status menu "Extract words from this screen…". The menu does not activate
    /// VoiceDraft, so the frontmost app is still the one the user was reading.
    func extractFromScreen() {
        guard !busy else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == own ? nil : ScreenContextApplication($0) }
        if let app = front ?? screenContextApplication { screenExtractionRequest = ScreenExtractionRequest(app: app) }
        page = "Vocabulary"; showMain?()
    }
    func completeOnboarding() {
        var options = device.features; options.onboardingCompleted = true; saveFeatures(options)
        showingOnboarding = false
    }
    func shortcutEvent(_ action: ShortcutAction, down: Bool) {
        // A held Fn chord retargeted to a non-recording action still finishes
        // its take on release, so that release takes the gesture path below.
        let releasesTake = !down && heldAction == action
        if action == .insertLast, !releasesTake {
            // Act on release; the modifiers are then awaited separately before pasting.
            if !down { insertLastResult() }
            return
        }
        if action == .styleSelection, !releasesTake {
            if down && !busy { chooseSelectionStyle?() }
            return
        }
        let effect: RecordingGesture.Effect
        if down {
            guard heldAction == nil || heldAction == action else { return }
            heldAction = action
            effect = gesture.press(at: ProcessInfo.processInfo.systemUptime, idle: !busy)
        } else {
            guard heldAction == action else { return }
            effect = gesture.release(at: ProcessInfo.processInfo.systemUptime, active: recording || phase == "starting")
            heldAction = nil
        }
        recordingLocked = gesture.locked
        switch effect {
        case .none:
            // A press during the previous take's writing or insertion is ignored by the
            // gesture; show the Processing capsule so the shortcut does not look dead.
            if down, phase == "processing" { status = "Still finishing the previous take…"; showHUD?() }
        case .start:
            toggle(mode: action.recordingMode ?? .polish, external: true)
        case .finish:
            if phase == "starting" { finishWhenReady = true } else { finish() }
        }
    }
    /// The held Fn chord now selects `to` while the take started by `from` is
    /// still held (see `FnChordTracker`). The held key always moves to `to`, so
    /// Fn's release finishes the take. The mode changes only while the take is
    /// starting or recording and `TakeRetargetPolicy` allows it; otherwise the
    /// current mode stays and a refused switch explains itself in `status`.
    /// Audio, screen context, HUD, gesture timing and `generation` continue.
    /// A tap-locked take has no held key, so it never retargets.
    func retargetShortcut(from: ShortcutAction, to: ShortcutAction) {
        guard heldAction == from, from != to else { return }
        heldAction = to
        guard phase == "starting" || recording, let mode = to.recordingMode, mode != runMode else { return }
        switch TakeRetargetPolicy.problem(to: to, selection: runSelection, writingKey: runWritingKey) {
        case .needsSelection?: status = "Select text in the destination app before using Edit selection."; return
        case .needsWritingKey?: status = "Add an API key for the writing model first."; return
        case .notRecording?: return
        case nil: break
        }
        runMode = mode; self.mode = mode
        // The tap-versus-hold window restarts at the chord, so a quick release locks the promoted take.
        gesture.retarget(at: ProcessInfo.processInfo.systemUptime)
        screenContext.retarget(take: generation, mode: mode)
    }
    /// Inserts the last result (`result`, from a recording or Studio) again into
    /// whichever input is focused now, through the normal insertion pipeline.
    /// This is not a new take: no history entry, recent context, vocabulary
    /// learning or correction observation. It never starts a recording.
    func insertLastResult() {
        guard !busy else { return }
        let text = result
        notice = ""; hudCopied = false
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = .init(error: VoiceDraftError.message("Nothing to insert yet. Dictate first."))
            hudText = ""; hudKind = .notice; showHUD?()
            return
        }
        error = ""
        generation = UUID(); let id = generation
        phase = "processing"; status = "Inserting text…"
        task = Task { [self] in
            // The hotkey's Control/Option (or any modifier) can still be held after
            // its key is released; a paste sent now could arrive as ⌃⌥⌘V.
            let released = await Self.waitForModifierRelease()
            guard generation == id, !Task.isCancelled else { return }
            guard released else {
                reinsertFallback(text, id: id, error: VoiceDraftError.message("Shortcut keys were still held, so nothing was pasted. Copy the result instead."))
                return
            }
            guard !preview, insertionAuthorized else {
                reinsertFallback(text, id: id, error: VoiceDraftError.message("Enable Accessibility to paste into other apps. The result is available here."))
                return
            }
            var destination = TextInsertion.capture(ignoring: device.features.shortcuts, trackOpaqueFocus: true)
            defer { destination?.focusGuard?.stop() }
            // A first enable can take a couple of seconds to build an Electron tree.
            if let pending = destination, pending.accessibilityPending, !pending.editable,
               let refreshed = await TextInsertion.refreshPending(pending, ignoring: device.features.shortcuts, trackOpaqueFocus: true) {
                guard generation == id, !Task.isCancelled else { refreshed.focusGuard?.stop(); return }
                pending.focusGuard?.stop(); destination = refreshed
            }
            guard let destination, destination.editable else {
                reinsertFallback(text, id: id, error: VoiceDraftError.message("No text field is focused. Copy the result instead."))
                return
            }
            do {
                let outcome = try await TextInsertion.insert(text, into: destination) { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.hideHUD?()
                }
                try Task.checkCancellation(); guard generation == id else { return }
                switch outcome {
                case .confirmed: status = "Text inserted"
                case .sentToTerminal: status = "Paste sent to terminal"
                case .sentWithoutConfirmation: status = "Paste sent · check the input field"
                }
                phase = "idle"; hudKind = .compact
            } catch {
                guard !(error is CancellationError) else { return }
                reinsertFallback(text, id: id, error: error)
            }
        }
    }
    private func reinsertFallback(_ text: String, id: UUID, error: Error) {
        guard generation == id else { return }
        phase = "idle"; self.error = .init(error: error); status = "Result ready · open VoiceDraft to copy"
        hudText = text; hudCopied = false; hudKind = .result; showHUD?()
    }
    /// Polls for up to about one second until Shift, Control, Option and Command are all up.
    private static func waitForModifierRelease() async -> Bool {
        let held: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        for _ in 0..<50 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return true }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        }
        return CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }
    /// Opens the in-window settings overlay on a tab ("Settings", "Personalization", "Models", "Sync", "About", "Help").
    func openSettings(_ tab: String = "Settings") {
        settingsTab = tab; page = "Settings"
    }
    func shortcutLabel(_ action: ShortcutAction) -> String {
        device.features.shortcuts.first { $0.action == action }?.label ?? F("Disabled", "未启用")
    }
    private func pruneHistory() {
        guard device.features.retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(device.features.retentionDays) * 86400)
        let removed = history.filter { $0.date < cutoff }
        guard !removed.isEmpty else { return }
        let remaining = history.filter { $0.date >= cutoff }
        do {
            try store?.write(remaining, name: "history"); history = remaining
            for entry in removed { if let id = entry.audioID { try store?.deleteAudio(id) } }
        } catch { self.error = .init(error: error) }
    }
    func play(_ entry: HistoryEntry) {
        guard let id = entry.audioID, let store, !busy else { return }
        if playingAudioID == id && player?.isPlaying == true { player?.stop(); playingAudioID = nil; return }
        do {
            player?.stop(); player = try AVAudioPlayer(contentsOf: store.audioURL(id))
            guard player?.play() == true else { throw FeatureError("Could not play this recording.") }
            playingAudioID = id
            playbackTask?.cancel()
            playbackTask = Task { [weak self] in
                while self?.player?.isPlaying == true {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
                self?.playingAudioID = nil
            }
        } catch { self.error = .init(error: error) }
    }
    func reprocess(_ entry: HistoryEntry, transcribeAgain: Bool) {
        guard !busy else { return }
        stopCorrectionObservation(); player?.stop(); playingAudioID = nil
        generation = UUID(); let id = generation
        let configuration = settings.resolved(for: nil)
        runSettings = configuration; runAudio = nil; runMode = mode; target = nil; runExternal = false; runAutoPaste = false; runSelection = ""
        phase = "processing"; error = ""; result = ""; liveTranscript = ""; hudText = ""
        // A historical Edit needs a fresh instruction/selection; retry as dictation polish instead.
        if runMode == .edit { runMode = .polish }
        task = Task {
            do {
                guard let writing = configuration.writing else { throw FeatureError("Choose a writing model.") }
                runWritingKey = try key(for: writing)
                var raw = entry.original
                if transcribeAgain {
                    guard let audioID = entry.audioID, let store, let speech = configuration.speech else { throw FeatureError("No retained recording is available.") }
                    let wav = try Data(contentsOf: store.audioURL(audioID))
                    let speechKey = try key(for: speech)
                    raw = try await metered(.speech, source: .historyTranscribeAgain, profile: speech, takeID: id, audioSeconds: entry.duration) { usage in
                        try await SpeechClient.transcribe(profile: speech, key: speechKey, wav: wav, vocabulary: configuration.vocabulary, usage: usage)
                    }
                    if device.features.retainAudio { runAudio = wav }
                }
                try Task.checkCancellation(); guard generation == id else { return }
                // Both History actions rewrite through the same writing pass.
                try await deliverTranscript(raw, id: id, duration: entry.duration, source: .historyRewrite)
            } catch { fail(error, id: id) }
        }
    }
    func applyStyleToSelection(_ styleID: UUID?) {
        guard !busy, let destination = pendingStyleTarget else { return }
        pendingStyleTarget = nil
        guard !destination.secure, !destination.selection.isEmpty else {
            error = .init(error: FeatureError("Select editable text before applying a style.")); return
        }
        var configuration = settings.resolved(for: NSRunningApplication(processIdentifier: destination.pid)?.bundleIdentifier)
        if let style = settings.styles.first(where: { $0.id == styleID }) { configuration.stylePrompt = style.prompt }
        stopCorrectionObservation(); generation = UUID(); let id = generation
        runSettings = configuration; runAudio = nil; target = destination; runMode = .polish
        runSelection = ""; runExternal = true; runAutoPaste = true
        phase = "processing"; error = ""; hudText = ""; liveTranscript = ""; showHUD?()
        task = Task {
            do {
                guard let writing = configuration.writing else { throw FeatureError("Choose a writing model.") }
                runWritingKey = try key(for: writing)
                try await deliverTranscript(destination.selection, id: id, duration: 0, source: .styleApplyToSelection)
            } catch { fail(error, id: id) }
        }
    }
    private func recordVocabularyUsage(_ text: String) {
        let before = settings.vocabulary
        Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                var counted = before
                guard counted.recordUsage(in: text) else { return Set<UUID>() }
                return Set(zip(before.entries, counted.entries).filter { $0.useCount != $1.useCount }.map { $1.id })
            }.value
            guard let self, !counts.isEmpty else { return }
            // Merge by stable identity into current settings; never resurrect deleted terms.
            var updated = self.settings
            for i in updated.vocabulary.entries.indices where counts.contains(updated.vocabulary.entries[i].id) {
                updated.vocabulary.entries[i].useCount = min(1_000_000_000, updated.vocabulary.entries[i].useCount + 1)
            }
            do {
                try self.store?.write(updated, name: "settings"); self.settings = updated; self.device.dirty = true; try self.persistDevice()
            } catch { self.error = .init(error: error) }
        }
    }
}

extension AppState {
    /// Times one inference call and appends its usage record, success or failure.
    /// The call's result or error passes through unchanged; logging never fails a take.
    func metered<T>(_ kind: ModelUsageKind, source: ModelUsageSource, profile: ModelProfile, mode: WritingMode? = nil, streamed: Bool = false,
                    takeID: UUID? = nil, audioSeconds: @autoclosure () -> Double? = nil,
                    _ call: (@escaping @Sendable (ProviderUsage) -> Void) async throws -> T) async throws -> T {
        let collector = ProviderUsageCollector(), date = Date(), start = ContinuousClock.now
        let result: Result<T, Error>
        do { result = .success(try await call(collector.sink)) } catch { result = .failure(error) }
        let elapsed = (ContinuousClock.now - start).components
        let latency = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        var failure: Error?
        if case .failure(let error) = result { failure = error }
        usageLog.record(ModelUsageRecord(date: date, kind: kind, source: source, profile: profile, mode: mode, streamed: streamed,
                                         audioSeconds: audioSeconds(), latencyMs: latency, failure: failure,
                                         takeID: takeID, usage: collector.usage))
        return try result.get()
    }
}

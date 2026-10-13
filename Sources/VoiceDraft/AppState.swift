import AppKit
import AVFoundation
import SwiftUI
import CryptoKit
import VoiceDraftCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings = SharedSettings()
    @Published private(set) var device = DeviceSettings()
    @Published private(set) var history: [HistoryEntry] = []
    @Published var page = "Studio"
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
    private var store: LocalStore?
    let preview: Bool
    private let recorder = AudioRecorder()
    private let liveRecorder = LiveAudioRecorder()
    private var liveFeed: LiveAudioFeed?
    private var stopTask: Task<Void, Never>?
    @Published private(set) var liveTranscript = ""
    @Published private(set) var hudKind = DictationHUDKind.compact
    @Published private(set) var hudText = ""
    @Published private(set) var hudCopied = false
    private var runAutoPaste = false
    private var runExternal = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var defaultInputID: String?
    @Published private(set) var recordingDeviceName = ""
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
    private var runMode: WritingMode = .polish
    private var runSelection = ""
    private var runSpeechKey = ""
    private var runWritingKey = ""
    var showMain: (() -> Void)?
    var showHUD: (() -> Void)?
    var hideHUD: (() -> Void)?
    var busy: Bool { phase != "idle" }
    var recording: Bool { phase == "recording" }
    var insertionAuthorized: Bool { preview || AXIsProcessTrusted() }

    /// Synthetic UI fixtures only; this path cannot load keys, record, or call a model.
    func prepareHUDPreview(_ name: String) {
        guard preview else { return }
        phase = "idle"; elapsed = 12; level = 0.45; hudCopied = false; error = ""
        recordingDeviceName = "Preview microphone"
        liveTranscript = "周二下午三点开会。\n不对，把刚才的周二改成周四，时间不变。"
        hudText = "周四下午三点开会。"; result = hudText
        switch name {
        case "recording": phase = "recording"; hudKind = .compact
        case "live": phase = "recording"; hudKind = .live
        case "processing": phase = "processing"; hudKind = .live
        case "failure": hudKind = .failure; hudText = liveTranscript; error = "The speech connection ended before the final result."
        case "long-result": hudKind = .result; hudText = Array(repeating: "这是用于检查长文本滚动的示例，不会发送到任何模型。", count: 18).joined(separator: "\n")
        default: hudKind = .result
        }
    }

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            inputDevices = [.init(id: "preview-microphone", name: "MacBook Pro Microphone")]
            defaultInputID = "preview-microphone"
            if ProcessInfo.processInfo.environment["VOICEDRAFT_PREVIEW_FIXTURES"] == "1" {
                settings.vocabulary = AppVocabulary(words: "VoiceDraft\nQwen\nSwiftUI\nBailian\nWebSocket\nmacOS\nAPI")
                settings.vocabulary.entries[2].priority = true
                settings.vocabulary.entries[6].enabled = false
                history = [
                    HistoryEntry(mode: .polish, original: "A sample voice note", result: "A sample voice note, ready to use.", application: "VoiceDraft Preview", duration: 12),
                    HistoryEntry(mode: .translate, original: "这是用于界面检查的示例。", result: "This is a sample for checking the interface.", application: "VoiceDraft Preview", duration: 8),
                    HistoryEntry(mode: .ask, original: "How can I organize my notes?", result: "Group related ideas and give each group a short heading.", application: "VoiceDraft Preview", duration: 5)
                ]
                history[1].date = Date().addingTimeInterval(-3600)
                history[2].date = Date().addingTimeInterval(-86400)
            }
            return
        }
        do {
            let store = try LocalStore(); self.store = store
            settings = try store.read("settings", fallback: SharedSettings())
            try settings.validate()
            device = try store.read("device", fallback: DeviceSettings())
            history = try store.read("history", fallback: [HistoryEntry]())
        } catch { self.error = "Could not load local data: \(error.localizedDescription)" }
        refreshInputDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification, NSApplication.didBecomeActiveNotification] {
            inputObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshInputDevices() }
            })
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.device.autoSync, !self.busy,
                      self.page == "Studio" || self.page == "History" else { return }
                await self.sync()
            }
        }
    }

    func key(for profile: ModelProfile) throws -> String { preview ? "" : try KeychainStore.read(profile.id.uuidString) }
    func hasKey(for profile: ModelProfile) throws -> Bool { preview ? false : try KeychainStore.contains(profile.id.uuidString) }
    func syncToken() throws -> String { preview ? "" : try KeychainStore.read("sync-token") }
    func syncPassphrase() throws -> String { preview ? "" : try KeychainStore.read("sync-passphrase") }
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
        if let override { mode = override }
        error = ""; notice = ""; liveTranscript = ""; hudText = ""; hudCopied = false; hudKind = .compact
        generation = UUID(); let id = generation
        target = external ? TextInsertion.capture() : nil
        runMode = mode; runSettings = settings; runAutoPaste = device.autoPaste; runExternal = external
        runSelection = external ? (target?.selection ?? "") : selection
        do {
            if target?.secure == true { throw VoiceDraftError.message("Voice input is disabled in password fields.") }
            guard let speech = settings.speech, let writing = settings.writing else {
                throw VoiceDraftError.message("Choose your speech and writing models.")
            }
            try speech.validateForInference(); try settings.vocabulary.validate()
            if mode != .verbatim { try writing.validateForInference() }
            runSpeechKey = try key(for: speech); runWritingKey = try key(for: writing)
            guard !runSpeechKey.isEmpty else { throw VoiceDraftError.message("Add your Bailian API key in Models first.") }
            if mode != .verbatim, runWritingKey.isEmpty { throw VoiceDraftError.message("Add an API key for the writing model first.") }
            if mode == .edit && runSelection.isEmpty { throw VoiceDraftError.message("Select text in the destination app before using Edit selection.") }
        } catch { fail(error, id: id); return }
        let inputDeviceID = device.inputDeviceID
        recordingDeviceName = ""; elapsed = 0; level = 0
        phase = "starting"; status = "Opening microphone…"
        showHUD?()
        if let speech = settings.speech, speech.adapter == .qwenMessageWebSocket {
            let feed = LiveAudioFeed(), vocabulary = settings.vocabulary, speechKey = runSpeechKey
            liveFeed = feed
            task = Task { [self] in
                do {
                    let raw = try await SpeechClient.transcribeLive(profile: speech, key: speechKey, audio: feed.stream, vocabulary: vocabulary,
                        onReady: { [weak self] in
                            guard let self else { throw CancellationError() }
                            try await self.beginLiveCapture(id: id, inputID: inputDeviceID, feed: feed)
                        }, onUpdate: { [weak self] text in
                            await self?.updateLiveTranscript(text, id: id)
                        })
                    try Task.checkCancellation(); guard generation == id else { return }
                    guard phase == "processing", elapsed >= 0.25 else {
                        throw VoiceDraftError.message("The recording was too short. Try again.")
                    }
                    try await deliverTranscript(raw, id: id, duration: elapsed)
                } catch { fail(error, id: id) }
            }
        } else {
            liveFeed = nil
            task = Task { [self] in
                do {
                    let input = try await recorder.start(preferredID: inputDeviceID)
                    try Task.checkCancellation(); guard generation == id else { return }
                    captureDidStart(input, id: id)
                } catch { fail(error, id: id) }
            }
        }
    }
    private func beginLiveCapture(id: UUID, inputID: String?, feed: LiveAudioFeed) async throws {
        guard generation == id, phase == "starting" else { throw CancellationError() }
        let input = try await liveRecorder.start(preferredID: inputID, feed: feed)
        try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
        captureDidStart(input, id: id)
    }
    private func captureDidStart(_ input: AudioInputDevice, id: UUID) {
        recordingDeviceName = input.name; phase = "recording"; status = "Listening · speak naturally"
        tick = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id, self.recording else { return }
                let failure = self.liveFeed != nil ? self.liveRecorder.failure : self.recorder.failure
                if let failure { self.fail(failure, id: id); return }
                self.elapsed = self.liveFeed != nil ? self.liveRecorder.elapsed : self.recorder.elapsed
                self.level = self.liveFeed != nil ? self.liveRecorder.level : self.recorder.level
                if self.elapsed >= 240 { self.finish() }
            }
        }
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
        phase = "processing"; status = "Recognizing with Qwen…"
        if liveFeed != nil {
            // Closing capture flushes the last PCM frame; the existing receive task waits for finals.
            stopTask = Task {
                do { try await liveRecorder.stop() }
                catch { fail(error, id: id) }
            }
        } else {
            task = Task {
                do {
                    let wav = try await recorder.stop()
                    try Task.checkCancellation(); guard generation == id else { return }
                    guard duration >= 0.25 else { throw VoiceDraftError.message("The recording was too short. Try again.") }
                    let raw = try await SpeechClient.transcribe(profile: speech, key: speechKey, wav: wav, vocabulary: configuration.vocabulary)
                    try Task.checkCancellation(); guard generation == id else { return }
                    try await deliverTranscript(raw, id: id, duration: duration)
                } catch { fail(error, id: id) }
            }
        }
    }
    private func deliverTranscript(_ raw: String, id: UUID, duration: Double) async throws {
        guard generation == id, let configuration = runSettings else { throw CancellationError() }
        let mode = runMode, selected = runSelection, destination = target, writingKey = runWritingKey
        transcript = raw; result = ""
        var output = raw
        if mode != .verbatim, let writing = configuration.writing {
            status = "Writing with \(writing.name)…"
            let request = try QwenRequests.writing(profile: writing, key: writingKey, text: raw, mode: mode,
                settings: configuration, selection: selected, application: destination?.name ?? "VoiceDraft")
            do { output = try await HTTPTransport().complete(request) }
            catch {
                try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
                result = raw; hudText = raw
                saveHistory(mode: .verbatim, original: raw, output: raw, app: destination?.name ?? "VoiceDraft", duration: duration)
                throw VoiceDraftError.message("Writing failed. Your transcript is preserved. \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
        result = output
        saveHistory(mode: mode, original: raw, output: output, app: destination?.name ?? "VoiceDraft", duration: duration)
        var inserted = false
        if runExternal, runAutoPaste, mode != .ask, !insertionAuthorized {
            self.error = "Enable Accessibility to paste into other apps. The result is available here."
            status = "Result ready · open VoiceDraft to copy"
        } else if let destination, destination.editable, runAutoPaste, mode != .ask {
            status = "Inserting text…"
            do {
                try await TextInsertion.insert(output, into: destination)
                try Task.checkCancellation(); guard generation == id else { return }
                inserted = true; status = "Text inserted"
            } catch {
                try Task.checkCancellation(); guard generation == id else { return }
                self.error = .init(error: error); status = "Result ready · open VoiceDraft to copy"
            }
        } else { status = "Your text is ready" }
        phase = "idle"; level = 0; runSpeechKey = ""; runWritingKey = ""; liveFeed = nil
        if inserted { hudKind = .compact; closeHUDAfterDelay(id: id) }
        else { hudText = output; hudKind = .result; showHUD?() }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); stopTask?.cancel(); liveFeed?.cancel(); liveFeed = nil
        recorder.cancel(); liveRecorder.cancel(); tick?.invalidate(); tick = nil
        phase = "idle"; level = 0; status = "Cancelled"; runSpeechKey = ""; runWritingKey = ""
        liveTranscript = ""; hudText = ""; hudKind = .compact; hideHUD?()
    }
    func dismissHUD() { if busy { cancel() } else { hideHUD?() } }
    func copyHUDResult() { copyResult(hudText); hudCopied = true }
    private func fail(_ error: Error, id: UUID) {
        guard generation == id else { return }
        generation = UUID(); task?.cancel(); stopTask?.cancel(); liveFeed?.cancel(); liveFeed = nil
        recorder.cancel(); liveRecorder.cancel(); tick?.invalidate(); tick = nil; phase = "idle"; level = 0
        runSpeechKey = ""; runWritingKey = ""
        if error is CancellationError { status = "Cancelled"; hideHUD?() }
        else {
            self.error = .init(error: error); status = "Something needs attention"
            if hudText.isEmpty { hudText = liveTranscript }
            hudKind = .failure; showHUD?()
        }
    }
    private func closeHUDAfterDelay(id: UUID) {
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); if generation == id && !busy { hideHUD?() } }
    }
    private func saveHistory(mode: WritingMode, original: String, output: String, app: String, duration: Double) {
        guard device.keepHistory else { return }
        history.insert(HistoryEntry(mode: mode, original: original, result: output, application: app, duration: duration), at: 0)
        history = Array(history.prefix(500))
        do { try store?.write(history, name: "history") } catch { self.error = "Could not save history: \(error.localizedDescription)" }
    }
    func deleteHistory(_ id: UUID? = nil) {
        if let id { history.removeAll { $0.id == id } } else { history.removeAll() }
        do { try store?.write(history, name: "history") } catch { self.error = .init(error: error) }
    }
    func copyResult(_ text: String? = nil) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text ?? result, forType: .string)
        notice = "Copied"
    }
    func processText() {
        guard !busy, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        liveTranscript = ""; hudText = ""; hudCopied = false; hideHUD?()
        generation = UUID(); let id = generation
        phase = "processing"; status = "Writing with Qwen…"; error = ""
        let configuration = settings, mode = mode, raw = transcript, selected = selection
        task = Task {
            do {
                guard let writing = configuration.writing else { throw VoiceDraftError.message("Choose a writing model in Models.") }
                let output: String
                if mode == .verbatim { output = raw }
                else {
                    let request = try QwenRequests.writing(profile: writing, key: key(for: writing), text: raw,
                        mode: mode, settings: configuration, selection: selected)
                    output = try await HTTPTransport().complete(request)
                }
                try Task.checkCancellation(); guard generation == id else { return }
                result = output; phase = "idle"; status = "Your text is ready"
                saveHistory(mode: mode, original: raw, output: output, app: "VoiceDraft", duration: 0)
            } catch { fail(error, id: id) }
        }
    }
}

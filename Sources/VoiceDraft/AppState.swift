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

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            inputDevices = [.init(id: "preview-microphone", name: "MacBook Pro Microphone")]
            defaultInputID = "preview-microphone"
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
        error = ""; notice = ""
        target = external ? TextInsertion.capture() : nil
        if target?.secure == true { error = "Voice input is disabled in password fields."; showMain?(); return }
        runMode = mode; runSettings = settings
        runSelection = external ? (target?.selection ?? "") : selection
        do {
            guard let speech = settings.speech, let writing = settings.writing else {
                throw VoiceDraftError.message("Choose your speech and writing models.")
            }
            try speech.validateForInference()
            try settings.vocabulary.validate()
            if mode != .verbatim { try writing.validateForInference() }
            runSpeechKey = try key(for: speech); runWritingKey = try key(for: writing)
            guard !runSpeechKey.isEmpty else { throw VoiceDraftError.message("Add your Bailian API key in Models first.") }
            if mode != .verbatim, runWritingKey.isEmpty { throw VoiceDraftError.message("Add an API key for the writing model first.") }
            if mode == .edit && runSelection.isEmpty { throw VoiceDraftError.message("Select text in the destination app before using Edit selection.") }
        } catch { self.error = .init(error: error); showMain?(); return }
        let inputDeviceID = device.inputDeviceID
        recordingDeviceName = ""
        phase = "starting"; status = "Opening microphone…"; elapsed = 0
        generation = UUID(); let id = generation
        showHUD?()
        task = Task { [self] in
            do {
                let input = try await recorder.start(preferredID: inputDeviceID)
                guard generation == id else { return }
                recordingDeviceName = input.name
                phase = "recording"; status = "Listening · speak naturally"
                tick = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.recording else { return }
                        if let failure = self.recorder.failure { self.fail(failure, id: id); return }
                        self.elapsed = self.recorder.elapsed; self.level = self.recorder.level
                        if self.elapsed >= 240 { self.finish() }
                    }
                }
            } catch { fail(error, id: id) }
        }
    }
    func finish() {
        guard recording, let configuration = runSettings, let speech = configuration.speech else { return }
        tick?.invalidate(); tick = nil; elapsed = recorder.elapsed
        let duration = elapsed, id = generation, mode = runMode, selected = runSelection, destination = target
        let speechKey = runSpeechKey, writingKey = runWritingKey
        phase = "processing"; status = "Recognizing with Qwen…"
        task = Task {
            do {
                let wav = try await recorder.stop()
                try Task.checkCancellation(); guard generation == id else { return }
                guard duration >= 0.25 else { throw VoiceDraftError.message("The recording was too short. Try again.") }
                let raw = try await SpeechClient.transcribe(profile: speech, key: speechKey, wav: wav, vocabulary: configuration.vocabulary)
                try Task.checkCancellation(); guard generation == id else { return }
                transcript = raw; result = ""
                var output = raw
                if mode != .verbatim, let writing = configuration.writing {
                    status = "Writing with \(writing.name)…"
                    let request = try QwenRequests.writing(profile: writing, key: writingKey, text: raw, mode: mode,
                        settings: configuration, selection: selected, application: destination?.name ?? "VoiceDraft")
                    do { output = try await HTTPTransport().complete(request) }
                    catch {
                        guard !Task.isCancelled else { throw CancellationError() }
                        result = raw
                        saveHistory(mode: .verbatim, original: raw, output: raw, app: destination?.name ?? "VoiceDraft", duration: duration)
                        throw VoiceDraftError.message("Writing failed. Your transcript is preserved. \(error.localizedDescription)")
                    }
                }
                try Task.checkCancellation(); guard generation == id else { return }
                result = output
                saveHistory(mode: mode, original: raw, output: output, app: destination?.name ?? "VoiceDraft", duration: duration)
                if let destination, device.autoPaste, mode != .ask {
                    status = "Inserting text…"
                    do {
                        try await TextInsertion.insert(output, into: destination)
                        guard generation == id else { return }
                        status = "Text inserted"
                    } catch {
                        guard generation == id else { return }
                        self.error = .init(error: error); status = "Result ready · open VoiceDraft to copy"
                    }
                } else {
                    status = "Your text is ready"
                    if mode == .ask { page = "Studio"; showMain?() }
                }
                phase = "idle"; level = 0; runSpeechKey = ""; runWritingKey = ""
                closeHUDAfterDelay(id: id)
            } catch { fail(error, id: id) }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); recorder.cancel(); tick?.invalidate(); tick = nil
        phase = "idle"; level = 0; status = "Cancelled"; runSpeechKey = ""; runWritingKey = ""; hideHUD?()
    }
    private func fail(_ error: Error, id: UUID) {
        guard generation == id else { return }
        recorder.cancel(); tick?.invalidate(); tick = nil; phase = "idle"; level = 0
        runSpeechKey = ""; runWritingKey = ""
        if error is CancellationError { status = "Cancelled" }
        else { self.error = .init(error: error); status = "Something needs attention"; showMain?() }
        closeHUDAfterDelay(id: id)
    }
    private func closeHUDAfterDelay(id: UUID) {
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if generation == id && !busy { hideHUD?() } }
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

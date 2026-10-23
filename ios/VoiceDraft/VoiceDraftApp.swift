import SwiftUI
import VoiceDraftCore

@main
struct VoiceDraftApp: App {
    @StateObject private var model: AppModel

    init() {
        // The app and the keyboard read the interface language from the same app-group suite.
        L10n.defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        let isolated = isTesting || StandbyDeviceProbe.enabled
        #else
        let isolated = isTesting
        #endif
        _model = StateObject(wrappedValue: isolated ? AppModel.preview() : AppModel())
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if StandbyDeviceProbe.enabled {
                StandbyDeviceProbe()
            } else {
                RootView().environmentObject(model)
            }
            #else
            RootView().environmentObject(model)
            #endif
        }
    }
}

extension AppModel {
    /// In-memory model with no microphone, Keychain, files or notifications. Used by previews and as the
    /// test host's model so hosted tests never touch real state.
    static func preview() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceDraftPreview-\(UUID().uuidString)")
        let store = try? IOSLocalStore(directory: directory)
        return AppModel(dependencies: .init(
            store: store, credentials: InMemoryCredentialStore(),
            statusStore: AppStatusStore(fileURL: directory.appendingPathComponent(AppStatusStore.fileName)),
            resultStore: SharedResultStore(fileURL: directory.appendingPathComponent(SharedResultStore.fileName)),
            presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent(KeyboardPresenceStore.fileName)),
            audio: SilentAudioCapture(), keepAlive: SilentStandbyKeepAlive(), usageLog: IOSUsageLog(directory: nil), post: { _ in }, observeKeyboard: false))
    }
}

/// Shared order of audio calls across the fakes, so tests can assert the standby switch ordering.
final class AudioJournal {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

/// An audio source that never produces audio, for previews and tests.
final class SilentAudioCapture: AudioCapturing {
    var journal: AudioJournal?
    var onPCM: ((Data) -> Void)?
    var onInterruption: ((Error) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0
    /// Set to make the next `start` throw, like iOS refusing to record in the background.
    var startError: Error?
    /// Whether the last `stop` kept the audio session active.
    private(set) var lastStopKeptSession = false
    func start() async throws {
        if let error = startError { throw error }
        isRunning = true
        startCount += 1
        journal?.record("mic.start")
    }
    func stop(keepingSessionActive: Bool) {
        isRunning = false
        lastStopKeptSession = keepingSessionActive
        journal?.record(keepingSessionActive ? "mic.stop(keep)" : "mic.stop(deactivate)")
    }
}

/// A standby keep-alive with no audio, for previews and tests. Tests raise session events through `send`.
final class SilentStandbyKeepAlive: StandbyKeepAlive {
    var journal: AudioJournal?
    var onEvent: ((StandbyAudioEvent) -> Void)?
    private(set) var isRunning = false
    var ready = true
    var isReadyForBackground: Bool { isRunning && ready }
    var prepared: Bool?
    var isPreparedForBackgroundTransition: Bool { isRunning && (prepared ?? ready) }
    private(set) var startCount = 0
    /// Set to make the next `start` throw.
    var startError: Error?
    private(set) var lastStopDeactivated = false
    /// Whether the last `setRecording` said a take is recording.
    private(set) var recording = false
    func start() throws {
        if let error = startError { throw error }
        isRunning = true
        startCount += 1
        journal?.record("keepalive.start")
    }
    func stop(deactivatingSession: Bool) {
        isRunning = false
        lastStopDeactivated = deactivatingSession
        journal?.record(deactivatingSession ? "keepalive.stop(deactivate)" : "keepalive.stop(keep)")
    }
    func setRecording(_ recording: Bool) { self.recording = recording }
    /// What the system would do on this event (the window closing stops the keep-alive; an interruption or reset
    /// leaves the window up), then the notification.
    func send(_ event: StandbyAudioEvent) {
        switch event {
        case .keepAliveEnded, .keepAliveFailed: isRunning = false
        default: break
        }
        onEvent?(event)
    }
}

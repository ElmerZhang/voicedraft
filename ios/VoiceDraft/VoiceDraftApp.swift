import SwiftUI
import VoiceDraftCore

@main
struct VoiceDraftApp: App {
    @StateObject private var model: AppModel

    init() {
        // The app and the keyboard read the interface language from the same app-group suite.
        L10n.defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _model = StateObject(wrappedValue: isTesting ? AppModel.preview() : AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
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
            audio: SilentAudioCapture(), usageLog: IOSUsageLog(directory: nil), post: { _ in }, observeKeyboard: false))
    }
}

/// An audio source that never produces audio, for previews and tests.
final class SilentAudioCapture: AudioCapturing {
    var onPCM: ((Data) -> Void)?
    var onInterruption: ((Error) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0
    func start() async throws { isRunning = true; startCount += 1 }
    func stop() { isRunning = false }
}

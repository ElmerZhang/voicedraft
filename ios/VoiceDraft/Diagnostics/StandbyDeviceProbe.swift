#if DEBUG
import AVFoundation
import SwiftUI
import VoiceDraftCore

/// Explicit local hardware probe. Uses no model, credentials, history or provider. PCM is discarded.
struct StandbyDeviceProbe: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--standby-device-probe") }
    @StateObject private var probe = Probe()

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--probe-keyboard-host") {
            KeyboardHostField().frame(height: 48).padding()
        } else {
            Text(verbatim: "VoiceDraft standby device probe\nNo recognition or network requests")
                .padding()
                .task { await probe.run() }
        }
    }

    private struct KeyboardHostField: UIViewRepresentable {
        func makeUIView(context: Context) -> UITextField {
            let field = UITextField()
            field.placeholder = "VoiceDraft keyboard host probe"
            field.borderStyle = .roundedRect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak field] in field?.becomeFirstResponder() }
            return field
        }
        func updateUIView(_ uiView: UITextField, context: Context) {}
    }

    @MainActor
    final class Probe: ObservableObject {
        private let session = IOSAudioSessionController()
        private lazy var keepAlive = IOSPictureInPictureKeepAlive(sessionController: session)
        private lazy var audio = IOSAudioCapture(sessionController: session)
        private var started = false
        private let counter = ByteCounter()

        func run() async {
            guard !started else { return }
            started = true
            KeyboardDiagnostics.record("probe.begin")
            if ProcessInfo.processInfo.arguments.contains("--probe-model-return") {
                await checkModelReturn()
                return
            }
            audio.onPCM = { [counter] data in counter.add(data.count) }
            if ProcessInfo.processInfo.arguments.contains("--probe-built-in-microphone") {
                do {
                    try session.activate()
                    let shared = AVAudioSession.sharedInstance()
                    if let input = shared.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                        try shared.setPreferredInput(input)
                        KeyboardDiagnostics.record("probe.route", "preferred=builtInMic")
                    }
                } catch { KeyboardDiagnostics.record("probe.route.failed", KeyboardDiagnostics.error(error)) }
            }
            keepAlive.onEvent = { event in KeyboardDiagnostics.record("probe.event", "\(event)") }
            try? await Task.sleep(for: .seconds(1))
            if ProcessInfo.processInfo.arguments.contains("--probe-prime-microphone") {
                do {
                    try await audio.start()
                    try? await Task.sleep(for: .seconds(2))
                    KeyboardDiagnostics.record("probe.foreground", "pcmBytes=\(counter.take())")
                    audio.stop(keepingSessionActive: true)
                } catch { KeyboardDiagnostics.record("probe.foreground.failed", AudioStepError.describe(error)) }
            }
            do { try keepAlive.start() }
            catch { KeyboardDiagnostics.record("probe.start.failed", KeyboardDiagnostics.error(error)); return }
            let longIntervals = ProcessInfo.processInfo.arguments.contains("--probe-visual")
            if ProcessInfo.processInfo.arguments.contains("--probe-return-settings") {
                let delay = ProcessInfo.processInfo.arguments.contains("--probe-delayed-return") ? 8 : 3
                try? await Task.sleep(for: .seconds(delay))
                let result = VDHostNavigation.returnToHost("com.apple.Preferences", application: UIApplication.shared)
                KeyboardDiagnostics.record("probe.return", result)
            }
            // Without --probe-return-settings the operator must put another app in the foreground.
            for attempt in 1...2 {
                let idle = ProcessInfo.processInfo.arguments.contains("--probe-long-standby") && attempt == 1
                    ? 90 : (longIntervals ? 15 : (attempt == 1 ? 10 : 3))
                try? await Task.sleep(for: .seconds(idle))
                KeyboardDiagnostics.record("probe.mic.attempt", "\(attempt) appState=\(UIApplication.shared.applicationState.rawValue)")
                do {
                    try await audio.start()
                    KeyboardDiagnostics.record("probe.mic.started", "\(attempt)")
                    try? await Task.sleep(for: .seconds(longIntervals ? 15 : 2))
                    audio.stop(keepingSessionActive: true)
                    KeyboardDiagnostics.record("probe.mic.stopped", "\(attempt) running=\(audio.isRunning) pcmBytes=\(counter.take())")
                } catch { KeyboardDiagnostics.record("probe.mic.failed", AudioStepError.describe(error)) }
            }
            if longIntervals { try? await Task.sleep(for: .seconds(15)) }
            keepAlive.stop(deactivatingSession: true)
            KeyboardDiagnostics.record("probe.end")
        }

        /// Runs the real model's cold-handoff scheduling with temporary state and placeholder keys.
        /// HTTP-only, always cancelled (never stopped/transcribed), so no provider request can be made.
        private func checkModelReturn() async {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReturnProbe-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let store = try IOSLocalStore(directory: directory)
                let settings = try store.loadSettings()
                guard let speech = settings.speech, !speech.adapter.isWebSocket else { return }
                try store.saveSettings(settings)
                let credentials = InMemoryCredentialStore()
                try credentials.write("probe-placeholder", account: CredentialAccount.profile(settings.speechID))
                try credentials.write("probe-placeholder", account: CredentialAccount.profile(settings.writingID))
                let pending = PendingTakeStore(fileURL: directory.appendingPathComponent("pending.json"))
                let meter = RecordingMeterStore(fileURL: directory.appendingPathComponent("meter.json"))
                let request = PendingTake(hostBundleIdentifier: "com.apple.Preferences")
                try pending.write(request)
                let model = AppModel(dependencies: .init(
                    store: store, credentials: credentials,
                    statusStore: AppStatusStore(fileURL: directory.appendingPathComponent("status.json")),
                    resultStore: SharedResultStore(fileURL: directory.appendingPathComponent("result.json")),
                    presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent("presence.json")),
                    audio: audio, keepAlive: keepAlive, usageLog: IOSUsageLog(directory: nil), post: { _ in },
                    observeKeyboard: false, pendingTakeStore: pending,
                    returnToHost: { VDHostNavigation.returnToHost($0, application: UIApplication.shared) },
                    meterStore: meter))
                try? await Task.sleep(for: .seconds(1))
                model.receiveRecordLink(KeyboardRecordLink.url(for: request)!)
                KeyboardDiagnostics.record("probe.model.started", "state=\(model.takeState) error=\(model.errorMessage.key)")
                var levels: [Double] = []
                var sampleTimes = Set<TimeInterval>()
                for _ in 0..<80 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let sample = meter.read(),
                       let level = sample.usableLevel(for: request.id, after: request.startedAt) {
                        levels.append(level)
                        sampleTimes.insert(sample.sampledAt)
                    }
                }
                KeyboardDiagnostics.record("probe.meter", "samples=\(sampleTimes.count) min=\(levels.min() ?? 0) max=\(levels.max() ?? 0)")
                KeyboardDiagnostics.record("probe.model.result", "appState=\(UIApplication.shared.applicationState.rawValue) micReady=\(audio.isReadyForRecording) pipReady=\(keepAlive.isReadyForBackground) elapsed=\(model.elapsed)")
                model.cancelTake()
                KeyboardDiagnostics.record("probe.meter.cleared", "\(meter.read() == nil)")
                model.endListening()
            } catch { KeyboardDiagnostics.record("probe.model.failed", KeyboardDiagnostics.error(error)) }
        }
    }

    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        func add(_ count: Int) { lock.withLock { bytes += count } }
        func take() -> Int { lock.withLock { defer { bytes = 0 }; return bytes } }
    }
}
#endif

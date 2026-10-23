import AVFoundation
import VoiceDraftCore

/// Microphone source for takes and listening sessions. AppModel depends on this protocol so tests can drive
/// takes without audio hardware.
protocol AudioCapturing: AnyObject {
    /// 16 kHz mono signed little-endian PCM16 chunks, delivered on the audio thread.
    var onPCM: ((Data) -> Void)? { get set }
    /// The session was interrupted or the engine stopped unexpectedly. Delivered on the main queue.
    var onInterruption: ((Error) -> Void)? { get set }
    var isRunning: Bool { get }
    var isReadyForRecording: Bool { get }
    /// Requests microphone permission, activates the shared audio session if needed and starts the input tap.
    func start() async throws
    /// Removes the tap and stops the engine. With `keepingSessionActive` the audio session stays active, as the
    /// standby Picture in Picture keep-alive requires.
    func stop(keepingSessionActive: Bool)
}

extension AudioCapturing {
    var isReadyForRecording: Bool { isRunning }
    /// Stops the microphone and deactivates the audio session.
    func stop() { stop(keepingSessionActive: false) }
}

/// An audio step that failed, named so the error text says where (for example
/// `session: setActive failed: OSStatus 561145187 '!rec'`). Shown in the app and, for standby, in the
/// keyboard's status line through `AppStatus.lastError`.
struct AudioStepError: LocalizedError {
    var step: String
    var underlying: Error

    var errorDescription: String? { "\(step) failed: \(Self.describe(underlying))" }

    /// An OSStatus as its number and four-character code when it has one, otherwise the localized description.
    static func describe(_ error: Error) -> String {
        if let step = error as? AudioStepError { return step.errorDescription ?? "" }
        let code = (error as NSError).code
        if let fourCC = fourCharacterCode(code) { return "OSStatus \(code) '\(fourCC)'" }
        return error.localizedDescription
    }

    static func fourCharacterCode(_ code: Int) -> String? {
        guard code > 0x2020_2020, code <= Int(UInt32.max) else { return nil }
        let bytes = withUnsafeBytes(of: UInt32(code).bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Runs `body` and wraps any error with `step`.
    static func run<T>(_ step: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw AudioStepError(step: step, underlying: error) }
    }
}

/// `AVAudioEngine` input tap converted with `AVAudioConverter` to the format `LiveAudioFeed` and
/// `WaveAudio` expect: 16 kHz, mono, PCM16.
///
/// Every `start` builds a new engine and every `stop` discards it (keeping one alive across the earlier standby
/// category switch failed with '!cat'). The session itself belongs to `IOSAudioSessionController`; this engine and
/// the standby keep-alive share its single `.playAndRecord` configuration, so a standby take makes no session call.
final class IOSAudioCapture: AudioCapturing {
    var onPCM: ((Data) -> Void)?
    var onInterruption: ((Error) -> Void)?
    private(set) var isRunning = false
    private(set) var isReadyForRecording = false
    private var inputSignal: AsyncStream<Void>.Continuation?
    private var starting = false
    private var generation = UUID()
    private var startupConfigurationChanged = false

    private var engine: AVAudioEngine?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private let sessionController: IOSAudioSessionController
    #if DEBUG
    private var reportedFirstBuffer = false
    #endif

    init(sessionController: IOSAudioSessionController) {
        self.sessionController = sessionController
        // These observers also cover the brief interval between startup retry engines.
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                   object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.interrupted()
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.interrupted()
        })
    }

    deinit {
        (observers + sessionObservers).forEach(NotificationCenter.default.removeObserver)
    }

    func start() async throws {
        if isRunning || starting {
            while (isRunning || starting) && !isReadyForRecording {
                try await Task.sleep(for: .milliseconds(20))
            }
            if isReadyForRecording { return }
            throw CancellationError()
        }
        starting = true
        let request = UUID()
        generation = request
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceDraftError.message("Allow microphone access for VoiceDraft in Settings > Privacy & Security > Microphone.")
        }
        try Task.checkCancellation()
        guard generation == request else { throw CancellationError() }
        // HFP can negotiate its input format only when IO starts. Rebuild the tap after that startup change,
        // keeping the session active so negotiation can finish. Once input is ready, route changes still end
        // the take. Cancellation and real interruptions invalidate the generation and never restart the mic.
        for attempt in 0...2 {
            startupConfigurationChanged = false
            do {
                try await startEngine()
                return
            } catch {
                guard startupConfigurationChanged, generation == request, !Task.isCancelled, attempt < 2 else {
                    throw error
                }
                KeyboardDiagnostics.record("mic.startup.retry", "attempt=\(attempt + 1)")
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                guard generation == request else { throw CancellationError() }
            }
        }
    }

    private func startEngine() async throws {
        let session = AVAudioSession.sharedInstance()
        // On standby the keep-alive has already configured and activated the session, so this makes no call.
        try sessionController.activate()

        let engine = AVAudioEngine()
        #if DEBUG
        reportedFirstBuffer = false
        #endif
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioStepError(step: "take: input format",
                                 underlying: VoiceDraftError.message("The microphone could not start. Check your input device."))
        }
        self.converter = converter
        let (inputStarted, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        inputSignal = signal
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            if self?.convert(buffer) == true { signal.yield(()); signal.finish() }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            signal.finish()
            inputSignal = nil
            throw AudioStepError(step: "take: engine.start", underlying: error)
        }
        self.engine = engine
        isRunning = true
        KeyboardDiagnostics.record("mic.engine.started", "inputRate=\(inputFormat.sampleRate) inputs=\(session.currentRoute.inputs.map { $0.portType.rawValue })")
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self, weak engine] _ in
            guard let self, let engine, self.engine === engine else { return }
            KeyboardDiagnostics.record("mic.configurationChanged", "ready=\(self.isReadyForRecording)")
            if self.starting, !self.isReadyForRecording {
                self.startupConfigurationChanged = true
                self.stopEngine(keepingSessionActive: true)
            } else {
                self.interrupted()
            }
        })
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in inputStarted { return }
                    throw CancellationError()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw VoiceDraftError.message("The microphone started but delivered no audio. Open VoiceDraft and try again.")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try Task.checkCancellation()
            guard self.engine === engine, isRunning else { throw CancellationError() }
            isReadyForRecording = true
        } catch {
            if self.engine === engine { stopEngine(keepingSessionActive: true) }
            throw AudioStepError(step: "take: first input buffer", underlying: error)
        }
    }

    /// Removes the tap, stops and discards the engine; the session configuration is untouched. Without
    /// `keepingSessionActive` (an in-app take, or standby ending) the session is deactivated.
    func stop(keepingSessionActive: Bool) {
        generation = UUID()
        stopEngine(keepingSessionActive: keepingSessionActive)
    }

    private func stopEngine(keepingSessionActive: Bool) {
        guard isRunning else {
            // A caller can stop while the startup retry is between engines.
            if !keepingSessionActive { sessionController.deactivate() }
            return
        }
        isRunning = false
        isReadyForRecording = false
        inputSignal?.finish()
        inputSignal = nil
        KeyboardDiagnostics.record("mic.engine.stopped")
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
        converter = nil
        if !keepingSessionActive { sessionController.deactivate() }
    }

    private func interrupted() {
        guard isRunning || starting else { return }
        stop()
        onInterruption?(VoiceDraftError.message("The microphone was interrupted. Start again when you are ready."))
    }

    /// Runs on the audio thread.
    @discardableResult
    private func convert(_ buffer: AVAudioPCMBuffer) -> Bool {
        #if DEBUG
        if !reportedFirstBuffer {
            reportedFirstBuffer = true
            let frames = buffer.frameLength
            DispatchQueue.main.async { KeyboardDiagnostics.record("mic.firstBuffer", "frames=\(frames)") }
        }
        #endif
        guard let converter, buffer.frameLength > 0 else { return false }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return false }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else { return false }
        onPCM?(Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        return true
    }
}

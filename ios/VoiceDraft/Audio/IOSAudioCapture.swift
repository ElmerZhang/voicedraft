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
    /// Requests microphone permission, activates the `.record` audio session and starts the input tap.
    func start() async throws
    /// Removes the tap, stops the engine and deactivates the audio session.
    func stop()
}

/// `AVAudioEngine` input tap converted with `AVAudioConverter` to the format `LiveAudioFeed` and
/// `WaveAudio` expect: 16 kHz, mono, PCM16.
final class IOSAudioCapture: AudioCapturing {
    var onPCM: ((Data) -> Void)?
    var onInterruption: ((Error) -> Void)?
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []

    func start() async throws {
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceDraftError.message("Allow microphone access for VoiceDraft in Settings > Privacy & Security > Microphone.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw VoiceDraftError.message("The microphone could not start. Check your input device.")
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        isRunning = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.interrupted()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            // A route change (for example a headset) invalidates the tap format; end the session cleanly.
            self?.interrupted()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.interrupted()
        })
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func interrupted() {
        guard isRunning else { return }
        stop()
        onInterruption?(VoiceDraftError.message("The microphone was interrupted. Start again when you are ready."))
    }

    /// Runs on the audio thread.
    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
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
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else { return }
        onPCM?(Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }
}

import AVFoundation
import VoiceDraftCore

@MainActor
final class AudioRecorder {
    private var run: AudioCaptureRun?
    var elapsed: Double { run?.metrics().elapsed ?? 0 }
    var level: Double { run?.metrics().level ?? 0 }
    var failure: Error? { run?.metrics().failure }

    static func devices() -> [AudioInputDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14, *) { types = [.microphone, .external] }
        else { types = [.builtInMicrophone, .externalUnknown] }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        return devices.filter(\.isConnected).map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static var defaultDeviceID: String? { AVCaptureDevice.default(for: .audio)?.uniqueID }

    func start(preferredID: String?) async throws -> AudioInputDevice {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard allowed else { throw VoiceDraftError.message("Enable VoiceDraft in System Settings > Privacy & Security > Microphone.") }
        let selected = try AudioInputDevice.resolve(preferredID: preferredID, defaultID: Self.defaultDeviceID, available: Self.devices())
        let capture = AudioCaptureRun(device: selected)
        run = capture
        do {
            try await capture.start()
            try Task.checkCancellation()
            return selected
        } catch {
            capture.cancel()
            if run === capture { run = nil }
            throw error
        }
    }
    func stop() async throws -> Data {
        guard let capture = run else { throw VoiceDraftError.message("No recording is available.") }
        // Cancel/new start may replace run while file finalization is suspended.
        defer { if run === capture { run = nil } }
        return try await capture.stop()
    }
    func cancel() { run?.cancel(); run = nil }
}

/// Each take has its own serial queue, session, file and completions. Delegate callbacks
/// cannot complete or delete a later take. No system-wide default device is changed.
private final class AudioCaptureRun: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let device: AudioInputDevice
    private let queue = DispatchQueue(label: "com.voicedraft.capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voicedraft-\(UUID().uuidString)", isDirectory: true)
    private var file: URL { directory.appendingPathComponent("recording.wav") }
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var stopWaiter: CheckedContinuation<Data, Error>?
    private var completed: Result<Data, Error>?
    private var stopping = false
    private var observers: [NSObjectProtocol] = []
    init(device: AudioInputDevice) { self.device = device }

    func metrics() -> (elapsed: Double, level: Double, failure: Error?) {
        queue.sync {
            let time = output.recordedDuration.seconds
            let power = output.connections.flatMap(\.audioChannels).map(\.averagePowerLevel).max() ?? -60
            let failure: Error?
            if case .failure(let error) = completed { failure = error } else { failure = nil }
            return (time.isFinite ? time : 0, max(0.02, min(1, pow(10, Double(power) / 30))), failure)
        }
    }
    func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let completed { continuation.resume(with: completed.map { _ in () }); return }
                    startWaiter = continuation
                    do {
                        guard let hardware = AVCaptureDevice(uniqueID: device.id), hardware.isConnected, hardware.hasMediaType(.audio) else {
                            throw VoiceDraftError.message("The selected audio input is unavailable. Reconnect it or choose another device.")
                        }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        let input = try AVCaptureDeviceInput(device: hardware)
                        session.beginConfiguration()
                        guard session.canAddInput(input), session.canAddOutput(output) else {
                            session.commitConfiguration()
                            throw VoiceDraftError.message("The microphone could not start. Check your input device.")
                        }
                        session.addInput(input); session.addOutput(output)
                        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                        session.commitConfiguration()
                        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                            self?.failInput()
                        })
                        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: hardware, queue: nil) { [weak self] _ in
                            self?.failInput()
                        })
                        session.startRunning()
                        guard session.isRunning, hardware.isConnected else { throw VoiceDraftError.message("The microphone could not start. Check your input device.") }
                        output.startRecording(to: file, outputFileType: .wav, recordingDelegate: self)
                        queue.asyncAfter(deadline: .now() + 10) { [self] in
                            if startWaiter != nil { complete(.failure(VoiceDraftError.message("The microphone could not start. Check your input device."))) }
                        }
                    } catch { complete(.failure(error)) }
                }
            }
        } onCancel: { self.cancel() }
    }
    func stop() async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let completed { continuation.resume(with: completed); return }
                    stopWaiter = continuation; stopping = true
                    output.stopRecording()
                    queue.asyncAfter(deadline: .now() + 5) { [self] in
                        if completed == nil { complete(.failure(VoiceDraftError.message("The recording could not be finalized. Please try again."))) }
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { queue.async { self.complete(.failure(CancellationError())) } }
    private func failInput() {
        queue.async { self.complete(.failure(VoiceDraftError.message("Audio input was interrupted. Check the selected device and record again."))) }
    }
    private func complete(_ result: Result<Data, Error>) {
        guard completed == nil else { return }
        completed = result
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if output.isRecording { output.stopRecording() }
        session.stopRunning()
        startWaiter?.resume(with: result.map { _ in () }); startWaiter = nil
        stopWaiter?.resume(with: result); stopWaiter = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { [self] in
            guard completed == nil else { return }
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                startWaiter?.resume(); startWaiter = nil
            } catch { complete(.failure(error)) }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [self] in
            guard completed == nil else { try? FileManager.default.removeItem(at: directory); return }
            guard stopping, error == nil else {
                complete(.failure(VoiceDraftError.message("Audio input was interrupted. Check the selected device and record again."))); return
            }
            do {
                let recorded = try AVAudioFile(forReading: fileURL)
                guard recorded.fileFormat.sampleRate == 16_000, recorded.fileFormat.channelCount == 1,
                      recorded.fileFormat.commonFormat == .pcmFormatInt16, recorded.length > 0 else {
                    throw VoiceDraftError.message("The recording format is unsupported. Choose another audio input device.")
                }
                complete(.success(try Data(contentsOf: fileURL)))
            } catch { complete(.failure(error)) }
        }
    }
}

import AVFoundation
import VoiceDraftCore

/// Separate from file capture: streaming PCM never needs a WAV file or a second upload.
@MainActor
final class LiveAudioRecorder {
    private var run: LiveCaptureRun?
    var elapsed: Double { run?.metrics().elapsed ?? 0 }
    var level: Double { run?.metrics().level ?? 0 }
    var failure: Error? { run?.metrics().failure }

    func start(preferredID: String?, feed: LiveAudioFeed) async throws -> AudioInputDevice {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard allowed else { throw VoiceDraftError.message("Enable VoiceDraft in System Settings > Privacy & Security > Microphone.") }
        let selected = try AudioInputDevice.resolve(preferredID: preferredID, defaultID: AudioRecorder.defaultDeviceID, available: AudioRecorder.devices())
        let capture = LiveCaptureRun(device: selected, feed: feed)
        run = capture
        do {
            try await capture.start(); try Task.checkCancellation()
            return selected
        } catch {
            capture.cancel(); if run === capture { run = nil }; throw error
        }
    }
    func stop() async throws {
        guard let capture = run else { throw VoiceDraftError.message("No recording is available.") }
        defer { if run === capture { run = nil } }
        try await capture.stop()
    }
    func cancel() { run?.cancel(); run = nil }
}

private final class LiveCaptureRun: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let device: AudioInputDevice
    private let feed: LiveAudioFeed
    private let queue = DispatchQueue(label: "com.voicedraft.live-capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var stopWaiter: CheckedContinuation<Void, Error>?
    private var completed: Result<Void, Error>?
    private var observers: [NSObjectProtocol] = []
    private var stopping = false
    private var samples = 0
    private var meter = 0.0
    private var previousEnd: Double?

    init(device: AudioInputDevice, feed: LiveAudioFeed) { self.device = device; self.feed = feed }
    func metrics() -> (elapsed: Double, level: Double, failure: Error?) {
        queue.sync {
            let failure: Error?
            if case .failure(let error) = completed { failure = error } else { failure = nil }
            return (Double(samples) / 16_000, meter, failure)
        }
    }
    func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let completed { continuation.resume(with: completed); return }
                    startWaiter = continuation
                    do {
                        guard let hardware = AVCaptureDevice(uniqueID: device.id), hardware.isConnected, hardware.hasMediaType(.audio) else {
                            throw VoiceDraftError.message("The selected audio input is unavailable. Reconnect it or choose another device.")
                        }
                        let input = try AVCaptureDeviceInput(device: hardware)
                        session.beginConfiguration()
                        guard session.canAddInput(input), session.canAddOutput(output) else {
                            session.commitConfiguration()
                            throw VoiceDraftError.message("The microphone could not start. Check your input device.")
                        }
                        session.addInput(input); session.addOutput(output)
                        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false]
                        output.setSampleBufferDelegate(self, queue: queue)
                        session.commitConfiguration()
                        for (name, object) in [(AVCaptureSession.runtimeErrorNotification, session as AnyObject),
                                               (AVCaptureDevice.wasDisconnectedNotification, hardware as AnyObject)] {
                            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                                self?.queue.async { [weak self] in self?.complete(.failure(Self.interrupted())) }
                            })
                        }
                        session.startRunning()
                        guard session.isRunning, hardware.isConnected else { throw Self.interrupted() }
                        queue.asyncAfter(deadline: .now() + 10) { [self] in
                            if startWaiter != nil { complete(.failure(Self.interrupted())) }
                        }
                    } catch { complete(.failure(error)) }
                }
            }
        } onCancel: { self.cancel() }
    }
    func stop() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let completed { continuation.resume(with: completed); return }
                    guard !stopping else { continuation.resume(throwing: CancellationError()); return }
                    stopping = true; stopWaiter = continuation
                    session.stopRunning()
                    // Drain callbacks already enqueued before closing the producer; tail PCM is retained.
                    queue.async { [self] in
                        guard completed == nil else { return }
                        do { try feed.finish(); complete(.success(())) }
                        catch { complete(.failure(error)) }
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { feed.cancel(); queue.async { self.complete(.failure(CancellationError())) } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard completed == nil else { return }
        do {
            let pcm = try PCM16Audio.data(from: sampleBuffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if let previousEnd, timestamp.isFinite, abs(timestamp - previousEnd) > 0.10 { throw Self.interrupted() }
            if timestamp.isFinite { previousEnd = timestamp + Double(pcm.count / 2) / 16_000 }
            try feed.append(pcm)
            samples += pcm.count / 2; meter = PCM16Audio.level(pcm)
            startWaiter?.resume(); startWaiter = nil
        } catch { complete(.failure(error)) }
    }
    private func complete(_ result: Result<Void, Error>) {
        guard completed == nil else { return }
        completed = result
        if case .failure(let error) = result { feed.cancel(error) }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        startWaiter?.resume(with: result); startWaiter = nil
        stopWaiter?.resume(with: result); stopWaiter = nil
    }
    private static func interrupted() -> VoiceDraftError {
        .message("Audio input was interrupted. Check the selected device and record again.")
    }
}

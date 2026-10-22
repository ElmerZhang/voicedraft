import Foundation
import VoiceDraftCore

/// Gate between the always-on microphone of a listening session and the current take.
///
/// While no take is active every chunk is discarded, so a listening session keeps nothing. During a take
/// chunks accumulate for HTTP adapters (`WaveAudio`) and are forwarded to the take's `LiveAudioFeed` for
/// WebSocket adapters. Thread-safe: `accept` runs on the audio thread.
final class PCMRouter: @unchecked Sendable {
    /// 16 kHz × 2 bytes.
    static let bytesPerSecond = 32_000

    private let lock = NSLock()
    private var active = false
    private var pcm = Data()
    private var feed: LiveAudioFeed?
    private var limitBytes = Int.max
    private var currentLevel = 0.0
    private var currentFailure: Error?

    var isActive: Bool { lock.withLock { active } }
    var elapsed: Double { lock.withLock { Double(pcm.count) / Double(Self.bytesPerSecond) } }
    var level: Double { lock.withLock { currentLevel } }
    var failure: Error? { lock.withLock { currentFailure } }

    /// Starts collecting a take of at most `maxSeconds`.
    func begin(feed: LiveAudioFeed?, maxSeconds: Double) {
        lock.withLock {
            active = true
            pcm = Data()
            self.feed = feed
            limitBytes = Int(maxSeconds * Double(Self.bytesPerSecond))
            currentLevel = 0
            currentFailure = nil
        }
    }

    func accept(_ chunk: Data) {
        lock.withLock {
            guard active, !chunk.isEmpty else { return }
            let room = limitBytes - pcm.count
            guard room > 0 else { return }
            var chunk = chunk.count > room ? Data(chunk.prefix(room)) : chunk
            if !chunk.count.isMultiple(of: 2) { chunk.removeLast() }
            pcm.append(chunk)
            currentLevel = PCM16Audio.level(chunk)
            guard let feed else { return }
            do { try feed.append(chunk) } catch {
                currentFailure = error
                self.feed = nil
            }
        }
    }

    /// Ends the take, closes its live feed and returns the collected PCM.
    func end() -> Data {
        lock.withLock {
            active = false
            let collected = pcm
            pcm = Data()
            try? feed?.finish()
            feed = nil
            currentLevel = 0
            return collected
        }
    }

    /// Abandons the take and discards its audio.
    func cancel() {
        lock.withLock {
            active = false
            pcm = Data()
            feed?.cancel()
            feed = nil
            currentLevel = 0
        }
    }
}

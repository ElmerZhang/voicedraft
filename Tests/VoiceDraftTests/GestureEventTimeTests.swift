import XCTest
@testable import VoiceDraft
import VoiceDraftCore

/// AppState uses the key events' own times for tap versus hold, so a release
/// processed late (after a cold-start stall) still locks a tapped take.
final class GestureEventTimeTests: XCTestCase {
    func testEarlyReleaseTimeLocksEvenWhenProcessedLate() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            let now = ProcessInfo.processInfo.systemUptime
            // Both events happened 0.9 s ago, 0.1 s apart; they are processed only now.
            state.shortcutEvent(.dictate, down: true, at: now - 0.9)
            state.shortcutEvent(.dictate, down: false, at: now - 0.8)
            XCTAssertTrue(state.recordingLocked)
        }
    }

    func testLongHoldByEventTimeIsNotLocked() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            state.shortcutEvent(.dictate, down: true, at: 100)
            state.shortcutEvent(.dictate, down: false, at: 100.8)
            XCTAssertFalse(state.recordingLocked)
        }
    }

    /// Only an accepted mode switch restarts the window (covered with event times in
    /// FeatureTests); preview has no writing key, so this switch is refused and the
    /// hold is still measured from the press event.
    func testRefusedRetargetKeepsThePressEventTime() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            state.shortcutEvent(.dictate, down: true, at: 100)
            state.retargetShortcut(from: .dictate, to: .translate, at: 100.7)
            state.shortcutEvent(.translate, down: false, at: 101.0)
            XCTAssertFalse(state.recordingLocked)
        }
    }
}

final class TakeDiagnosticsTests: XCTestCase {
    func testRecordHasTimingsAndNoText() throws {
        var trace = TakeTrace(takeID: UUID(), origin: 10, action: .dictate, mode: .polish, external: true)
        trace.bundleID = "com.example.editor"
        trace.pressDelay = 0.002; trace.capture = 0.5; trace.starting = 0.62; trace.microphone = 0.71
        trace.taskStarted = 0.45; trace.releaseDelay = 0.55; trace.held = 0.09; trace.releaseEffect = "none"; trace.locked = true
        let record = trace.record(audioSeconds: 3.456, outcome: "noSpeech", failure: SpeechRecognitionError.noSpeech)
        XCTAssertEqual(record.captureMs, 500)
        XCTAssertEqual(record.startingMs, 620)
        XCTAssertEqual(record.heldMs, 90)
        XCTAssertEqual(record.audioSeconds, 3.46)
        XCTAssertEqual(record.failure, "noSpeech")
        XCTAssertEqual(record.action, "dictate")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var enabled = false
        let log = TakeDiagnosticsLog(directory: directory, isEnabled: { enabled })
        log.record(record); log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.fileURL.path), "off by default")
        enabled = true
        log.record(record); log.record(record); log.flush()
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoded = try JSONDecoder.iso8601.decode(TakeDiagnosticRecord.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.takeID, record.takeID)
        XCTAssertEqual(log.fileURL.lastPathComponent, "takes.jsonl")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

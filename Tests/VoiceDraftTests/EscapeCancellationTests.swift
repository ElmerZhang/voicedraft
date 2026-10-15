import AppKit
import XCTest
@testable import VoiceDraft

final class EscapeCancellationTests: XCTestCase {
    func testInstalledLocalMonitorReceivesEventsAndUninstalls() async {
        await MainActor.run {
            let application = NSApplication.shared
            let monitor = EscapeCancellationMonitor()
            var cancellations = 0
            monitor.onCancel = { cancellations += 1; return true }
            monitor.install()
            monitor.install() // Reinstallation must not leave a duplicate monitor.
            application.sendEvent(event())
            XCTAssertEqual(cancellations, 1)
            monitor.uninstall()
            application.sendEvent(event())
            XCTAssertEqual(cancellations, 1)
        }
    }

    @MainActor
    private func event(keyCode: UInt16 = 53, type: NSEvent.EventType = .keyDown,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\u{1b}",
                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: keyCode)!
    }

    func testEscapeCancelsEveryActiveInputPhase() async {
        await MainActor.run {
            for phase in ["starting", "recording", "live", "processing"] {
                let state = AppState(preview: true)
                state.prepareHUDPreview(phase)
                var hidden = 0
                state.hideHUD = { hidden += 1 }
                let monitor = EscapeCancellationMonitor()
                monitor.onCancel = { state.cancelActiveInput() }

                XCTAssertTrue(monitor.handle(event()), phase)
                XCTAssertEqual(state.phase, "idle", phase)
                XCTAssertFalse(state.busy)
                XCTAssertTrue(state.liveTranscript.isEmpty)
                XCTAssertTrue(state.hudText.isEmpty)
                XCTAssertEqual(hidden, 1)
                XCTAssertFalse(monitor.handle(event()), "Repeated Escape must pass through when idle")
                XCTAssertEqual(hidden, 1)
            }
        }
    }

    func testIdleEscapePreservesResultAndOtherKeysPreserveRecording() async {
        await MainActor.run {
            let state = AppState(preview: true)
            let monitor = EscapeCancellationMonitor()
            monitor.onCancel = { state.cancelActiveInput() }
            state.prepareHUDPreview("result")
            let result = state.hudText
            XCTAssertFalse(monitor.handle(event()))
            XCTAssertEqual(state.hudText, result)

            state.prepareHUDPreview("recording")
            XCTAssertFalse(monitor.handle(event(keyCode: 0)))
            XCTAssertFalse(monitor.handle(event(type: .keyUp)))
            XCTAssertTrue(state.recording)
        }
    }

    func testIdleEscapeDismissesVisibleCardOnly() async {
        await MainActor.run {
            for name in ["result", "failure", "notice"] {
                let state = AppState(preview: true)
                state.prepareHUDPreview(name)
                var hidden = 0
                state.hideHUD = { hidden += 1 }
                var visible = true
                let monitor = EscapeCancellationMonitor()
                monitor.onCancel = { state.handleEscape(hudVisible: visible) }

                XCTAssertTrue(monitor.handle(event()), name)
                XCTAssertEqual(hidden, 1, name)
                XCTAssertEqual(state.phase, "idle", name)
                visible = false
                XCTAssertFalse(monitor.handle(event()), "Idle Escape without a visible card must pass through")
                XCTAssertEqual(hidden, 1, name)
            }
        }
    }

    func testEscapeStillCancelsActiveRunWhenHUDVisible() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("live")
            var hidden = 0
            state.hideHUD = { hidden += 1 }
            XCTAssertTrue(state.handleEscape(hudVisible: true))
            XCTAssertEqual(state.phase, "idle")
            XCTAssertTrue(state.hudText.isEmpty)
            XCTAssertEqual(hidden, 1)
        }
    }

    func testFailureWithoutTextUsesNoticeKind() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("notice")
            XCTAssertEqual(state.hudKind, .notice)
            XCTAssertTrue(state.hudText.isEmpty)
            XCTAssertLessThan(DictationHUDKind.notice.size.height, DictationHUDKind.failure.size.height)
            state.prepareHUDPreview("failure")
            XCTAssertEqual(state.hudKind, .failure)
            XCTAssertFalse(state.hudText.isEmpty)
        }
    }

    func testEscapeWhileHoldingFnIgnoresSubsequentRelease() async {
        await MainActor.run {
            let state = AppState(preview: true)
            state.prepareHUDPreview("recording")
            state.shortcutEvent(.dictate, down: true)
            let monitor = EscapeCancellationMonitor()
            monitor.onCancel = { state.cancelActiveInput() }
            XCTAssertTrue(monitor.handle(event(modifiers: .function)))
            state.shortcutEvent(.dictate, down: false)
            XCTAssertEqual(state.phase, "idle")
            XCTAssertFalse(state.recordingLocked)
        }
    }
}

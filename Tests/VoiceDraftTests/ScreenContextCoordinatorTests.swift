import AppKit
import XCTest
import VoiceDraftCore
@testable import VoiceDraft

/// Coordinator timing and policy with fake readers. No real AX, screen capture,
/// permission prompt, audio or credential is used; all text is synthetic.
private enum Fixture {
    static let rich = "Alice Chen will demo VoiceDraft on the Raspberry Pi. We switch qwen3-asr-flash to Doubao after the review, then ship the HUD and the Raspberry Pi build."
    static let thin = "Inbox"
    static let ocrText = "Kickoff for Project Atlas with Bob Lee and the Zephyr team"
}

@MainActor
final class ScreenContextCoordinatorTests: XCTestCase {

    private final class FakeReader: ScreenTextReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _delay: TimeInterval
        let text: String
        init(delay: TimeInterval, text: String) { _delay = delay; self.text = text }
        var calls: Int { lock.withLock { _calls } }
        var delay: TimeInterval { get { lock.withLock { _delay } } set { lock.withLock { _delay = newValue } } }
        func collect(_ request: ScreenReadRequest, limits: ScreenContextLimits) async -> ScreenTextCollection? {
            let delay = lock.withLock { _calls += 1; return _delay }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return ScreenTextCollection(segments: [ScreenTextSegment(kind: .body, text: text, order: 0)], nodesVisited: 3, charactersCollected: text.count)
        }
    }

    private final class FakeRecognizer: WindowTextRecognizing, @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (permitted: 0, locate: 0, recognize: 0)
        private var _delay: TimeInterval
        let allowed: Bool
        let text: String
        init(allowed: Bool, delay: TimeInterval = 0.01, text: String = Fixture.ocrText) {
            self.allowed = allowed; _delay = delay; self.text = text
        }
        var delay: TimeInterval { get { lock.withLock { _delay } } set { lock.withLock { _delay = newValue } } }
        var permittedCalls: Int { lock.withLock { counts.permitted } }
        var locateCalls: Int { lock.withLock { counts.locate } }
        var recognizeCalls: Int { lock.withLock { counts.recognize } }
        func permitted() -> Bool { lock.withLock { counts.permitted += 1 }; return allowed }
        func locate(_ request: ScreenReadRequest) async -> ScreenWindowLocation? {
            lock.withLock { counts.locate += 1 }
            return ScreenWindowLocation(windowID: 77, focusFrame: nil)
        }
        func recognize(_ location: ScreenWindowLocation, deadline: ContinuousClock.Instant, limits: ScreenContextLimits) async -> ScreenTextCollection? {
            let delay = lock.withLock { counts.recognize += 1; return _delay }
            // Deliberately ignores the deadline and cancellation: the coordinator must not wait for it.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { done.resume() }
            }
            return ScreenTextCollection(segments: [ScreenTextSegment(kind: .ocrLine, text: text, order: 0)], nodesVisited: 1, charactersCollected: text.count)
        }
    }

    private func target(pid: pid_t = 4242, secure: Bool = false) -> InputTarget {
        InputTarget(pid: pid, name: "Notes", element: nil, window: nil, range: nil, selection: "", value: nil,
                    secure: secure, editable: true, keyboardSurface: false, opaqueApplication: false, focusGuard: nil)
    }

    private func options(ocr: Bool = false, excluded: [String] = []) -> DesktopOptions {
        var options = DesktopOptions()
        options.screenContext = true
        options.screenContextOCR = ocr
        options.screenContextExcludedApps = excluded
        return options
    }

    private func coordinator(_ reader: FakeReader, _ recognizer: FakeRecognizer, ocrSeconds: TimeInterval = 0.5) -> ScreenContextCoordinator {
        var limits = ScreenContextLimits.standard
        limits.ocrSeconds = ocrSeconds
        return ScreenContextCoordinator(reader: reader, recognizer: recognizer, limits: limits, ownBundleID: "com.voicedraft.tests")
    }

    private func gate() -> ContinuousClock.Instant { .now.advanced(by: .milliseconds(250)) }

    func testGateReturnsAccessibilityTermsWhenTheWalkIsEarly() async {
        let screen = coordinator(FakeReader(delay: 0.02, text: Fixture.rich), FakeRecognizer(allowed: false))
        let take = UUID()
        XCTAssertTrue(screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(), vocabulary: AppVocabulary()))
        let terms = await screen.asrTerms(take: take, until: gate())
        XCTAssertTrue(terms.contains("VoiceDraft"), "\(terms)")
        XCTAssertTrue(terms.contains("qwen3-asr-flash"), "\(terms)")
        XCTAssertEqual(screen.termCount(take: take), terms.count)
        XCTAssertTrue(screen.learningExclusions(take: take).contains(AppVocabulary.automaticTermKey("VoiceDraft")))
    }

    func testGateReturnsNothingWhenTheWalkIsLate() async {
        let screen = coordinator(FakeReader(delay: 0.8, text: Fixture.rich), FakeRecognizer(allowed: false))
        let take = UUID()
        screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(), vocabulary: AppVocabulary())
        let started = ContinuousClock.now
        let terms = await screen.asrTerms(take: take, until: gate())
        XCTAssertEqual(terms, [])
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(450), "The live gate must not wait past 250 ms.")
        screen.end(take: take)
    }

    func testGateUsesCachedOCRTermsForTheSameWindow() async {
        let reader = FakeReader(delay: 0.01, text: Fixture.thin), recognizer = FakeRecognizer(allowed: true)
        let first = coordinator(reader, recognizer)
        let take = UUID()
        first.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(ocr: true), vocabulary: AppVocabulary())
        let context = await first.writingContext(take: take, mode: .polish)
        XCTAssertEqual(context?.source, .accessibility)
        XCTAssertTrue(context?.terms.contains("Project Atlas") == true, "\(String(describing: context))")
        XCTAssertEqual(first.cachedEntries, 1)
        first.end(take: take)

        // Same pid and window: the next take's gate sees the cached OCR terms even
        // though its AX walk is late and its fresh OCR has not finished.
        reader.delay = 0.8; recognizer.delay = 1.0
        let next = UUID()
        first.begin(take: next, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(ocr: true), vocabulary: AppVocabulary())
        let terms = await first.asrTerms(take: next, until: gate())
        XCTAssertTrue(terms.contains("Project Atlas"), "\(terms)")
        first.end(take: next)
        first.clearCache()
        XCTAssertEqual(first.cachedEntries, 0)
    }

    func testCurrentTermsNeverWait() async {
        let screen = coordinator(FakeReader(delay: 0.3, text: Fixture.rich), FakeRecognizer(allowed: false))
        let take = UUID()
        screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(), vocabulary: AppVocabulary())
        let started = ContinuousClock.now
        XCTAssertEqual(screen.currentASRTerms(take: take), [])
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(50))
        _ = await screen.asrTerms(take: take, until: .now.advanced(by: .seconds(2)))
        XCTAssertTrue(screen.currentASRTerms(take: take).contains("VoiceDraft"))
    }

    func testWritingWaitsAtMostUntilTheOCRDeadline() async {
        let recognizer = FakeRecognizer(allowed: true, delay: 2.5)
        let screen = coordinator(FakeReader(delay: 0.01, text: Fixture.thin + " · Alice Chen"), recognizer, ocrSeconds: 0.4)
        let take = UUID()
        screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .translate, options: options(ocr: true), vocabulary: AppVocabulary())
        let started = ContinuousClock.now
        let context = await screen.writingContext(take: take, mode: .translate)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(900), "Writing must not wait past t0 + ocrSeconds.")
        XCTAssertEqual(context?.source, .accessibility, "AX text is used when OCR misses its deadline.")
        XCTAssertEqual(recognizer.recognizeCalls, 1)
        screen.end(take: take)
    }

    func testEndDiscardsLateResults() async {
        let reader = FakeReader(delay: 0.15, text: Fixture.rich)
        let screen = coordinator(reader, FakeRecognizer(allowed: false))
        var updates = 0
        screen.onTakeUpdate = { _ in updates += 1 }
        let take = UUID()
        screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(), vocabulary: AppVocabulary())
        screen.end(take: take)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(updates, 0)
        XCTAssertNil(screen.termCount(take: take))
        XCTAssertEqual(screen.currentASRTerms(take: take), [])
        let context = await screen.writingContext(take: take, mode: .polish)
        XCTAssertNil(context)
        XCTAssertFalse(screen.hasActiveTake)
    }

    func testExcludedAppsAndVoiceDraftNeverCallTheReader() async throws {
        let reader = FakeReader(delay: 0, text: Fixture.rich), recognizer = FakeRecognizer(allowed: true)
        let screen = coordinator(reader, recognizer)
        for (bundle, exclusions) in [("com.1password.1password", []), ("COM.APPLE.KEYCHAINACCESS", []),
                                     ("com.tencent.xinWeChat", ["com.tencent.xinwechat"]), ("com.voicedraft.tests", [])] {
            XCTAssertFalse(screen.begin(take: UUID(), target: target(), bundleID: bundle, mode: .polish,
                                        options: options(ocr: true, excluded: exclusions), vocabulary: AppVocabulary()))
        }
        XCTAssertFalse(screen.begin(take: UUID(), target: target(secure: true), bundleID: "com.example.notes", mode: .polish,
                                    options: options(ocr: true), vocabulary: AppVocabulary()), "Secure fields are never read.")
        let scan = try await screen.extract(app: ScreenContextApplication(pid: 1, bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
                                            options: options(ocr: true), vocabulary: AppVocabulary())
        XCTAssertTrue(scan.excluded)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reader.calls, 0)
        XCTAssertEqual(recognizer.permittedCalls + recognizer.locateCalls + recognizer.recognizeCalls, 0)
    }

    func testMasterOffOrNoConsumerNeverCallsAnything() async {
        let reader = FakeReader(delay: 0, text: Fixture.rich), recognizer = FakeRecognizer(allowed: true)
        let screen = coordinator(reader, recognizer)
        var off = DesktopOptions(); off.screenContextOCR = true
        XCTAssertFalse(screen.begin(take: UUID(), target: target(), bundleID: "com.example.notes", mode: .polish, options: off, vocabulary: AppVocabulary()))
        var none = options(ocr: true); none.screenContextASR = false; none.screenContextWriting = false
        XCTAssertFalse(screen.begin(take: UUID(), target: target(), bundleID: "com.example.notes", mode: .polish, options: none, vocabulary: AppVocabulary()))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reader.calls, 0)
        XCTAssertEqual(recognizer.permittedCalls + recognizer.locateCalls + recognizer.recognizeCalls, 0)
    }

    func testMissingScreenRecordingNeverCallsTheRecognizer() async throws {
        let recognizer = FakeRecognizer(allowed: false)
        let screen = coordinator(FakeReader(delay: 0.01, text: Fixture.thin), recognizer)
        let take = UUID()
        screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(ocr: true), vocabulary: AppVocabulary())
        _ = await screen.writingContext(take: take, mode: .polish)
        _ = try await screen.extract(app: ScreenContextApplication(pid: 4242, bundleID: "com.example.notes", name: "Notes"),
                                     options: options(ocr: true), vocabulary: AppVocabulary())
        XCTAssertGreaterThan(recognizer.permittedCalls, 0)
        XCTAssertEqual(recognizer.locateCalls + recognizer.recognizeCalls, 0)
    }

    func testConsumerSwitchesAndModesScopeWhatIsOffered() async {
        let screen = coordinator(FakeReader(delay: 0.01, text: Fixture.rich), FakeRecognizer(allowed: false))
        var writingOnly = options(); writingOnly.screenContextASR = false
        let take = UUID()
        screen.begin(take: take, target: target(), bundleID: "com.example.notes", mode: .polish, options: writingOnly, vocabulary: AppVocabulary())
        let terms = await screen.asrTerms(take: take, until: gate())
        XCTAssertEqual(terms, [], "Recognition hints are off.")
        let ask = await screen.writingContext(take: take, mode: .ask)
        XCTAssertNil(ask, "Ask never receives on-screen context.")
        let edit = await screen.writingContext(take: take, mode: .edit)
        XCTAssertEqual(edit?.excerpt, "", "Edit receives terms only.")
        XCTAssertFalse(edit?.terms.isEmpty ?? true)

        // Globally disabled vocabulary also disables screen recognition hints.
        var vocabulary = AppVocabulary(); vocabulary.enabled = false
        let next = UUID()
        screen.begin(take: next, target: target(), bundleID: "com.example.notes", mode: .polish, options: options(), vocabulary: vocabulary)
        let disabled = await screen.asrTerms(take: next, until: gate())
        XCTAssertEqual(disabled, [])
    }

    func testExtractionReadsWithTheMasterSwitchOffAndCapsCandidates() async throws {
        let reader = FakeReader(delay: 0, text: Fixture.rich)
        let screen = coordinator(reader, FakeRecognizer(allowed: false))
        let scan = try await screen.extract(app: ScreenContextApplication(pid: 4242, bundleID: "com.example.notes", name: "Notes"),
                                            options: DesktopOptions(), vocabulary: AppVocabulary(words: "VoiceDraft"))
        XCTAssertEqual(reader.calls, 1)
        XCTAssertEqual(scan.source, .accessibility)
        XCTAssertFalse(scan.excluded)
        XCTAssertTrue(scan.candidates.map(\.text).contains("Raspberry Pi"))
        XCTAssertFalse(scan.candidates.map(\.text).contains("VoiceDraft"), "Existing vocabulary is excluded.")
        XCTAssertLessThanOrEqual(scan.candidates.count, 200)
    }

    func testTrackingSkipsVoiceDraftAndClearsOnTermination() {
        let screen = coordinator(FakeReader(delay: 0, text: ""), FakeRecognizer(allowed: false))
        screen.activated(ScreenContextApplication(pid: 10, bundleID: "com.example.notes", name: "Notes"))
        screen.activated(ScreenContextApplication(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "x", name: "Self"))
        screen.activated(ScreenContextApplication(pid: 11, bundleID: "com.voicedraft.tests", name: "VoiceDraft"))
        XCTAssertEqual(screen.lastExternalApplication?.pid, 10)
        screen.terminated(ScreenContextApplication(pid: 10, bundleID: "com.example.notes", name: "Notes"))
        XCTAssertNil(screen.lastExternalApplication)
    }
}

import AppKit
import VoiceDraftCore

/// An app that on-screen extraction can read: identity only, never content.
struct ScreenContextApplication: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String

    init(pid: pid_t, bundleID: String?, name: String) { self.pid = pid; self.bundleID = bundleID; self.name = name }
    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "App")
    }
}

/// Per-take on-screen context: reads the target window's AX text (and, when
/// allowed, window OCR) in the background and hands bounded results to the
/// speech and writing requests. Everything stays in memory. One take record
/// exists at a time; results that arrive after `end(take:)` are discarded.
@MainActor
final class ScreenContextCoordinator {
    private final class Take {
        let id: UUID
        let start: ContinuousClock.Instant
        let bundleID: String
        let name: String
        let mode: WritingMode
        let options: DesktopOptions
        let vocabulary: AppVocabulary
        /// The complete walk (to `axWalkSeconds`), once finished.
        var ax: ScreenContextSnapshot?
        var axCollection: ScreenTextCollection?
        var axDone = false
        var axElapsed: Duration?
        /// Text collected so far while the walk runs; the live gate uses it.
        var axPartial: ScreenTextCollection?
        var partialSnapshot: ScreenContextSnapshot?
        var partialStale = false
        var axKey: String?
        /// This window's complete AX snapshot from an earlier take (≤ `cacheSeconds`).
        var cachedAX: ScreenContextSnapshot?
        var axNeedsOCR = true
        var ocr: ScreenContextSnapshot?
        var ocrCollection: ScreenTextCollection?
        var ocrPending = false
        var ocrStart: ContinuousClock.Instant?
        var ocrElapsed: Duration?
        var cachedOCR: ScreenContextSnapshot?
        /// Keys of every screen term offered to speech or writing, for learning exclusion.
        var offeredKeys = Set<String>()
        /// Diagnostics only: what each consumer received.
        var offeredTerms: [String] = []
        var gateHadTerms: Bool?
        var asrTermsSent = 0
        var writingTerms: [String] = []
        var excerptLength = 0
        var tasks: [Task<Void, Never>] = []
        var startedAt = Date()
        func offer(_ terms: [String]) {
            for term in terms where offeredKeys.insert(AppVocabulary.automaticTermKey(term)).inserted { offeredTerms.append(term) }
        }
        init(id: UUID, start: ContinuousClock.Instant, bundleID: String, name: String, mode: WritingMode,
             options: DesktopOptions, vocabulary: AppVocabulary) {
            self.id = id; self.start = start; self.bundleID = bundleID; self.name = name; self.mode = mode
            self.options = options; self.vocabulary = vocabulary
        }
    }

    let limits: ScreenContextLimits
    private let reader: ScreenTextReading
    private let recognizer: WindowTextRecognizing
    private let ownBundleID: String?
    private let now: () -> Date
    private var current: Take?
    private var cache: ScreenContextCache
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Opt-in device-local diagnostics; nil in preview mode.
    var diagnostics: ScreenContextDiagnosticsLog?
    /// The last regular app other than VoiceDraft that became active; Vocabulary's target.
    private(set) var lastExternalApplication: ScreenContextApplication?
    /// Called on the main actor whenever a take's offered context changes.
    var onTakeUpdate: ((UUID) -> Void)?
    var onApplicationChange: ((ScreenContextApplication?) -> Void)?

    init(reader: ScreenTextReading = ScreenContextAXReader.shared, recognizer: WindowTextRecognizing = WindowTextRecognizer.shared,
         limits: ScreenContextLimits = .standard, ownBundleID: String? = Bundle.main.bundleIdentifier, now: @escaping () -> Date = Date.init) {
        self.reader = reader; self.recognizer = recognizer; self.limits = limits
        self.ownBundleID = ownBundleID; self.now = now
        cache = ScreenContextCache(limits: limits)
    }

    var cachedEntries: Int { cache.count }

    // MARK: Take lifecycle

    /// Starts reading for a dictation take into another app. Returns false (and
    /// reads nothing) when the policy disallows it: master or both consumers off,
    /// a secure field, an excluded app or VoiceDraft itself. Ends any earlier take.
    @discardableResult
    func begin(take id: UUID, target: InputTarget, bundleID: String?, mode: WritingMode,
               options: DesktopOptions, vocabulary: AppVocabulary) -> Bool {
        if let current { end(take: current.id) }
        guard ScreenContextPolicy.shouldCapture(options: options, external: true, secure: target.secure,
                                                bundleID: bundleID, ownBundleID: ownBundleID), let bundleID else { return false }
        let record = Take(id: id, start: .now, bundleID: bundleID, name: target.name, mode: mode, options: options, vocabulary: vocabulary)
        record.startedAt = now()
        current = record
        let request = ScreenReadRequest(pid: target.pid, window: target.window, focused: target.element,
                                        focusedValue: target.value, focusedRange: target.range)
        let reader = reader, recognizer = recognizer, limits = limits
        // The walk continues past the ASR gate to `axWalkSeconds`; partial results
        // feed the gate, the complete one feeds writing and the per-window cache.
        let sink: @Sendable (ScreenReadProgress) -> Void = { [weak self] event in
            Task { @MainActor in self?.progress(id, event) }
        }
        record.tasks.append(Task { [weak self] in
            let collection = await reader.collect(request, limits: limits, progress: sink)
            self?.finishAccessibility(id, collection)
        })
        // Takes only check; a dictation never triggers a permission prompt.
        if options.screenContextOCR, recognizer.permitted() {
            record.ocrPending = true
            let deadline = record.start.advanced(by: .milliseconds(Int(limits.ocrSeconds * 1000)))
            record.tasks.append(Task { [weak self] in
                let location = await recognizer.locate(request)
                guard let self else { return }
                guard let location else { self.finishOCR(id, nil, key: nil); return }
                let key = ScreenContextCache.key(pid: request.pid, windowID: location.windowID)
                self.useCache(id, key: key)
                // Decides as soon as the walk (or a partial with enough text) shows whether OCR is needed.
                await self.wait(id, until: deadline) { !$0.axDone && $0.axNeedsOCR }
                guard self.current?.id == id, self.current?.axNeedsOCR == true, !Task.isCancelled else {
                    self.finishOCR(id, nil, key: nil); return
                }
                self.current?.ocrStart = .now
                let collection = await recognizer.recognize(location, deadline: deadline, limits: limits)
                self.finishOCR(id, collection, key: key)
            })
        }
        return true
    }

    /// Cancels the take's work and drops its record. Late results are discarded.
    func end(take id: UUID) {
        guard let record = current, record.id == id else { return }
        record.tasks.forEach { $0.cancel() }
        if let diagnostics, diagnostics.isEnabled() { diagnostics.record(diagnosticRecord(record)) }
        current = nil
        signal()
    }

    var hasActiveTake: Bool { current != nil }

    // MARK: Consumers

    /// Live ASR gate: waits until the AX walk finishes or `deadline` (t0 + 250 ms),
    /// then returns the terms ready now: the complete walk, else the partial walk
    /// merged with this window's cached AX snapshot, plus OCR or cached OCR; else [].
    func asrTerms(take id: UUID, until deadline: ContinuousClock.Instant) async -> [String] {
        await wait(id, until: deadline) { !$0.axDone }
        let terms = currentASRTerms(take: id)
        if let record = current, record.id == id {
            record.gateHadTerms = !terms.isEmpty
            onTakeUpdate?(id)
        }
        return terms
    }

    /// HTTP adapters at stop: whatever is ready now, including finished OCR. Never waits.
    func currentASRTerms(take id: UUID) -> [String] {
        guard let record = current, record.id == id, record.options.screenContextASR else { return [] }
        let terms = ScreenContextPolicy.asrTerms(snapshot(record), vocabulary: record.vocabulary, limits: limits)
        record.offer(terms)
        record.asrTermsSent = terms.count
        return terms
    }

    /// Writing reference for Polish/Translate (terms only for Edit). Waits for
    /// in-flight AX/OCR, but never beyond t0 + `ocrSeconds`.
    func writingContext(take id: UUID, mode: WritingMode) async -> ScreenWritingContext? {
        guard let record = current, record.id == id, record.options.screenContextWriting,
              mode == .polish || mode == .translate || mode == .edit else { return nil }
        await wait(id, until: record.start.advanced(by: .milliseconds(Int(limits.ocrSeconds * 1000)))) { !$0.axDone || $0.ocrPending }
        guard let record = current, record.id == id, let snapshot = snapshot(record),
              let context = ScreenWritingContext(snapshot: snapshot, mode: mode, limits: limits) else { return nil }
        record.offer(context.terms)
        record.writingTerms = context.terms
        record.excerptLength = context.excerpt.count
        return context
    }

    func learningExclusions(take id: UUID) -> Set<String> {
        guard let record = current, record.id == id else { return [] }
        return record.offeredKeys
    }

    /// Terms offered for the HUD indicator: ASR terms after policy filtering when
    /// that consumer is on, else writing terms. Nil when nothing would be delivered.
    func termCount(take id: UUID) -> Int? {
        guard let record = current, record.id == id, let snapshot = snapshot(record) else { return nil }
        let asr = record.options.screenContextASR
            ? ScreenContextPolicy.asrTerms(snapshot, vocabulary: record.vocabulary, limits: limits).count : 0
        let writing = record.options.screenContextWriting ? ScreenWritingContext(snapshot: snapshot, mode: record.mode, limits: limits) : nil
        guard asr > 0 || writing != nil else { return nil }
        return asr > 0 ? asr : writing?.terms.count ?? 0
    }

    // MARK: Extraction

    /// "Extract words from this screen": AX from the app's focused or main window,
    /// plus OCR when that switch is on and permission is granted. Works with the
    /// master switch off; exclusions always apply and are checked before any read.
    func extract(app: ScreenContextApplication, options: DesktopOptions, vocabulary: AppVocabulary) async throws -> ScreenContextScan {
        guard ScreenContextPolicy.allows(bundleID: app.bundleID, options: options, ownBundleID: ownBundleID) else {
            return ScreenContextScan(applicationName: app.name, excluded: true)
        }
        // An explicit, on-demand read is not on the dictation latency path.
        var extraction = limits
        extraction.axWalkSeconds = max(limits.axWalkSeconds, 1.5)
        let request = ScreenReadRequest(pid: app.pid, window: nil, focused: nil, focusedValue: nil, focusedRange: nil)
        let started = ContinuousClock.now
        let ax = await reader.collect(request, limits: extraction)
        let axElapsed = started.duration(to: .now)
        try Task.checkCancellation()
        var ocr: ScreenTextCollection?
        var ocrElapsed: Duration?
        if options.screenContextOCR, ScreenContextPolicy.needsOCR(ax, limits: limits), recognizer.permitted(),
           let location = await recognizer.locate(request) {
            try Task.checkCancellation()
            let ocrStarted = ContinuousClock.now
            ocr = await recognizer.recognize(location, deadline: .now.advanced(by: .milliseconds(Int(limits.ocrSeconds * 1000))), limits: limits)
            ocrElapsed = ocrStarted.duration(to: .now)
            try Task.checkCancellation()
        }
        let collections = [ax, ocr].compactMap { $0 }.filter { !$0.segments.isEmpty }
        let source: ScreenContextSource? = ocr?.segments.isEmpty == false ? .ocr : ax?.segments.isEmpty == false ? .accessibility : nil
        let scan = ScreenContextScan.make(collections: collections, source: source, applicationName: app.name, vocabulary: vocabulary)
        if let diagnostics, diagnostics.isEnabled() {
            diagnostics.record(ScreenContextDiagnosticRecord(
                kind: .extraction, date: now(), takeID: nil, bundleID: app.bundleID,
                sources: [ax?.segments.isEmpty == false ? ScreenContextSource.accessibility : nil, ocr?.segments.isEmpty == false ? .ocr : nil].compactMap { $0?.rawValue },
                nodesVisited: (ax?.nodesVisited ?? 0) + (ocr?.nodesVisited ?? 0),
                charactersCollected: (ax?.charactersCollected ?? 0) + (ocr?.charactersCollected ?? 0),
                axElapsedMs: ax == nil ? nil : axElapsed.roundedMilliseconds, ocrElapsedMs: ocrElapsed?.roundedMilliseconds,
                truncated: (ax?.truncated ?? false) || (ocr?.truncated ?? false), gateHadTerms: nil,
                termsOffered: scan.candidates.map(\.text), excerptLength: 0, asrTermsSent: 0, writingTerms: []))
        }
        return scan
    }

    // MARK: Cache and observers

    func clearCache() { cache.clear() }

    /// Tracks the last external app and clears cached OCR text on app exit, sleep and lock.
    func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (ScreenContextApplication?) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                    .flatMap { $0.activationPolicy == .regular ? ScreenContextApplication($0) : nil }
                Task { @MainActor in handle(app) }
            }))
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] app in self?.activated(app) }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.terminated(app) }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { [weak self] _ in self?.clearCache() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.clearCache() }
        if let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular {
            activated(ScreenContextApplication(front))
        }
    }

    func stopObserving() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func activated(_ app: ScreenContextApplication?) {
        guard let app, app.pid != ProcessInfo.processInfo.processIdentifier,
              app.bundleID == nil || app.bundleID != ownBundleID else { return }
        lastExternalApplication = app
        onApplicationChange?(app)
    }

    func terminated(_ app: ScreenContextApplication?) {
        guard let app else { return }
        cache.remove(pid: app.pid)
        if lastExternalApplication?.pid == app.pid { lastExternalApplication = nil; onApplicationChange?(nil) }
    }

    // MARK: Internals

    /// Complete walk, else partial walk + cached AX; then fresh OCR, else cached OCR.
    private func snapshot(_ record: Take) -> ScreenContextSnapshot? {
        let ax = record.ax ?? ScreenContextSnapshot.merged(partial(record), record.cachedAX, limits: limits)
        return ScreenContextSnapshot.merged(ax, record.ocr ?? record.cachedOCR, limits: limits)
    }

    /// Built lazily from the latest partial collection, at most once per update.
    private func partial(_ record: Take) -> ScreenContextSnapshot? {
        if record.partialStale, let collection = record.axPartial {
            record.partialSnapshot = ScreenContextSnapshot.make(collection: collection, source: .accessibility, bundleID: record.bundleID,
                                                                applicationName: record.name, vocabulary: record.vocabulary, limits: limits, now: now())
            record.partialStale = false
        }
        return record.partialSnapshot
    }

    private func progress(_ id: UUID, _ event: ScreenReadProgress) {
        guard let record = current, record.id == id else { return }
        switch event {
        case .window(let key):
            record.axKey = key
            // Events hop to the main actor separately; a key that arrives after the walk still caches it.
            if let snapshot = record.ax { cache.store(snapshot, key: key, now: now()); return }
            if record.cachedAX == nil, let cached = cache.snapshot(for: key, now: now()) { record.cachedAX = cached }
        case .partial(let collection):
            guard !record.axDone else { return }
            record.axPartial = collection
            record.partialStale = true
            // Enough text already: OCR is not needed, whatever the rest of the walk finds.
            if !ScreenContextPolicy.needsOCR(collection, limits: limits) { record.axNeedsOCR = false }
        }
        signal()
    }

    private func finishAccessibility(_ id: UUID, _ collection: ScreenTextCollection?) {
        guard let record = current, record.id == id else { return }
        record.axDone = true
        record.axElapsed = record.start.duration(to: .now)
        record.axCollection = collection
        record.axNeedsOCR = record.axNeedsOCR && ScreenContextPolicy.needsOCR(collection, limits: limits)
        record.ax = collection.flatMap {
            ScreenContextSnapshot.make(collection: $0, source: .accessibility, bundleID: record.bundleID,
                                       applicationName: record.name, vocabulary: record.vocabulary, limits: limits, now: now())
        }
        // The next take in this window starts from the complete snapshot.
        if let key = record.axKey, let snapshot = record.ax { cache.store(snapshot, key: key, now: now()) }
        signal(); onTakeUpdate?(id)
    }

    private func useCache(_ id: UUID, key: String) {
        guard let record = current, record.id == id, let cached = cache.snapshot(for: key, now: now()) else { return }
        record.cachedOCR = cached
        signal(); onTakeUpdate?(id)
    }

    private func diagnosticRecord(_ record: Take) -> ScreenContextDiagnosticRecord {
        let merged = snapshot(record)
        let ax = record.axCollection ?? record.axPartial
        return ScreenContextDiagnosticRecord(
            kind: .take, date: record.startedAt, takeID: record.id,
            bundleID: record.bundleID, sources: (merged?.sources ?? []).map(\.rawValue),
            nodesVisited: (ax?.nodesVisited ?? 0) + (record.ocrCollection?.nodesVisited ?? 0),
            charactersCollected: (ax?.charactersCollected ?? 0) + (record.ocrCollection?.charactersCollected ?? 0),
            axElapsedMs: record.axElapsed?.roundedMilliseconds, ocrElapsedMs: record.ocrElapsed?.roundedMilliseconds,
            truncated: (ax?.truncated ?? false) || (record.ocrCollection?.truncated ?? false),
            gateHadTerms: record.gateHadTerms, termsOffered: record.offeredTerms, excerptLength: record.excerptLength,
            asrTermsSent: record.asrTermsSent, writingTerms: record.writingTerms)
    }

    private func finishOCR(_ id: UUID, _ collection: ScreenTextCollection?, key: String?) {
        guard let record = current, record.id == id else { return }
        record.ocrPending = false
        record.ocrCollection = collection
        if let started = record.ocrStart { record.ocrElapsed = started.duration(to: .now) }
        if let collection, let snapshot = ScreenContextSnapshot.make(collection: collection, source: .ocr, bundleID: record.bundleID,
                                                                   applicationName: record.name, vocabulary: record.vocabulary,
                                                                   limits: limits, now: now()) {
            record.ocr = snapshot
            if let key { cache.store(snapshot, key: key, now: now()) }
        }
        signal(); onTakeUpdate?(id)
    }

    /// Suspends while `pending` holds for the take, until a change or `deadline`.
    private func wait(_ id: UUID, until deadline: ContinuousClock.Instant, while pending: (Take) -> Bool) async {
        while let record = current, record.id == id, pending(record), ContinuousClock.now < deadline {
            let token = UUID()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[token] = continuation
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    self?.waiters.removeValue(forKey: token)?.resume()
                }
            }
        }
    }

    private func signal() {
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume() }
    }
}

private extension Duration {
    var roundedMilliseconds: Int {
        Int(((Double(components.seconds) + Double(components.attoseconds) / 1e18) * 1000).rounded())
    }
}

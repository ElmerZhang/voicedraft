import UIKit

/// VoiceDraft keyboard: voice only. Hold to talk through the container app, insert the last result, and the four
/// basic keys (globe, space, delete, return). Typing is left to the system keyboard or any other installed keyboard.
///
/// The extension has no microphone and no networking. Without Full Access the voice controls stay visible but
/// disabled, with a one-line explanation; the four basic keys always work.
///
/// Two ways to record, both in the container app:
/// - The app is on standby (`AppStatus` available): hold to talk; `take.start` and `take.stop` Darwin notifications.
/// - Otherwise a tap writes `pending-take.json` and opens `voicedraft://record` through `ContainingAppOpener`
///   (`NSExtensionContext.open`, then the responder chain's `UIApplication`).
///   The app records; when the keyboard reappears it shows "recording in VoiceDraft" with Finish, which posts
///   `take.stop`, and it inserts the `SharedResult` whose id matches the marker.
final class KeyboardViewController: UIInputViewController {
    private enum VoiceState: Equatable {
        case idle
        case connecting
        case recording
        /// The app is recording a take this keyboard opened it for (`pendingTake`).
        case remoteRecording
        case processing
    }

    private var heightConstraint: NSLayoutConstraint?
    private static let takeTimeout: TimeInterval = 60
    /// Processing wait for a take recorded in the app (`pendingTake`).
    private static let remoteProcessingTimeout: TimeInterval = 30
    /// How long the app's `lastError` stays in the status line.
    private static let lastErrorDisplayWindow: TimeInterval = 10 * 60
    private static let pollInterval: TimeInterval = 0.5
    /// A press shorter than this locks recording; the next tap stops it.
    private static let tapLockThreshold: TimeInterval = 0.35

    private let resultStore = SharedResultStore()
    private let statusStore = AppStatusStore()
    private let meterStore = RecordingMeterStore()
    private let appCheck = KeyboardAppCheck()
    private let presenceStore = KeyboardPresenceStore()
    private let pendingStore = PendingTakeStore()
    private let openAttemptStore = KeyboardOpenAttemptStore()
    private lazy var appOpener = ContainingAppOpener(controller: self)

    private let voicePage = VoicePageView()

    private var voiceState: VoiceState = .idle
    private var isLocked = false
    private var pressStartedAt: Date?
    private var takeStartedAt: Date?
    private var stateChangedAt = Date()
    private var baselineResultID: UUID?
    /// Set while waiting for a take recorded through `voicedraft://record`.
    private var pendingTake: PendingTake?
    private var pollTimer: Timer?
    private var hintTimer: Timer?
    private var statusMessage: String?
    private var resultObservation: KeyboardBridge.Observation?
    private var statusObservation: KeyboardBridge.Observation?
    private var meterTimer: Timer?
    private var isVisible = false
    private var activationID: UUID?
    private var lastAppCheckAt = Date.distantPast
    private var mustOpenApp = false

    // MARK: Lifecycle

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        hasDictationKey = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        hasDictationKey = true
    }

    deinit { meterTimer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // VoiceDraft supplies dictation; UIKit should not add a second microphone in its bottom bar.
        hasDictationKey = true

        configureVoicePage()
        voicePage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(voicePage)
        // `voicePage` is a subview of `view` before its constraints are activated.
        let height = view.heightAnchor.constraint(equalToConstant: 320)
        height.priority = UILayoutPriority(999)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            voicePage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            voicePage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            voicePage.topAnchor.constraint(equalTo: view.topAnchor),
            voicePage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        renderVoice()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasDictationKey = true
        isVisible = true
        VDHostNavigation.prepareKeyboard()
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.view.window != nil else { return }
            KeyboardDiagnostics.record("keyboard.host", VDHostNavigation.hostDiagnostic(for: self))
        }
        #endif
        voicePage.voiceEnabled = hasFullAccess
        if hasFullAccess {
            // Lets the app show "Keyboard enabled" instead of the setup guide.
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            try? presenceStore.write(KeyboardPresence(seenAt: Date(), fullAccess: true, version: version))
            resultObservation = KeyboardBridge.observe(KeyboardBridge.resultUpdated) { [weak self] in
                self?.checkForResult()
                self?.refreshInsertButton()
            }
            statusObservation = KeyboardBridge.observe(KeyboardBridge.statusUpdated) { [weak self] in
                self?.checkAppStillAvailable()
                self?.renderVoice()
            }
        }
        refreshInsertButton()
        resumePendingTake()
        renderVoice()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        appCheck.cancel()
        stopMetering()
        resultObservation = nil
        statusObservation = nil
        voicePage.cancelRepeats()
        if pendingTake != nil {
            // The app keeps recording while the user switches apps; the marker brings the state back on reappear.
            suspendRemoteTake()
            return
        }
        // A take in progress belongs to the text field it was started in.
        if voiceState != .idle {
            if voiceState == .recording { KeyboardBridge.post(KeyboardBridge.takeStop) }
            finishTake(message: nil)
        }
    }

    override func viewWillLayoutSubviews() {
        // Modern iPhones supply the globe below the extension. Keep a custom one only when the system needs it.
        voicePage.showsNextKeyboardKey = needsInputModeSwitchKey
        heightConstraint?.constant = traitCollection.verticalSizeClass == .compact ? 216 : (needsInputModeSwitchKey ? 320 : 276)
        super.viewWillLayoutSubviews()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        voicePage.returnKeyTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
    }

    // MARK: Voice page

    private func configureVoicePage() {
        voicePage.onTalkDown = { [weak self] in self?.talkDown() }
        voicePage.onTalkUp = { [weak self] in self?.talkUp() }
        voicePage.onInsertLast = { [weak self] in self?.insertLastResult() }
        voicePage.onSpace = { [weak self] in self?.insert(" ") }
        voicePage.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        voicePage.onReturn = { [weak self] in self?.insert("\n") }
        voicePage.nextKeyboardButton.addTarget(
            self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents
        )
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
    }

    private func refreshInsertButton() {
        let result = hasFullAccess ? resultStore.read() : nil
        voicePage.insertButton.isEnabled = !(result?.text.isEmpty ?? true)
    }

    /// Redraws the talk button and the status line from the take state.
    private func renderVoice() {
        switch voiceState {
        case .idle: voicePage.setTalk(hasFullAccess && (mustOpenApp || !statusStore.isAppAvailable()) ? .idleOpensApp : .idle)
        case .connecting: voicePage.setTalk(.connecting)
        case .remoteRecording: voicePage.setTalk(.remoteRecording)
        case .recording: voicePage.setTalk(isLocked ? .recordingLocked : .recordingHeld)
        case .processing: voicePage.setTalk(.processing)
        }
        voicePage.statusLabel.text = statusMessage ?? stateText()
        updateMetering()
    }

    private func updateMetering() {
        guard isVisible, hasFullAccess, voiceState == .recording || voiceState == .remoteRecording else {
            stopMetering()
            return
        }
        guard meterTimer == nil else { return }
        readMeter()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.readMeter() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func readMeter() {
        let start = pendingTake?.startedAt ?? takeStartedAt ?? stateChangedAt
        let level = meterStore.read()?.usableLevel(for: pendingTake?.id, after: start)
        voicePage.updateRecordingLevel(level)
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        voicePage.updateRecordingLevel(nil)
    }

    private func stateText() -> String {
        switch voiceState {
        case .connecting: return L10n.connecting
        case .recording: return isLocked ? L10n.tapToStop : L10n.releaseToStop
        case .remoteRecording: return L10n.tapToStop
        case .processing: return L10n.processing
        case .idle:
            guard hasFullAccess else { return L10n.needsFullAccess }
            let status = statusStore.read()
            if !mustOpenApp, status?.isAvailable() == true { return L10n.tapToTalk }
            // Standby ended on its own (for example iOS refused to record in the background); the next tap opens the app.
            if let status, let error = status.lastError, !error.isEmpty,
               Date().timeIntervalSince(status.updatedAt) < Self.lastErrorDisplayWindow {
                return error
            }
            return L10n.tapToTalk
        }
    }

    private func showStatus(_ text: String?, autoHide: Bool) {
        hintTimer?.invalidate()
        hintTimer = nil
        statusMessage = text
        if autoHide, text != nil {
            hintTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.statusMessage = nil
                self?.renderVoice()
            }
        }
        renderVoice()
    }

    private func insertLastResult() {
        guard hasFullAccess, let result = resultStore.read(), !result.text.isEmpty else {
            refreshInsertButton()
            return
        }
        insert(result.text)
    }

    /// Press: starts a take, or stops a take locked by a short tap.
    private func talkDown() {
        switch voiceState {
        case .idle:
            guard hasFullAccess else { showStatus(L10n.needsFullAccess, autoHide: true); return }
            isLocked = false
            activationID = UUID()
            pressStartedAt = Date()
            if mustOpenApp || !statusStore.isAppAvailable() {
                openAppForTake()
                return
            }
            checkAppBeforeStarting()
        case .connecting:
            break
        case .recording:
            if isLocked { stopTake() }
        case .remoteRecording:
            stopRemoteTake()
        case .processing:
            break
        }
    }

    /// Release: stops the take, unless the press was a short tap, which locks recording until the next tap.
    private func talkUp() {
        if voiceState == .connecting {
            // A quick tap still locks after the reply arrives. Releasing a long hold before any start cancels it.
            guard pendingTake == nil, let started = pressStartedAt else { return }
            if Date().timeIntervalSince(started) < Self.tapLockThreshold {
                isLocked = true
                pressStartedAt = nil
            } else {
                finishTake(message: nil)
            }
            return
        }
        guard voiceState == .recording, !isLocked, let started = pressStartedAt else { return }
        pressStartedAt = nil
        if Date().timeIntervalSince(started) < Self.tapLockThreshold {
            isLocked = true
            renderVoice()
        } else {
            stopTake()
        }
    }

    // MARK: Voice take

    private func checkAppBeforeStarting() {
        let activation = activationID
        transition(to: .connecting)
        showStatus(nil, autoHide: false)
        KeyboardDiagnostics.record("keyboard.app-check.start")
        appCheck.start { [weak self] reply in
            guard let self, self.isVisible, self.activationID == activation, self.voiceState == .connecting else { return }
            self.lastAppCheckAt = Date()
            KeyboardDiagnostics.record("keyboard.app-check.result", reply?.state.rawValue ?? "timeout")
            switch reply?.state {
            case .ready:
                self.mustOpenApp = false
                self.startTake()
            case .busy:
                self.finishTake(message: L10n.appBusy)
            case .unavailable, .none:
                self.mustOpenApp = true
                self.openAppForTake()
            }
        }
    }

    private func startTake() {
        guard hasFullAccess else {
            finishTake(message: L10n.needsFullAccess)
            return
        }
        guard statusStore.isAppAvailable() else {
            openAppForTake()
            return
        }
        baselineResultID = resultStore.read()?.id
        takeStartedAt = Date()
        KeyboardBridge.post(KeyboardBridge.takeStart)
        transition(to: .recording)
        showStatus(nil, autoHide: false)
        startPolling()
    }

    private func stopTake() {
        KeyboardBridge.post(KeyboardBridge.takeStop)
        transition(to: .processing)
        showStatus(nil, autoHide: false)
        lastAppCheckAt = .distantPast
        checkAppStillAvailable()
    }

    // MARK: Take recorded in the app

    /// Writes the pending marker and opens `voicedraft://record` through `ContainingAppOpener`. The outcome is shown
    /// in the status line and appended to `open-attempts.json`, because iOS may refuse every strategy and nothing
    /// else would reveal it on the phone.
    private func openAppForTake() {
        appCheck.cancel()
        let activation = activationID
        let host = VDHostNavigation.hostBundleIdentifier(for: self)
        let take = PendingTake(hostBundleIdentifier: host)
        KeyboardDiagnostics.record("keyboard.open", "take=\(take.id) host=\(host ?? "unresolved")")
        guard let url = KeyboardRecordLink.url(for: take), (try? pendingStore.write(take)) != nil else {
            finishTake(message: L10n.openRefused)
            return
        }
        // Set the marker locally before opening: viewWillDisappear can run before the open completion.
        pendingTake = take
        transition(to: .connecting)
        showStatus(L10n.opening, autoHide: false)
        appOpener.open(url) { [weak self] outcome in
            try? self?.openAttemptStore.append(outcome.attempts)
            guard let self, self.activationID == activation else { return }
            if let strategy = outcome.succeeded {
                self.mustOpenApp = false
                // The next appearance resumes the persisted marker; never restart timers off screen.
                guard self.isVisible else { self.activationID = nil; return }
                self.pendingTake = take
                self.lastAppCheckAt = Date()
                self.transition(to: .remoteRecording)
                // Shown briefly, then the "recording in VoiceDraft" state text returns.
                self.showStatus(L10n.opened(method: strategy.number), autoHide: true)
                self.startPolling()
            } else {
                if self.pendingStore.read()?.id == take.id { self.pendingStore.clear() }
                self.finishTake(message: L10n.openFailed(KeyboardOpenSequence.summary(outcome.attempts)))
            }
        }
    }

    /// Finish for a take recorded in the app: posts `take.stop` only while the app status shows it working on this
    /// take; otherwise drops the marker instead of waiting in "processing" for a result that cannot arrive.
    private func stopRemoteTake() {
        guard let take = pendingTake, statusStore.read()?.isWorking(onTake: take.id) == true else {
            pendingStore.clear()
            finishTake(message: L10n.takeNotStarted)
            return
        }
        stopTake()
    }

    /// Applies the pending marker when the keyboard appears: resume, insert the finished result, or drop a stale marker.
    private func resumePendingTake() {
        guard hasFullAccess else { return }
        switch KeyboardResumeDecision.decide(pending: pendingStore.read(), latest: resultStore.read(),
                                             status: statusStore.read()) {
        case .none:
            break
        case .clear:
            pendingStore.clear()
            if voiceState != .idle { finishTake(message: nil) }
        case .notStarted:
            // The app is not working on this take, so Finish would wait for a result that never comes.
            pendingStore.clear()
            finishTake(message: L10n.takeNotStarted)
        case .insert(let result):
            pendingStore.clear()
            pendingTake = nil
            if !result.text.isEmpty { insert(result.text) }
            if voiceState != .idle { finishTake(message: nil) }
            refreshInsertButton()
        case .resume(let take):
            activationID = UUID()
            pendingTake = take
            lastAppCheckAt = .distantPast
            if voiceState == .idle {
                transition(to: statusStore.read()?.state == .processing ? .processing : .remoteRecording)
            }
            startPolling()
        }
    }

    /// The keyboard is going away while the app records; keep the marker, stop local timers.
    private func suspendRemoteTake() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingTake = nil
        voiceState = .idle
        statusMessage = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func transition(to state: VoiceState) {
        voiceState = state
        stateChangedAt = Date()
        renderVoice()
    }

    private func poll() {
        guard voiceState != .idle else { return }
        if checkForResult() { return }
        if let take = pendingTake {
            if take.isStale() {
                pendingStore.clear()
                finishTake(message: L10n.timedOut)
            } else if voiceState == .remoteRecording, statusStore.read()?.state == .processing {
                // Finished in the app instead of here.
                transition(to: .processing)
            } else if voiceState == .processing,
                      Date().timeIntervalSince(stateChangedAt) > Self.remoteProcessingTimeout {
                pendingStore.clear()
                finishTake(message: L10n.timedOut)
            }
            checkAppStillAvailable()
            return
        }
        if Date().timeIntervalSince(stateChangedAt) > Self.takeTimeout {
            if voiceState == .recording { KeyboardBridge.post(KeyboardBridge.takeStop) }
            finishTake(message: L10n.timedOut)
            return
        }
        checkAppStillAvailable()
    }

    /// Inserts the latest result if it was produced for the current take. Returns true when it did.
    @discardableResult
    private func checkForResult() -> Bool {
        guard voiceState != .idle, let result = resultStore.read() else { return false }
        if let take = pendingTake {
            guard result.id == take.id else { return false }
            pendingStore.clear()
        } else {
            guard let startedAt = takeStartedAt else { return false }
            // ISO 8601 dates in the file have whole-second precision, so compare against the start second.
            let startSecond = Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded(.down))
            guard result.id != baselineResultID, result.createdAt >= startSecond else { return false }
        }
        if !result.text.isEmpty {
            insert(result.text)
        }
        finishTake(message: nil)
        refreshInsertButton()
        return true
    }

    private func checkAppStillAvailable() {
        guard isVisible, voiceState == .recording || voiceState == .remoteRecording || voiceState == .processing,
              !appCheck.isChecking, Date().timeIntervalSince(lastAppCheckAt) >= 2 else { return }
        let activation = activationID
        lastAppCheckAt = Date()
        appCheck.start { [weak self] reply in
            guard let self, self.isVisible, self.activationID == activation else { return }
            // A completed result wins even when the app has already become idle or exited.
            if self.checkForResult() { return }
            if let reply, reply.state == .busy,
               self.pendingTake == nil || reply.takeID == self.pendingTake?.id {
                self.mustOpenApp = false
                return
            }
            self.mustOpenApp = reply == nil || reply?.state == .unavailable
            KeyboardDiagnostics.record("keyboard.app-lost", reply?.state.rawValue ?? "timeout")
            if reply == nil, self.voiceState == .recording || self.voiceState == .remoteRecording {
                // A temporarily blocked app may recover after our deadline; do not leave its mic running.
                KeyboardBridge.post(KeyboardBridge.takeStop)
            }
            self.finishTake(message: L10n.connectionLost)
        }
    }

    private func finishTake(message: String?) {
        appCheck.cancel()
        activationID = nil
        if let pendingTake, pendingStore.read()?.id == pendingTake.id { pendingStore.clear() }
        pollTimer?.invalidate()
        pollTimer = nil
        takeStartedAt = nil
        baselineResultID = nil
        pendingTake = nil
        pressStartedAt = nil
        isLocked = false
        transition(to: .idle)
        showStatus(message, autoHide: true)
    }

    private static func returnTitle(for type: UIReturnKeyType?) -> String {
        switch type {
        case .go: return L10n.returnGo
        case .search, .google, .yahoo: return L10n.returnSearch
        case .send: return L10n.returnSend
        case .done: return L10n.returnDone
        case .next: return L10n.returnNext
        default: return L10n.returnDefault
        }
    }
}

/// Localized UI strings, loaded from the extension bundle.
enum L10n {
    private static let bundle = Bundle(for: KeyboardViewController.self)

    private static func string(_ key: String, _ comment: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, comment: comment)
    }

    static var needsFullAccess: String { string("keyboard.hint.fullAccess", "Shown when voice is used without Full Access") }
    static var openApp: String { string("keyboard.hint.openApp", "Shown when the container app is not listening") }
    static var listening: String { string("keyboard.status.listening", "Status while the app listens and the keyboard is idle") }
    static var recording: String { string("keyboard.status.recording", "Status while the app records") }
    static var processing: String { string("keyboard.status.processing", "Status while the app processes the take") }
    static var connecting: String { string("keyboard.status.connecting", "Checking the app before starting voice input") }
    static var connectionLost: String { string("keyboard.status.connectionLost", "The app stopped replying during a take") }
    static var appBusy: String { string("keyboard.status.appBusy", "The app is already working on another take") }
    static var timedOut: String { string("keyboard.status.timedOut", "Shown when no result arrives in time") }
    static var recordingInApp: String { string("keyboard.status.recordingInApp", "Status while VoiceDraft records a take this keyboard opened it for") }
    static var opensAppHint: String { string("keyboard.status.opensApp", "Status when a tap will open VoiceDraft to record") }
    static var opening: String { string("keyboard.status.opening", "Status right after the keyboard asked iOS to open VoiceDraft") }
    static var openRefused: String { string("keyboard.status.openRefused", "Shown when iOS refused to open VoiceDraft from the keyboard") }
    static func opened(method: Int) -> String {
        String(format: string("keyboard.status.opened", "Shown briefly after VoiceDraft opened; %d is the strategy number"), method)
    }
    static var takeNotStarted: String { string("keyboard.status.takeNotStarted", "Shown when the take the keyboard opened VoiceDraft for is not running") }
    static func openFailed(_ summary: String) -> String {
        String(format: string("keyboard.status.openFailed", "Shown when every way to open VoiceDraft failed; %@ lists each result"), summary)
    }
    static var tapOpensApp: String { string("keyboard.voice.tapOpensApp", "Talk button title when a tap opens VoiceDraft") }
    static var finish: String { string("keyboard.voice.finish", "Talk button title that finishes a take recorded in VoiceDraft") }
    static var holdToTalk: String { string("keyboard.voice.hold", "Title of the hold-to-talk button") }
    static var tapToTalk: String { string("keyboard.voice.tap", "Instruction above the microphone") }
    static var holdHint: String { string("keyboard.voice.holdHint", "Secondary hint for press-and-hold recording") }
    static var releaseToStop: String { string("keyboard.voice.release", "Title of the talk button while held") }
    static var tapToStop: String { string("keyboard.voice.tapToStop", "Title of the talk button after a short tap locked recording") }
    static var insertLast: String { string("keyboard.button.insertLast", "Button that inserts the latest result") }
    static var micStart: String { string("keyboard.button.micStart", "Accessibility label of the talk button") }
    static var micStop: String { string("keyboard.button.micStop", "Accessibility label of the talk button while recording") }
    static var nextKeyboard: String { string("keyboard.button.nextKeyboard", "Accessibility label of the globe key") }
    static var delete: String { string("keyboard.key.delete", "Accessibility label of the delete key") }
    static var space: String { string("keyboard.key.space", "Title of the space bar") }
    static var returnDefault: String { string("keyboard.key.return", "Title of the return key") }
    static var returnGo: String { string("keyboard.key.go", "Return key title for Go") }
    static var returnSearch: String { string("keyboard.key.search", "Return key title for Search") }
    static var returnSend: String { string("keyboard.key.send", "Return key title for Send") }
    static var returnDone: String { string("keyboard.key.done", "Return key title for Done") }
    static var returnNext: String { string("keyboard.key.next", "Return key title for Next") }
}

import UIKit

/// VoiceDraft keyboard: basic Latin typing, keyboard switching, inserting the last shared result,
/// and starting or stopping a take in the container app through `KeyboardBridge`.
///
/// The extension has no microphone and no networking. Without Full Access it can only type.
final class KeyboardViewController: UIInputViewController {
    private enum VoiceState: Equatable {
        case idle
        case recording
        case processing
    }

    private static let keyboardHeight: CGFloat = 260
    private static let takeTimeout: TimeInterval = 60
    private static let pollInterval: TimeInterval = 0.5

    private let resultStore = SharedResultStore()
    private let statusStore = AppStatusStore()

    private let statusLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let keysView = KeyboardKeysView()

    private var voiceState: VoiceState = .idle
    private var takeStartedAt: Date?
    private var stateChangedAt = Date()
    private var baselineResultID: UUID?
    private var pollTimer: Timer?
    private var hintTimer: Timer?
    private var resultObservation: KeyboardBridge.Observation?
    private var statusObservation: KeyboardBridge.Observation?

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        keysView.onInsert = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        keysView.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        keysView.onReturn = { [weak self] in self?.textDocumentProxy.insertText("\n") }
        keysView.nextKeyboardButton.addTarget(
            self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents
        )

        let topBar = makeTopBar()
        let stack = UIStackView(arrangedSubviews: [topBar, keysView])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let height = view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            topBar.heightAnchor.constraint(equalToConstant: 36),
        ])

        updateMicButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasFullAccess {
            resultObservation = KeyboardBridge.observe(KeyboardBridge.resultUpdated) { [weak self] in
                self?.checkForResult()
                self?.refreshInsertButton()
            }
            statusObservation = KeyboardBridge.observe(KeyboardBridge.statusUpdated) { [weak self] in
                self?.checkAppStillAvailable()
            }
        }
        refreshInsertButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resultObservation = nil
        statusObservation = nil
        // A take in progress belongs to the text field it was started in.
        if voiceState != .idle {
            if voiceState == .recording { KeyboardBridge.post(KeyboardBridge.takeStop) }
            finishTake(message: nil)
        }
    }

    override func viewWillLayoutSubviews() {
        keysView.nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        keysView.returnKeyTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
    }

    // MARK: Top bar

    private func makeTopBar() -> UIView {
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        insertButton.setImage(UIImage(systemName: "text.insert"), for: .normal)
        insertButton.setTitle(" " + L10n.insertLast, for: .normal)
        insertButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        insertButton.accessibilityLabel = L10n.insertLast
        insertButton.addTarget(self, action: #selector(insertLastResult), for: .touchUpInside)
        insertButton.setContentHuggingPriority(.required, for: .horizontal)
        insertButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        micButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20), forImageIn: .normal)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.setContentHuggingPriority(.required, for: .horizontal)
        micButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let bar = UIStackView(arrangedSubviews: [statusLabel, insertButton, micButton])
        bar.axis = .horizontal
        bar.spacing = 8
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 4)
        return bar
    }

    private func refreshInsertButton() {
        let result = hasFullAccess ? resultStore.read() : nil
        insertButton.isEnabled = !(result?.text.isEmpty ?? true)
    }

    private func updateMicButton() {
        switch voiceState {
        case .idle:
            micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            micButton.tintColor = .label
            micButton.isEnabled = true
            micButton.accessibilityLabel = L10n.micStart
        case .recording:
            micButton.setImage(UIImage(systemName: "stop.circle.fill"), for: .normal)
            micButton.tintColor = .systemRed
            micButton.isEnabled = true
            micButton.accessibilityLabel = L10n.micStop
        case .processing:
            micButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            micButton.tintColor = .secondaryLabel
            micButton.isEnabled = false
            micButton.accessibilityLabel = L10n.processing
        }
    }

    private func showStatus(_ text: String?, autoHide: Bool) {
        hintTimer?.invalidate()
        hintTimer = nil
        statusLabel.text = text
        if autoHide, text != nil {
            hintTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                guard let self, self.voiceState == .idle else { return }
                self.statusLabel.text = nil
            }
        }
    }

    // MARK: Actions

    @objc private func insertLastResult() {
        guard hasFullAccess, let result = resultStore.read(), !result.text.isEmpty else {
            refreshInsertButton()
            return
        }
        textDocumentProxy.insertText(result.text)
    }

    @objc private func micTapped() {
        switch voiceState {
        case .idle:
            startTake()
        case .recording:
            KeyboardBridge.post(KeyboardBridge.takeStop)
            transition(to: .processing)
            showStatus(L10n.processing, autoHide: false)
        case .processing:
            break
        }
    }

    // MARK: Voice take

    private func startTake() {
        guard hasFullAccess else {
            showStatus(L10n.needsFullAccess, autoHide: true)
            return
        }
        guard statusStore.isAppAvailable() else {
            showStatus(L10n.openApp, autoHide: true)
            return
        }
        baselineResultID = resultStore.read()?.id
        takeStartedAt = Date()
        KeyboardBridge.post(KeyboardBridge.takeStart)
        transition(to: .recording)
        showStatus(L10n.recording, autoHide: false)

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func transition(to state: VoiceState) {
        voiceState = state
        stateChangedAt = Date()
        updateMicButton()
    }

    private func poll() {
        guard voiceState != .idle else { return }
        if checkForResult() { return }
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
        guard voiceState != .idle, let startedAt = takeStartedAt, let result = resultStore.read() else {
            return false
        }
        // ISO 8601 dates in the file have whole-second precision, so compare against the start second.
        let startSecond = Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded(.down))
        guard result.id != baselineResultID, result.createdAt >= startSecond else { return false }
        if !result.text.isEmpty {
            textDocumentProxy.insertText(result.text)
        }
        finishTake(message: nil)
        refreshInsertButton()
        return true
    }

    private func checkAppStillAvailable() {
        guard voiceState != .idle, !statusStore.isAppAvailable() else { return }
        // Give a just-finished result a chance before reporting the app as gone.
        if checkForResult() { return }
        finishTake(message: L10n.openApp)
    }

    private func finishTake(message: String?) {
        pollTimer?.invalidate()
        pollTimer = nil
        takeStartedAt = nil
        baselineResultID = nil
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
    static var recording: String { string("keyboard.status.recording", "Status while the app records") }
    static var processing: String { string("keyboard.status.processing", "Status while the app processes the take") }
    static var timedOut: String { string("keyboard.status.timedOut", "Shown when no result arrives in time") }
    static var insertLast: String { string("keyboard.button.insertLast", "Button that inserts the latest result") }
    static var micStart: String { string("keyboard.button.micStart", "Accessibility label of the mic button") }
    static var micStop: String { string("keyboard.button.micStop", "Accessibility label of the stop button") }
    static var nextKeyboard: String { string("keyboard.button.nextKeyboard", "Accessibility label of the globe key") }
    static var shift: String { string("keyboard.key.shift", "Accessibility label of the shift key") }
    static var delete: String { string("keyboard.key.delete", "Accessibility label of the delete key") }
    static var space: String { string("keyboard.key.space", "Title of the space bar") }
    static var returnDefault: String { string("keyboard.key.return", "Title of the return key") }
    static var returnGo: String { string("keyboard.key.go", "Return key title for Go") }
    static var returnSearch: String { string("keyboard.key.search", "Return key title for Search") }
    static var returnSend: String { string("keyboard.key.send", "Return key title for Send") }
    static var returnDone: String { string("keyboard.key.done", "Return key title for Done") }
    static var returnNext: String { string("keyboard.key.next", "Return key title for Next") }
}

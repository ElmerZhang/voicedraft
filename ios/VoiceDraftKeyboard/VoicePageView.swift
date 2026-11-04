import UIKit

/// A voice-first keyboard with deletion above the recording surface and submission below it.
/// Touch handling remains in `KeyboardViewController`; this view never starts audio or changes a take.
/// The header also holds the Ask anything toggle. An answer replaces the recording surface with a read-only answer
/// and an Insert / Copy / Close row in place of the bottom row, so nothing is inserted without a tap.
final class VoicePageView: UIView {
    enum TalkAppearance {
        case idle
        case idleOpensApp
        case connecting
        case remoteRecording
        case recordingHeld
        case recordingLocked
        case processing
    }

    var onTalkDown: (() -> Void)?
    var onTalkUp: (() -> Void)?
    var onInsertLast: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    var onAskToggle: (() -> Void)?
    var onAnswerInsert: (() -> Void)?
    var onAnswerCopy: (() -> Void)?
    var onAnswerClose: (() -> Void)?

    let statusLabel = UILabel()
    let insertButton = KeyButton(style: .secondary)
    let nextKeyboardButton = KeyButton(style: .plain)
    private let brandLabel = UILabel()
    private let detailLabel = UILabel()
    private let waveformView = RecordingWaveformView()
    private let talkButton = UIButton(type: .custom)
    private let spaceButton = KeyButton(style: .secondary)
    private let deleteButton = KeyButton(style: .secondary)
    private let returnButton = KeyButton(style: .accent)
    private let deleteRepeater = KeyRepeater()
    private let askButton = KeyButton(style: .secondary)
    private let answerTextView = UITextView()
    private let answerInsertButton = KeyButton(style: .accent)
    private let answerCopyButton = KeyButton(style: .secondary)
    private let answerCloseButton = KeyButton(style: .secondary)
    private var talkAppearance: TalkAppearance = .idle

    /// Ask anything is on: the talk surface says "ask" and the controller sends the selection as reference.
    var askEnabled = false {
        didSet { updateAskButton(); setTalk(talkAppearance) }
    }

    /// The host has selected text; while Ask is on, the detail line says it will be sent as reference.
    var referenceSelected = false {
        didSet { if referenceSelected != oldValue { setTalk(talkAppearance) } }
    }

    /// The answer shown in the answer panel; nil shows the recording surface.
    private(set) var answerText: String?
    var showsNextKeyboardKey = true {
        didSet {
            nextKeyboardButton.isHidden = !showsNextKeyboardKey
            setNeedsLayout()
        }
    }

    var returnKeyTitle: String = L10n.returnDefault {
        didSet {
            returnButton.setTitle(returnKeyTitle, for: .normal)
            returnButton.accessibilityLabel = returnKeyTitle
        }
    }

    /// False without Full Access: recording remains visible but unavailable; editing keys still work.
    var voiceEnabled = true {
        didSet { updateTalkAvailability() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        // Let the system keyboard supply its backdrop, including its appearance and translucency.
        backgroundColor = .clear
        brandLabel.text = "VoiceDraft"
        brandLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        brandLabel.textColor = .secondaryLabel
        brandLabel.textAlignment = .left

        statusLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 18, weight: .semibold), maximumPointSize: 24)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .label
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.75
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .left
        detailLabel.numberOfLines = 2
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.8

        talkButton.addTarget(self, action: #selector(talkDown), for: .touchDown)
        talkButton.addTarget(self, action: #selector(talkUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        talkButton.accessibilityIdentifier = "keyboard.talk"
        talkButton.contentHorizontalAlignment = .leading

        insertButton.setImage(UIImage(systemName: "text.insert"), for: .normal)
        insertButton.accessibilityLabel = L10n.insertLast
        insertButton.accessibilityIdentifier = "keyboard.insertLast"
        insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.setPreferredSymbolConfiguration(.init(pointSize: 28, weight: .regular), forImageIn: .normal)
        nextKeyboardButton.accessibilityLabel = L10n.nextKeyboard

        spaceButton.setTitle(L10n.space, for: .normal)
        spaceButton.titleLabel?.font = .systemFont(ofSize: 15)
        spaceButton.accessibilityLabel = L10n.space
        spaceButton.accessibilityIdentifier = "keyboard.space"
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        var deleteConfiguration = UIButton.Configuration.plain()
        deleteConfiguration.image = UIImage(systemName: "delete.left")
        deleteConfiguration.title = L10n.delete
        deleteConfiguration.imagePadding = 6
        deleteConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        deleteConfiguration.titleLineBreakMode = .byClipping
        deleteConfiguration.baseForegroundColor = .label
        deleteConfiguration.preferredSymbolConfigurationForImage = .init(pointSize: 18)
        deleteConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 14, weight: .medium)
            return attributes
        }
        deleteButton.configuration = deleteConfiguration
        deleteButton.accessibilityLabel = L10n.delete
        deleteButton.accessibilityIdentifier = "keyboard.delete"
        deleteButton.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        returnButton.setTitle(returnKeyTitle, for: .normal)
        returnButton.accessibilityLabel = returnKeyTitle
        returnButton.accessibilityIdentifier = "keyboard.return"
        returnButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        returnButton.titleLabel?.adjustsFontSizeToFitWidth = true
        returnButton.titleLabel?.minimumScaleFactor = 0.75
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        var askConfiguration = UIButton.Configuration.plain()
        askConfiguration.image = UIImage(systemName: "bubble.left.and.bubble.right")
        askConfiguration.title = L10n.askShort
        askConfiguration.imagePadding = 4
        askConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        askConfiguration.titleLineBreakMode = .byClipping
        askConfiguration.preferredSymbolConfigurationForImage = .init(pointSize: 15)
        askConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 14, weight: .medium)
            return attributes
        }
        askButton.configuration = askConfiguration
        askButton.accessibilityLabel = L10n.askAnything
        askButton.accessibilityIdentifier = "keyboard.ask"
        askButton.addTarget(self, action: #selector(askTapped), for: .touchUpInside)
        updateAskButton()

        answerTextView.isEditable = false
        answerTextView.isSelectable = false
        answerTextView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 20)
        answerTextView.adjustsFontForContentSizeCategory = true
        answerTextView.textColor = .label
        answerTextView.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1) : UIColor.white.withAlphaComponent(0.65)
        }
        answerTextView.layer.cornerRadius = 16
        answerTextView.layer.cornerCurve = .continuous
        answerTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        answerTextView.accessibilityIdentifier = "keyboard.answer"
        for (button, title, identifier, action) in [
            (answerInsertButton, L10n.answerInsert, "keyboard.answer.insert", #selector(answerInsertTapped)),
            (answerCopyButton, L10n.answerCopy, "keyboard.answer.copy", #selector(answerCopyTapped)),
            (answerCloseButton, L10n.answerClose, "keyboard.answer.close", #selector(answerCloseTapped)),
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            button.accessibilityLabel = title
            button.accessibilityIdentifier = identifier
            button.addTarget(self, action: action, for: .touchUpInside)
        }

        // Labels sit over the recording surface but do not intercept its touch-down/up gestures.
        [brandLabel, talkButton, statusLabel, detailLabel, waveformView, insertButton,
         nextKeyboardButton, spaceButton, deleteButton, returnButton, askButton,
         answerTextView, answerInsertButton, answerCopyButton, answerCloseButton].forEach(addSubview)
        accessibilityElements = [brandLabel, askButton, deleteButton, statusLabel, talkButton, detailLabel,
                                 answerTextView, insertButton, spaceButton, returnButton,
                                 answerInsertButton, answerCopyButton, answerCloseButton, nextKeyboardButton]
        setTalk(.idle)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        let compact = height < 240
        let inset: CGFloat = 16
        let headerY: CGFloat = compact ? 8 : 12
        deleteButton.frame = CGRect(x: width - inset - 104, y: headerY, width: 104, height: 44)
        askButton.frame = CGRect(x: deleteButton.frame.minX - 8 - 80, y: headerY, width: 80, height: 44)
        brandLabel.frame = CGRect(x: inset + 4, y: headerY, width: askButton.frame.minX - inset - 12, height: 44)

        // Delete and return never share a row, even in compact layouts. The recording surface separates
        // the two targets so a small horizontal slip while deleting cannot send the host's message.
        let key: CGFloat = 48
        let rowY = compact ? height - 56 : height - (showsNextKeyboardKey ? 104 : 60)
        nextKeyboardButton.frame = CGRect(x: inset, y: compact ? rowY : height - 48, width: 44, height: 44)
        let insertX = compact && showsNextKeyboardKey ? inset + 52 : inset
        insertButton.frame = CGRect(x: insertX, y: rowY, width: 48, height: key)
        returnButton.frame = CGRect(x: width - inset - 88, y: rowY, width: 88, height: key)
        let spaceX = insertButton.frame.maxX + 8
        spaceButton.frame = CGRect(x: spaceX, y: rowY, width: returnButton.frame.minX - spaceX - 12, height: key)

        let talkY = deleteButton.frame.maxY + (compact ? 12 : 16)
        talkButton.frame = CGRect(x: inset, y: talkY, width: width - inset * 2,
                                  height: rowY - talkY - (compact ? 12 : 20))
        let hasDetail = !detailLabel.isHidden
        let statusHeight: CGFloat = voiceEnabled ? (compact ? 38 : 48) : talkButton.bounds.height - 16
        let detailHeight: CGFloat = !waveformView.isHidden ? (compact ? 30 : 42) : (hasDetail ? 30 : 0)
        let textY = talkButton.frame.midY - (statusHeight + detailHeight) / 2
        statusLabel.frame = CGRect(x: inset + 76, y: textY, width: talkButton.bounds.width - 92, height: statusHeight)
        detailLabel.frame = CGRect(x: statusLabel.frame.minX, y: statusLabel.frame.maxY,
                                   width: statusLabel.bounds.width, height: detailHeight)
        waveformView.frame = CGRect(x: statusLabel.frame.minX, y: statusLabel.frame.maxY,
                                    width: min(240, statusLabel.bounds.width), height: detailHeight)

        // The answer panel takes the recording surface; its buttons take the bottom row (never the header row).
        answerTextView.frame = talkButton.frame
        let answerButtons = [answerInsertButton, answerCopyButton, answerCloseButton]
        let rowWidth = width - inset - insertX
        let buttonWidth = (rowWidth - 8 * CGFloat(answerButtons.count - 1)) / CGFloat(answerButtons.count)
        for (index, button) in answerButtons.enumerated() {
            button.frame = CGRect(x: insertX + CGFloat(index) * (buttonWidth + 8), y: rowY, width: buttonWidth, height: key)
        }
    }

    /// Shows `text` in the answer panel in place of the recording surface, or the recording surface again for nil.
    func showAnswer(_ text: String?) {
        answerText = text
        answerTextView.text = text
        answerTextView.setContentOffset(.zero, animated: false)
        answerCopyButton.setTitle(L10n.answerCopy, for: .normal)
        answerCopyButton.accessibilityLabel = L10n.answerCopy
        brandLabel.text = text == nil ? "VoiceDraft" : L10n.answerTitle
        updateTalkAvailability()
        if text != nil { UIAccessibility.post(notification: .layoutChanged, argument: answerTextView) }
    }

    /// The Copy button reads "Copied" while `copied` is true; `showAnswer` resets it.
    func showCopied(_ copied: Bool) {
        let title = copied ? L10n.answerCopied : L10n.answerCopy
        answerCopyButton.setTitle(title, for: .normal)
        answerCopyButton.accessibilityLabel = title
    }

    private func updateAskButton() {
        guard var configuration = askButton.configuration else { return }
        configuration.baseForegroundColor = askEnabled ? .systemBlue : .label
        configuration.background.backgroundColor = askEnabled ? UIColor.systemBlue.withAlphaComponent(0.18) : .clear
        configuration.background.cornerRadius = 12
        askButton.configuration = configuration
        askButton.accessibilityTraits = askEnabled ? [.button, .selected] : .button
        askButton.isEnabled = voiceEnabled
    }

    func setTalk(_ appearance: TalkAppearance) {
        talkAppearance = appearance
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 24
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 32, weight: .medium)
        detailLabel.text = nil
        switch appearance {
        case .idle:
            configuration.image = UIImage(systemName: askEnabled ? "bubble.left.and.bubble.right.fill" : "mic.fill")
            talkButton.accessibilityLabel = askEnabled ? L10n.holdToAsk : L10n.micStart
            detailLabel.text = askEnabled && referenceSelected ? L10n.referenceHint : L10n.holdHint
        case .idleOpensApp:
            configuration.image = UIImage(systemName: askEnabled ? "bubble.left.and.bubble.right.fill" : "mic.fill")
            talkButton.accessibilityLabel = askEnabled ? L10n.tapToAskOpensApp : L10n.tapOpensApp
            detailLabel.text = askEnabled && referenceSelected ? L10n.referenceHint : L10n.opensAppHint
        case .connecting:
            configuration.showsActivityIndicator = true
            talkButton.accessibilityLabel = L10n.connecting
        case .remoteRecording, .recordingLocked:
            configuration.image = UIImage(systemName: "stop.fill")
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 24, weight: .medium)
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
            talkButton.accessibilityLabel = L10n.micStop
        case .recordingHeld:
            configuration.image = UIImage(systemName: "mic.fill")
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
            talkButton.accessibilityLabel = L10n.micStop
        case .processing:
            configuration.showsActivityIndicator = true
            talkButton.accessibilityLabel = L10n.processing
        }
        if askEnabled, appearance == .idle || appearance == .idleOpensApp {
            // The bubbles glyph is about half again as wide as the microphone; a smaller size keeps it inside the
            // icon column instead of running under the status text.
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 24, weight: .medium)
        }
        talkButton.configuration = configuration
        updateTalkAvailability()
    }

    private func updateTalkAvailability() {
        talkButton.isEnabled = voiceEnabled && talkAppearance != .processing
        talkButton.alpha = voiceEnabled ? 1 : 0.35
        statusLabel.textColor = voiceEnabled && talkAppearance != .processing ? .white : .label
        statusLabel.numberOfLines = voiceEnabled ? 2 : 3
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        detailLabel.isHidden = !voiceEnabled || detailLabel.text == nil
        waveformView.isHidden = !voiceEnabled || !isRecording
        askButton.isEnabled = voiceEnabled
        let answering = answerText != nil
        for view in [talkButton, statusLabel, insertButton, spaceButton, returnButton] as [UIView] { view.isHidden = answering }
        if answering {
            detailLabel.isHidden = true
            waveformView.isHidden = true
        }
        for view in [answerTextView, answerInsertButton, answerCopyButton, answerCloseButton] as [UIView] {
            view.isHidden = !answering
        }
        if waveformView.isHidden { waveformView.update(level: nil) }
        setNeedsLayout()
    }

    private var isRecording: Bool {
        talkAppearance == .recordingHeld || talkAppearance == .recordingLocked || talkAppearance == .remoteRecording
    }

    func updateRecordingLevel(_ level: Double?) {
        waveformView.update(level: isRecording && voiceEnabled ? level : nil)
    }

    func cancelRepeats() { deleteRepeater.stop() }
    @objc private func talkDown() { onTalkDown?() }
    @objc private func talkUp() { onTalkUp?() }
    @objc private func insertTapped() { onInsertLast?() }
    @objc private func spaceTapped() { onSpace?() }
    @objc private func returnTapped() { onReturn?() }
    @objc private func askTapped() { onAskToggle?() }
    @objc private func answerInsertTapped() { onAnswerInsert?() }
    @objc private func answerCopyTapped() { onAnswerCopy?() }
    @objc private func answerCloseTapped() { onAnswerClose?() }
    @objc private func deleteDown() { deleteRepeater.start { [weak self] in self?.onDelete?() } }
    @objc private func deleteUp() { deleteRepeater.stop() }
}

/// A continuous curve whose whole envelope follows the current measured input level.
/// Phase advances only on meter updates; silence is flat and missing/stale input resets immediately.
private final class RecordingWaveformView: UIView {
    private let curve = CAShapeLayer()
    private var amplitude: CGFloat = 0
    private var phase: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        curve.fillColor = UIColor.clear.cgColor
        curve.strokeColor = UIColor.white.cgColor
        curve.lineWidth = 2.5
        curve.lineCap = .round
        curve.lineJoin = .round
        layer.addSublayer(curve)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        curve.frame = bounds
        CATransaction.commit()
        render(animated: false)
    }

    func update(level: Double?) {
        guard let level, level.isFinite else {
            amplitude = 0
            phase = 0
            render(animated: false)
            return
        }
        // Boost quiet/normal speech smoothly, retaining headroom for louder input and exact zero for silence.
        let input = min(1, max(0, level))
        let boosted = 4 * input / (1 + 3 * input)
        amplitude = CGFloat(pow(boosted, 0.65))
        if UIAccessibility.isReduceMotionEnabled {
            phase = 0
        } else if amplitude > 0 {
            phase = (phase + 0.28).truncatingRemainder(dividingBy: .pi * 20)
        }
        render(animated: !UIAccessibility.isReduceMotionEnabled && window != nil)
    }

    private func render(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = CGMutablePath()
        let inset = curve.lineWidth / 2
        let height = max(0, bounds.height / 2 - inset)
        for index in 0...120 {
            let position = CGFloat(index) / 120
            // Taper both ends. Two smooth harmonics add shape without random or autonomous motion.
            let envelope = pow(sin(.pi * position), 1.2)
            let wave = (sin(position * .pi * 6 + phase)
                        + 0.22 * sin(position * .pi * 10 - phase * 0.7)) / 1.22
            let point = CGPoint(x: inset + position * max(0, bounds.width - inset * 2),
                                y: bounds.midY + wave * envelope * amplitude * height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let previous = curve.presentation()?.path ?? curve.path
        curve.removeAnimation(forKey: "meter")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        curve.path = path
        CATransaction.commit()
        if animated, let previous {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = previous
            animation.toValue = path
            animation.duration = 0.1
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            curve.add(animation, forKey: "meter")
        }
    }
}

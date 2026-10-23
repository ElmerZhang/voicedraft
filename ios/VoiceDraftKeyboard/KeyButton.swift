import UIKit

/// Rounded editing keys, with system light/dark colors and a visible pressed state.
final class KeyButton: UIButton {
    enum Style { case secondary, accent, plain }
    private let style: Style
    private static let secondaryColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1) : UIColor.white.withAlphaComponent(0.65)
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        setTitleColor(style == .accent ? .systemBlue : .label, for: .normal)
        tintColor = style == .accent ? .systemBlue : .label
        setPreferredSymbolConfiguration(.init(pointSize: 22, weight: .regular), forImageIn: .normal)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = 12
    }

    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool { didSet { updateAppearance() } }

    private func updateAppearance() {
        alpha = isEnabled ? 1 : 0.3
        if isHighlighted || isSelected {
            backgroundColor = .tertiaryLabel
        } else {
            switch style {
            case .accent: backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            case .secondary: backgroundColor = Self.secondaryColor
            case .plain: backgroundColor = .clear
            }
        }
    }
}

/// Repeats an action while a key is held: once on touch down, then after 0.45 s every 0.08 s.
final class KeyRepeater {
    private var timer: Timer?

    func start(_ action: @escaping () -> Void) {
        action()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in action() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

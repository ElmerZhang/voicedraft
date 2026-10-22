import UIKit

/// The typing area: three letter rows or a digits and punctuation page, plus the bottom row.
final class KeyboardKeysView: UIView {
    private enum Page { case letters, symbols }

    private static let letterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private static let symbolRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'", "#", "%"],
    ]

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    let nextKeyboardButton = KeyButton(style: .special)
    var returnKeyTitle: String = L10n.returnDefault {
        didSet { returnButton.setTitle(returnKeyTitle, for: .normal) }
    }

    private let rowsStack = UIStackView()
    private let shiftButton = KeyButton(style: .special)
    private let deleteButton = KeyButton(style: .special)
    private let pageButton = KeyButton(style: .special)
    private let spaceButton = KeyButton(style: .character)
    private let returnButton = KeyButton(style: .special)
    private var characterButtons: [KeyButton] = []

    private var page: Page = .letters
    private var isShifted = false
    private var isCapsLocked = false
    private var lastShiftTap: Date?
    private var deleteRepeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        rowsStack.axis = .vertical
        rowsStack.spacing = 8
        rowsStack.distribution = .fillEqually
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        shiftButton.setImage(UIImage(systemName: "shift"), for: .normal)
        shiftButton.accessibilityLabel = L10n.shift
        shiftButton.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.accessibilityLabel = L10n.delete
        deleteButton.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        pageButton.addTarget(self, action: #selector(pageTapped), for: .touchUpInside)

        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.accessibilityLabel = L10n.nextKeyboard

        spaceButton.setTitle(L10n.space, for: .normal)
        spaceButton.titleLabel?.font = .systemFont(ofSize: 16)
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)

        returnButton.setTitle(returnKeyTitle, for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 16)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        rebuildRows()
    }

    // MARK: Layout

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        characterButtons.removeAll()

        let rows = page == .letters ? Self.letterRows : Self.symbolRows
        let referenceKey = makeCharacterKey(rows[0][0])
        rowsStack.addArrangedSubview(makeRow(rows[0].dropFirst().reduce(into: [referenceKey]) {
            $0.append(makeCharacterKey($1))
        }))

        // The second row is narrower on the letters page, centred like the system keyboard.
        let second = rows[1].map(makeCharacterKey)
        rowsStack.addArrangedSubview(makeRow(second, referenceWidth: referenceKey, centred: page == .letters))

        let third = rows[2].map(makeCharacterKey)
        let leading: UIView = page == .letters ? shiftButton : makeSpacer()
        let thirdRow = UIStackView(arrangedSubviews: [leading, makeRow(third, referenceWidth: referenceKey), deleteButton])
        thirdRow.axis = .horizontal
        thirdRow.spacing = 10
        // The side keys flex slightly so the row always fits the width set by the first row.
        for side in [leading, deleteButton] {
            let width = side.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: 1.4)
            width.priority = .defaultHigh
            width.isActive = true
        }
        leading.widthAnchor.constraint(equalTo: deleteButton.widthAnchor).isActive = true
        rowsStack.addArrangedSubview(thirdRow)

        pageButton.setTitle(page == .letters ? "123" : "ABC", for: .normal)
        let bottomRow = UIStackView(arrangedSubviews: [pageButton, nextKeyboardButton, spaceButton, returnButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 6
        pageButton.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: 1.4).isActive = true
        nextKeyboardButton.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: 1.4).isActive = true
        returnButton.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: 2.4).isActive = true
        rowsStack.addArrangedSubview(bottomRow)

        updateShiftAppearance()
    }

    private func makeRow(_ keys: [KeyButton], referenceWidth reference: KeyButton? = nil, centred: Bool = false) -> UIView {
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal
        row.spacing = 6
        if let reference {
            row.distribution = .fill
            for key in keys where key !== reference {
                key.widthAnchor.constraint(equalTo: reference.widthAnchor).isActive = true
            }
        } else {
            row.distribution = .fillEqually
        }
        guard centred else { return row }
        let container = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
        ])
        return container
    }

    private func makeSpacer() -> UIView {
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        return spacer
    }

    private func makeCharacterKey(_ character: String) -> KeyButton {
        let key = KeyButton(style: .character)
        key.character = character
        key.titleLabel?.font = .systemFont(ofSize: 22)
        key.addTarget(self, action: #selector(characterTapped(_:)), for: .touchUpInside)
        characterButtons.append(key)
        return key
    }

    // MARK: Shift

    private var isUppercase: Bool { page == .letters && (isShifted || isCapsLocked) }

    private func updateShiftAppearance() {
        let symbol = isCapsLocked ? "capslock.fill" : (isShifted ? "shift.fill" : "shift")
        shiftButton.setImage(UIImage(systemName: symbol), for: .normal)
        shiftButton.isSelected = isShifted || isCapsLocked
        for key in characterButtons {
            let character = key.character ?? ""
            key.setTitle(isUppercase ? character.uppercased() : character, for: .normal)
        }
    }

    @objc private func shiftTapped() {
        let now = Date()
        if let last = lastShiftTap, now.timeIntervalSince(last) < 0.3, !isCapsLocked {
            isCapsLocked = true
            isShifted = false
            lastShiftTap = nil
        } else if isCapsLocked {
            isCapsLocked = false
            isShifted = false
            lastShiftTap = nil
        } else {
            isShifted.toggle()
            lastShiftTap = now
        }
        updateShiftAppearance()
    }

    // MARK: Keys

    @objc private func characterTapped(_ sender: KeyButton) {
        guard let character = sender.character else { return }
        onInsert?(isUppercase ? character.uppercased() : character)
        if isShifted {
            isShifted = false
            updateShiftAppearance()
        }
    }

    @objc private func spaceTapped() {
        onInsert?(" ")
    }

    @objc private func returnTapped() {
        onReturn?()
    }

    @objc private func pageTapped() {
        page = page == .letters ? .symbols : .letters
        isShifted = false
        isCapsLocked = false
        rebuildRows()
    }

    @objc private func deleteDown() {
        onDelete?()
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.onDelete?()
            }
        }
    }

    @objc private func deleteUp() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }
}

/// A rounded key that follows the system light and dark appearance.
final class KeyButton: UIButton {
    enum Style { case character, special }

    var character: String?
    private let style: Style

    private static let characterColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    }
    private static let specialColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1)
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        setTitleColor(.label, for: .normal)
        tintColor = .label
        updateBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override var isSelected: Bool {
        didSet { updateBackground() }
    }

    private func updateBackground() {
        let pressed = isHighlighted || isSelected
        switch style {
        case .character:
            backgroundColor = pressed ? Self.specialColor : Self.characterColor
        case .special:
            backgroundColor = pressed ? Self.characterColor : Self.specialColor
        }
    }
}

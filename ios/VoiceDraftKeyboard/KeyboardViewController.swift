import UIKit

/// Minimal VoiceDraft keyboard: switch keyboards, a mic placeholder, and insert the last shared result.
final class KeyboardViewController: UIInputViewController {
    private let store = SharedResultStore()
    private let nextKeyboardButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()

        // Required by App Store guideline 4.4.1: always offer a way to switch keyboards.
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.accessibilityLabel = "Next keyboard"
        nextKeyboardButton.addTarget(self, action: #selector(advanceToNextInputMode), for: .touchUpInside)

        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.accessibilityLabel = "Record (not implemented)"
        micButton.isEnabled = false

        insertButton.setTitle("Insert last result", for: .normal)
        insertButton.addTarget(self, action: #selector(insertLastResult), for: .touchUpInside)

        // TODO: Add a compact QWERTY row once the voice flow works.
        let stack = UIStackView(arrangedSubviews: [nextKeyboardButton, micButton, insertButton])
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    override func viewWillLayoutSubviews() {
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    @objc private func insertLastResult() {
        guard let result = store.read(), !result.text.isEmpty else { return }
        textDocumentProxy.insertText(result.text)
    }
}

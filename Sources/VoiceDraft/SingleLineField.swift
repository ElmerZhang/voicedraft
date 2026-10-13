import AppKit
import SwiftUI

/// Uses AppKit's single-line field editor, which filters pasted line separators
/// before insertion and keeps selection, undo, and input-method handling native.
struct SingleLineField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    var secure = false
    var placeholder: String?

    init(_ title: String, text: Binding<String>, secure: Bool = false, placeholder: String? = nil) {
        self.title = title
        self._text = text
        self.secure = secure
        self.placeholder = placeholder
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = secure ? NSSecureTextField() : NSTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.cell?.allowsUndo = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder ?? title
        field.setAccessibilityLabel(title)
        // Reassigning an unchanged value would disrupt selection and IME input.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

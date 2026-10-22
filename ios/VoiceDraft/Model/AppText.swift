import Foundation
import VoiceDraftCore

/// App strings. Keys are the English text. Lookup order: this app's `Localizable.strings` for the
/// interface language chosen through `L10n`, then the shared `VoiceDraftCore` tables, then this app's
/// English table, then the key itself.
/// `{0}`-style placeholders match Core's `LocalizedMessage` convention.
enum AppText {
    private static let missing = "\u{1}missing\u{1}"

    static func t(_ key: String, _ arguments: String...) -> String {
        render(LocalizedMessage(key: key, arguments: arguments))
    }

    static func render(_ message: LocalizedMessage) -> String {
        guard !message.key.isEmpty else { return "" }
        let code = L10n.resolved(L10n.language)
        let template = appTemplate(message.key, language: code) ?? coreTemplate(message.key)
            ?? appTemplate(message.key, language: "en") ?? message.key
        var result = template
        for (index, argument) in message.arguments.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: argument)
        }
        return result
    }

    private static func appTemplate(_ key: String, language: String) -> String? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    private static func coreTemplate(_ key: String) -> String? {
        let value = L10n.text(key)
        return value == key ? nil : value
    }
}

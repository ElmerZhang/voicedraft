import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case japanese = "ja", korean = "ko", german = "de", french = "fr", spanish = "es"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return L("Follow system")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        }
    }
}

/// Keep interpolation separate from the translation key. Values are never translated or
/// interpreted as format strings (including user text containing braces or percent signs).
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Equatable, Sendable {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(key: String, arguments: [String] = []) { self.key = key; self.arguments = arguments }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public init(error: Error) {
        if let error = error as? VoiceDraftError, case .message(let message) = error { self = message }
        else { self.init(key: error.localizedDescription) }
    }
    public var isEmpty: Bool { key.isEmpty }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ value: String) { key += value }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    private static let preferenceKey = "interfaceLanguage"
    /// Preference store for the interface language. An iOS keyboard extension can point this
    /// at its app-group suite before first use; macOS keeps `.standard`.
    public static var defaults: UserDefaults = .standard
    static let resourceBundle: Bundle = {
        let name = "VoiceDraft_VoiceDraftCore.bundle"
        let packaged = ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension)
        if packaged {
            // Bundle.module's generated accessor traps when its bundle is missing, so packaged
            // apps and extensions search their own resources and never call it.
            let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0?.appendingPathComponent(name) }
            if let bundle = candidates.lazy.compactMap({ Bundle(url: $0) }).first { return bundle }
            NSLog("VoiceDraft: missing packaged localization resources %@; falling back to the main bundle", name)
            return Bundle.main
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()
    public static var language: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: preferenceKey)
            // Cocoa-owned UI (including permission dialogs) reads this app-only preference at launch.
            if newValue == .system { defaults.removeObject(forKey: "AppleLanguages") }
            else { defaults.set([newValue.rawValue, "en"], forKey: "AppleLanguages") }
        }
    }
    public static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
    }
    public static func resolved(_ language: AppLanguage, preferred: [String] = systemLanguages) -> String {
        guard language == .system else { return language.rawValue }
        // Unsupported languages fall back through the user's ordered language preferences.
        for code in preferred {
            let value = code.lowercased().replacingOccurrences(of: "_", with: "-")
            if value.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(value) { return "zh-Hant" }
            if value == "zh" || value.hasPrefix("zh-hans") || value == "zh-cn" || value == "zh-sg" { return "zh-Hans" }
            let base = value.split(separator: "-").first.map(String.init) ?? value
            if ["en", "ja", "ko", "de", "fr", "es"].contains(base) { return base }
        }
        return "en"
    }
    public static var locale: Locale { Locale(identifier: resolved(language)) }
    public static func text(_ key: String, table: String = "Localizable") -> String { render(.init(key: key), table: table) }
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    public static func render(_ message: LocalizedMessage, language: AppLanguage? = nil, table: String = "Localizable") -> String {
        let code = resolved(language ?? self.language)
        // SwiftPM lowercases lproj names (zh-hans); match the actual resource name rather
        // than allowing Foundation's preferred-language lookup to silently choose English.
        let directory = resourceBundle.localizations.first { $0.caseInsensitiveCompare(code) == .orderedSame } ?? "en"
        let bundle = Bundle(url: resourceBundle.bundleURL.appendingPathComponent(directory + ".lproj"))
        let template = bundle?.localizedString(forKey: message.key, value: message.key, table: table) ?? message.key
        let source = template as NSString
        var result = template
        for match in placeholderPattern.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let index = Int(source.substring(with: match.range(at: 1))), message.arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: message.arguments[index])
        }
        return result
    }
}

public func L(_ message: LocalizedMessage) -> String { L10n.render(message) }

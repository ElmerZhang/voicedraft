import XCTest
@testable import VoiceDraftCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageMatchingAndFallback() {
        for (preferred, expected) in [("zh-CN", "zh-Hans"), ("zh-Hant-HK", "zh-Hant"), ("zh-TW", "zh-Hant"),
                                      ("ja-JP", "ja"), ("ko-KR", "ko"), ("de-DE", "de"), ("fr-CA", "fr"), ("es-MX", "es"), ("en-GB", "en")] {
            XCTAssertEqual(L10n.resolved(.system, preferred: [preferred]), expected)
        }
        XCTAssertEqual(L10n.resolved(.system, preferred: ["ar", "ko-KR", "en"]), "ko")
        XCTAssertEqual(L10n.resolved(.system, preferred: ["ru"]), "en")
        XCTAssertEqual(L10n.resolved(.japanese, preferred: ["zh-CN"]), "ja")
    }

    func testAllEightCatalogsHaveMatchingKeysAndPlaceholders() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        func placeholders(_ value: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: #"\{\d+\}|%\d*d"#)
            return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        let english = try catalog("en")
        XCTAssertGreaterThan(english.count, 280)
        XCTAssertEqual(AppLanguage.allCases.filter { $0 != .system }.count, 8)
        for language in AppLanguage.allCases where language != .system {
            let values = try catalog(language.rawValue)
            XCTAssertEqual(Set(values.keys), Set(english.keys), language.rawValue)
            for (key, value) in values {
                XCTAssertFalse(value.isEmpty, "\(language.rawValue): \(key)")
                XCTAssertEqual(placeholders(key), placeholders(value), "\(language.rawValue): \(key)")
            }
        }
    }

    func testInterpolationDoesNotTranslateOrReinterpretUserContent() {
        let name = "私のモデル {1} 100% %@"
        let message: LocalizedMessage = "Add an API key for \(name) in Models."
        XCTAssertEqual(message.key, "Add an API key for {0} in Models.")
        for language in AppLanguage.allCases where language != .system {
            XCTAssertTrue(L10n.render(message, language: language).contains(name))
        }
        for (language, expected): (AppLanguage, String) in [(.english, "Save profile"), (.simplifiedChinese, "保存配置"),
            (.traditionalChinese, "保存配置"), (.japanese, "モデル設定を保存"), (.korean, "모델 설정 저장"),
            (.german, "Profil speichern"), (.french, "Enregistrer le profil"), (.spanish, "Guardar perfil")] {
            XCTAssertEqual(L10n.render("Save profile", language: language), expected)
        }
        XCTAssertEqual(L10n.render(.init(key: "Unknown future label"), language: .french), "Unknown future label")
    }
}

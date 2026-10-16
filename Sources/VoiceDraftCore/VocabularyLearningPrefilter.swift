import Foundation
import NaturalLanguage

/// Local, pure gate in front of the vocabulary-learning model call. Plain
/// dictations with nothing term-like skip the second writing-model request.
/// The gate is deliberately conservative on the skip side: a false positive
/// only costs one model call, while a false negative skips learning for that take.
///
/// A sample is classified when any of these hold:
/// 1. It is a correction (`.editedDictation` or a spoken correction marker).
///    Corrections are never prefiltered.
/// 2. `before` or `after` contains a signal:
///    a. `TermExtractor` screen-context candidates (quoted terms, proper names,
///       identifiers, acronyms, embedded Latin, Chinese name + title, …);
///    b. in Han-dominant text, any Latin token of two or more letters outside
///       `englishUIStoplist` and `acronymStoplist` (ASR often lowercases
///       product names);
///    c. a token mixing letters and digits (`qwen3`, `H100`, `3b`), except
///       ordinals and clock suffixes such as `2nd` or `3pm`;
///    d. `NLTagger` `.nameType` finds a personal, place or organization name.
///       This is best-effort: NaturalLanguage does not advertise the name-type
///       scheme for Chinese, yet tags Chinese names on macOS 26; results may
///       differ on older releases;
///    e. the text is dominated by letters that are neither Han nor Latin
///       (kana, hangul, Cyrillic, …), which the heuristics above do not cover.
public enum VocabularyLearningPrefilter {
    public static func shouldClassify(_ sample: VocabularyLearningSample) -> Bool {
        if sample.source == .editedDictation || sample.hasSpokenCorrection { return true }
        return hasSignal(sample.before) || (sample.after != sample.before && hasSignal(sample.after))
    }

    static func hasSignal(_ text: String) -> Bool {
        let letters = letterCounts(text)
        guard letters.total > 0 else { return false }
        // e. Scripts the heuristics do not cover (at least a third of the letters).
        if letters.other * 3 >= letters.total { return true }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // c. Letter + digit tokens.
        for match in mixedTokenPattern.matches(in: text, range: full) {
            let token = ns.substring(with: match.range)
            if ordinalOrClock.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) == nil {
                return true
            }
        }
        // b. Any non-stoplist Latin word in Han-dominant text.
        if letters.han * 2 > letters.total {
            for match in latinWordPattern.matches(in: text, range: full) {
                let token = ns.substring(with: match.range)
                if !TermExtractor.englishUIStoplist.contains(token.lowercased()),
                   !TermExtractor.acronymStoplist.contains(token.uppercased()) { return true }
            }
        }
        // a. Screen-context term extraction.
        if let candidates = try? TermExtractor.candidates(in: text, options: .screenContext), !candidates.isEmpty {
            return true
        }
        // d. Named entities (best-effort).
        return hasNamedEntity(text)
    }

    private static let mixedTokenPattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9])(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{2,}(?![A-Za-z0-9])"#)
    private static let ordinalOrClock = try! NSRegularExpression(pattern: #"^[0-9]+(?:st|nd|rd|th|s|am|pm)$"#, options: .caseInsensitive)
    private static let latinWordPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z])[A-Za-z]{2,}(?![A-Za-z])"#)
    private static let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

    private static func hasNamedEntity(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if let tag, nameTags.contains(tag) { found = true; return false }
            return true
        }
        return found
    }

    struct LetterCounts { var han = 0, latin = 0, other = 0; var total: Int { han + latin + other } }

    static func letterCounts(_ text: String) -> LetterCounts {
        var counts = LetterCounts()
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F, 0x3005, 0x3007: counts.han += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: counts.latin += 1
            default: counts.other += 1
            }
        }
        return counts
    }
}

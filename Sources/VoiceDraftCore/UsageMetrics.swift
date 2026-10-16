import Foundation

/// Local estimates from retained voice transcripts. Generated answers and typed tests are not speech.
public struct UsageMetrics {
    public static let typingWordsPerMinute: Double = 45
    public private(set) var words = 0
    public private(set) var personalizedWords = 0
    public private(set) var duration: TimeInterval = 0
    public var wordsPerMinute: Double? { duration > 0 ? Double(words) * 60 / duration : nil }
    public var personalization: Double? { words > 0 ? Double(personalizedWords) / Double(words) : nil }
    public var estimatedTimeSaved: TimeInterval {
        max(0, Double(words) * 60 / Self.typingWordsPerMinute - duration)
    }

    public init() {}

    public mutating func include(_ entry: HistoryEntry, matcher: UsageVocabularyMatcher = .init()) {
        guard entry.duration.isFinite, entry.duration > 0 else { return }
        let tokens = Self.tokens(entry.original)
        let count = tokens.filter(\.isWord).count
        guard count > 0 else { return }
        words += count
        personalizedWords += matcher.matchedCount(tokens)
        duration += entry.duration
    }

    public mutating func merge(_ other: UsageMetrics) {
        words += other.words
        personalizedWords += other.personalizedWords
        duration += other.duration
    }

    public static func wordCount(_ text: String) -> Int { tokens(text).filter(\.isWord).count }

    /// Han and Japanese kana count per character; other scripts count letter/number runs.
    /// Punctuation and emoji do not count; internal apostrophes stay within one word.
    fileprivate struct Token {
        let key: String
        let isWord: Bool
    }

    fileprivate static func tokens(_ text: String) -> [Token] {
        let text = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        var tokens: [Token] = []
        var word = ""
        func flush() {
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !token.isEmpty { tokens.append(Token(key: token, isWord: true)) }
            word = ""
        }
        for character in text {
            let scalar = character.unicodeScalars.first!.value
            let perCharacter = (0x3400...0x4DBF).contains(scalar) || (0x4E00...0x9FFF).contains(scalar)
                || (0xF900...0xFAFF).contains(scalar) || (0x20000...0x323AF).contains(scalar)
                || (0x3041...0x3096).contains(scalar) || (0x30A1...0x30FA).contains(scalar)
                || (0xFF66...0xFF9D).contains(scalar)
            if perCharacter {
                flush(); tokens.append(Token(key: String(character), isWord: true))
            } else if character.isLetter || character.isNumber {
                word.append(character)
            } else if (character == "'" || character == "’"), !word.isEmpty {
                word.append("'")
            } else {
                flush()
                // Preserve symbols for exact vocabulary matching (C++ must not match C).
                if !character.isWhitespace { tokens.append(Token(key: String(character), isWord: false)) }
            }
        }
        flush()
        return tokens
    }
}

/// Token trie built once per projection. Whole terms/aliases match; overlapping matches count once.
public struct UsageVocabularyMatcher {
    private struct Node {
        var children: [String: Int] = [:]
        var terminal = false
    }
    private var nodes = [Node()]

    public init(vocabulary: AppVocabulary = AppVocabulary()) {
        guard vocabulary.enabled else { return }
        for entry in vocabulary.entries where entry.enabled {
            for term in [entry.text, entry.displayAs] + entry.aliases {
                let tokens = UsageMetrics.tokens(term)
                guard tokens.contains(where: \.isWord) else { continue }
                var index = 0
                for item in tokens {
                    let token = item.key
                    if let next = nodes[index].children[token] { index = next }
                    else {
                        let next = nodes.count
                        nodes.append(Node())
                        nodes[index].children[token] = next
                        index = next
                    }
                }
                nodes[index].terminal = true
            }
        }
    }

    fileprivate func matchedCount(_ tokens: [UsageMetrics.Token]) -> Int {
        var covered = [Bool](repeating: false, count: tokens.count)
        for start in tokens.indices {
            var node = 0
            var longestEnd: Int?
            for end in start..<tokens.count {
                guard let next = nodes[node].children[tokens[end].key] else { break }
                node = next
                if nodes[node].terminal { longestEnd = end }
            }
            if let end = longestEnd {
                for index in start...end where tokens[index].isWord { covered[index] = true }
            }
        }
        return covered.filter { $0 }.count
    }
}

import Foundation

/// Deterministic local post-processing for Polish results, applied after the writing model returns.
public enum PolishOutput {
    /// Strips the terminal punctuation of a one-word dictation, then applies conservative typography.
    public static func finalize(_ output: String, transcript: String, protectedTerms: [String]) -> String {
        if SingleWordOutput.isSingleWord(transcript) {
            return PolishTypography.apply(SingleWordOutput.finalize(output, transcript: transcript), protectedTerms: protectedTerms)
        }
        return PolishTypography.apply(restoringTerminalMark(of: transcript, in: output), protectedTerms: protectedTerms)
    }

    /// Sentence-final marks the model sometimes drops from short sentences: 。！？ and their ASCII forms.
    static let sentenceTerminals: Set<Character> = ["。", "！", "？", ".", "!", "?"]

    /// A multi-word transcript that ends with a sentence-final mark keeps one: when the model's output ends
    /// on a CJK character, an ASCII letter or a digit instead, the transcript's own mark is appended.
    /// Output ending in any punctuation, bracket, quote or code fence is left alone.
    static func restoringTerminalMark(of transcript: String, in output: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = trimmedTranscript.last, sentenceTerminals.contains(mark) else { return output }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmedOutput.last, !trimmedOutput.isEmpty else { return output }
        let bare = PolishTypography.isCJK(last) || (last.isASCII && (last.isLetter || last.isNumber))
        return bare ? trimmedOutput + String(mark) : output
    }
}

extension AppVocabulary {
    /// Spellings the typography pass must copy through untouched: each enabled entry's text and its
    /// non-empty display form, trimmed and deduplicated. Empty when the vocabulary is turned off.
    public var protectedTypographyTerms: [String] {
        guard enabled else { return [] }
        var seen = Set<String>()
        return entries.filter(\.enabled).flatMap { [$0.text, $0.displayAs] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Conservative Pangu-style spacing between CJK and ASCII letters or digits, plus a small product-name
/// casing table. It only inserts single spaces and swaps the case of whole listed words, so already-correct
/// text is returned byte-identical and a second pass changes nothing.
///
/// Protected spans are copied through untouched: fenced and inline code, URLs, email addresses, file paths,
/// Markdown link destinations, quoted text and the caller's protected terms. A space may still be inserted
/// at the outer edge of a URL, email or protected term (访问https://a.com becomes 访问 https://a.com),
/// never inside one. Code, quotes and link destinations are delimited by punctuation, which never gets a space.
public enum PolishTypography {
    public static func apply(_ text: String, protectedTerms: [String]) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        let spans = protectedSpans(chars, protectedTerms: protectedTerms)
        applyCasing(&chars, spans: spans, protectedTerms: Set(protectedTerms))
        var output = String()
        output.reserveCapacity(text.utf8.count + 16)
        for index in chars.indices {
            output.append(chars[index])
            if index + 1 < chars.count, needsSpace(chars, index, spans) { output.append(" ") }
        }
        return output
    }

    // MARK: Spacing

    private static func needsSpace(_ chars: [Character], _ index: Int, _ spans: [Int]) -> Bool {
        if spans[index] != 0, spans[index] == spans[index + 1] { return false }
        let left = chars[index], right = chars[index + 1]
        if isCJK(left) { return isASCIIAlphanumeric(right) }
        guard isCJK(right) else { return false }
        if isASCIIAlphanumeric(left) { return true }
        // 15%, 3‰ and 30° are one number.
        return numberSuffixes.contains(left) && index > 0 && isASCIIDigit(chars[index - 1])
    }

    static let numberSuffixes: Set<Character> = ["%", "‰", "°"]

    /// Full-width and CJK punctuation; tokens end at these and no space is ever placed beside them.
    static let cjkPunctuation: Set<Character> = [
        "，", "。", "！", "？", "；", "：", "、", "（", "）", "《", "》", "〈", "〉", "「", "」", "『", "』",
        "【", "】", "〔", "〕", "…", "‥", "“", "”", "‘", "’", "—", "～", "·", "．", "・"
    ]

    private static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    private static func isASCIILetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    private static func isASCIIAlphanumeric(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// Han, Kana and Hangul, the same ranges `SingleWordOutput` treats as CJK.
    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF,
             0xD7B0...0xD7FF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    // MARK: Casing

    /// Accepted spellings for each canonical name. Only all-caps APP is rewritten, since "app" is English.
    static let casing: [String: String] = {
        var table = ["APP": "App"]
        for name in ["iPhone", "iPad", "iOS", "macOS", "GitHub", "GitLab", "YouTube", "WeChat", "ChatGPT", "LinkedIn"] {
            let lower = name.lowercased()
            for form in [lower.uppercased(), lower, lower.prefix(1).uppercased() + lower.dropFirst()] { table[form] = name }
        }
        return table
    }()

    /// Rewrites whole ASCII-letter words bounded by non-letters (CJK counts as a boundary). Every listed
    /// rewrite keeps the length, so span indices stay valid.
    private static func applyCasing(_ chars: inout [Character], spans: [Int], protectedTerms: Set<String>) {
        var index = 0
        while index < chars.count {
            guard isASCIILetter(chars[index]) else { index += 1; continue }
            var end = index
            while end < chars.count, isASCIILetter(chars[end]) { end += 1 }
            let bounded = (index == 0 || !isWordLetter(chars[index - 1])) && (end == chars.count || !isWordLetter(chars[end]))
            let word = String(chars[index..<end])
            if bounded, spans[index..<end].allSatisfy({ $0 == 0 }), !protectedTerms.contains(word),
               let replacement = casing[word], replacement != word {
                chars.replaceSubrange(index..<end, with: Array(replacement))
            }
            index = end
        }
    }

    private static func isWordLetter(_ c: Character) -> Bool { c.isLetter && !isCJK(c) }

    // MARK: Protected spans

    /// One span id per character; 0 means unprotected.
    private static func protectedSpans(_ chars: [Character], protectedTerms: [String]) -> [Int] {
        var spans = [Int](repeating: 0, count: chars.count)
        var nextID = 0
        func claim(_ range: Range<Int>) {
            nextID += 1
            for i in range where spans[i] == 0 { spans[i] = nextID }
        }
        func isFree(_ range: Range<Int>) -> Bool { spans[range].allSatisfy { $0 == 0 } }
        func matches(_ pattern: [Character], at i: Int) -> Bool {
            i >= 0 && i + pattern.count <= chars.count && Array(chars[i..<(i + pattern.count)]) == pattern
        }

        // Fenced code: ``` to the next ```, or to the end when unclosed.
        let fence: [Character] = ["`", "`", "`"]
        var i = 0
        while i < chars.count {
            guard matches(fence, at: i) else { i += 1; continue }
            var j = i + 3
            while j < chars.count, !matches(fence, at: j) { j += 1 }
            let end = min(chars.count, j + 3)
            claim(i..<end); i = end
        }

        // Inline code: a run of n backticks to the next run of exactly n on the same line.
        i = 0
        while i < chars.count {
            guard chars[i] == "`", spans[i] == 0 else { i += 1; continue }
            var openEnd = i
            while openEnd < chars.count, chars[openEnd] == "`" { openEnd += 1 }
            let n = openEnd - i
            var j = openEnd, close: Int?
            while j < chars.count, !chars[j].isNewline, spans[j] == 0 {
                if chars[j] == "`" {
                    var runEnd = j
                    while runEnd < chars.count, chars[runEnd] == "`" { runEnd += 1 }
                    if runEnd - j == n { close = runEnd; break }
                    j = runEnd
                } else { j += 1 }
            }
            if let close { claim(i..<close); i = close } else { i = openEnd }
        }

        // Markdown link destinations: the "(...)" after "](", with nested parentheses, on one line.
        i = 0
        while i + 1 < chars.count {
            guard chars[i] == "]", chars[i + 1] == "(", spans[i] == 0, spans[i + 1] == 0 else { i += 1; continue }
            var depth = 0, j = i + 1, close: Int?
            while j < chars.count, !chars[j].isNewline {
                if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1; if depth == 0 { close = j; break } }
                j += 1
            }
            if let close, isFree((i + 1)..<(close + 1)) { claim((i + 1)..<(close + 1)); i = close + 1 } else { i += 1 }
        }

        // Quotations, marks included, closed on the same line. The outermost pair wins.
        let quotePairs: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』", "\"": "\""]
        i = 0
        while i < chars.count {
            guard spans[i] == 0, let closer = quotePairs[chars[i]] else { i += 1; continue }
            var j = i + 1
            while j < chars.count, !chars[j].isNewline, chars[j] != closer { j += 1 }
            if j < chars.count, chars[j] == closer, isFree(i..<(j + 1)) { claim(i..<(j + 1)); i = j + 1 } else { i += 1 }
        }

        // URLs, email addresses and file paths. A token ends at whitespace, CJK punctuation or a CJK
        // character, so 访问https://a.com。 protects only the URL.
        i = 0
        while i < chars.count {
            guard isTokenCharacter(chars[i]) else { i += 1; continue }
            var end = i
            while end < chars.count, isTokenCharacter(chars[end]) { end += 1 }
            if isProtectedToken(String(chars[i..<end])) { claim(i..<end) }
            i = end
        }

        // Protected terms: every occurrence, longest first, case-sensitive, never overlapping another span.
        let unique: Set<String> = Set(protectedTerms.filter { !$0.isEmpty })
        let terms: [[Character]] = unique.map { (term: String) -> [Character] in Array(term) }
            .sorted { (a: [Character], b: [Character]) -> Bool in
                a.count != b.count ? a.count > b.count : String(a) < String(b)
            }
        for term in terms {
            var k = 0
            while k + term.count <= chars.count {
                if chars[k] == term[0], matches(term, at: k), isFree(k..<(k + term.count)) {
                    claim(k..<(k + term.count)); k += term.count
                } else { k += 1 }
            }
        }
        return spans
    }

    private static func isTokenCharacter(_ c: Character) -> Bool {
        !c.isWhitespace && !cjkPunctuation.contains(c) && !isCJK(c)
    }

    private static func isProtectedToken(_ token: String) -> Bool {
        if token.contains("://") { return true }
        if let at = token.firstIndex(of: "@"), token[token.index(after: at)...].contains(".") { return true }
        let core = token.drop(while: { "([{<\"'".contains($0) })
        if core.lowercased().hasPrefix("www.") { return true }
        return ["/", "~/", "./", "../"].contains(where: { core.hasPrefix($0) })
    }
}

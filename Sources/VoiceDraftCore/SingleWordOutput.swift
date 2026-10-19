import Foundation

/// Deterministic guard for Polish results of one-word dictations: a bare word such as 测试 must not
/// come back as 测试。. It only ever strips trailing terminal punctuation and never rewrites the word.
///
/// The ASCII `.` may appear inside a token (Node.js, example.com, .gitignore) but is still stripped
/// from the end. A token with any CJK character counts as a word only up to 4 characters, because
/// Chinese words are 1 to 4 characters; longer unpunctuated runs are phrases the model judges itself.
public enum SingleWordOutput {
    /// Terminal punctuation stripped from the end, half- and full-width.
    static let terminal: Set<Character> = ["。", "．", ".", "！", "!", "？", "?", "，", ",", "、", "；", ";", "：", ":", "…", "‥"]
    /// Terminal punctuation that never belongs inside a word; `.` is allowed internally.
    static let wordInternalForbidden: Set<Character> = terminal.subtracting(["."])

    public static func isSingleWord(_ transcript: String) -> Bool {
        let core = stripTerminal(transcript)
        guard isToken(core) else { return false }
        return core.count <= (core.unicodeScalars.contains(where: isCJK) ? 4 : 40)
    }

    /// Polish result for a single-word transcript: the output with trailing terminal punctuation removed.
    /// Any other input, or an output that is no longer a single token, returns `output` unchanged.
    public static func finalize(_ output: String, transcript: String) -> String {
        guard isSingleWord(transcript) else { return output }
        let stripped = stripTerminal(output)
        return isToken(stripped) ? stripped : output
    }

    private static func stripTerminal(_ text: String) -> String {
        var value = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = value.last, terminal.contains(last) || last.isWhitespace {
            value = value.dropLast()
        }
        return String(value)
    }

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: { $0.isWhitespace || $0.isNewline || wordInternalForbidden.contains($0) })
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF,
             0xD7B0...0xD7FF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3134F:
            return true
        default:
            return false
        }
    }
}

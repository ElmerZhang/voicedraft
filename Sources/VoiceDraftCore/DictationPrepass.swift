import Foundation

/// Deterministic transcript rewrites applied before the writing model sees a dictation-cleanup request.
public enum DictationPrepass {
    /// Longest first so `应该说是` wins over `应该说`.
    static let restatementMarkers = ["应该说是", "应该说", "或者说是", "或者说", "就是说", "我是说"]
    private static let hesitations: Set<Character> = ["啊", "嗯", "呃", "额", "哦"]
    private static let commas: Set<Character> = ["，", ","]
    private static let trailingPunctuation: Set<Character> = ["。", "！", "？", "，", "、", "；", ",", ".", "!", "?", ";"]
    /// Where an abandoned attempt can start: a sentence end, a clause comma or a line break.
    private static let clauseBoundaries: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "，", "、", ","]
    private static let maxPasses = 20

    /// Collapses an abandoned attempt that the speaker restarts with the same words after a Chinese restatement
    /// marker, e.g. `我们明天会把那盆花。\n啊，应该说是我明天会把那盆花搬到…` → `我明天会把那盆花搬到…`.
    /// Fires only when the attempt and the restart share at least four Han characters, aligned within two
    /// characters on each side. Unchanged input is returned as is; the function is idempotent.
    public static func collapseRestatements(_ transcript: String) -> String {
        var text = transcript
        for _ in 0..<maxPasses {
            guard let collapsed = collapseFirst(in: text) else { break }
            text = collapsed
        }
        return text
    }

    private static func collapseFirst(in text: String) -> String? {
        var searchStart = text.startIndex
        while let match = nextMarker(in: text, from: searchStart) {
            if let attemptStart = qualifyingAttemptStart(in: text, before: match.lowerBound, restart: restart(after: match.upperBound, in: text)) {
                return String(text[..<attemptStart]) + restart(after: match.upperBound, in: text)
            }
            searchStart = match.upperBound
        }
        return nil
    }

    /// The earliest marker occurrence at or after `start`; at one position the longest marker wins.
    private static func nextMarker(in text: String, from start: String.Index) -> Range<String.Index>? {
        var index = start
        while index < text.endIndex {
            for marker in restatementMarkers where text[index...].hasPrefix(marker) {
                return index..<text.index(index, offsetBy: marker.count)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func restart(after markerEnd: String.Index, in text: String) -> Substring {
        var rest = text[markerEnd...].drop(while: { $0 == " " })
        if let first = rest.first, commas.contains(first) { rest = rest.dropFirst() }
        return rest
    }

    /// Returns where the abandoned attempt starts when the text before the marker is restarted by `restart`.
    private static func qualifyingAttemptStart(in text: String, before markerStart: String.Index, restart: Substring) -> String.Index? {
        var pre = text[..<markerStart]
        pre = dropTrailingWhitespace(pre)
        pre = dropTrailingHesitation(pre)
        pre = dropTrailingWhitespace(pre)
        if let last = pre.last, trailingPunctuation.contains(last) { pre = pre.dropLast() }
        pre = dropTrailingWhitespace(pre)

        var attemptStart = pre.startIndex
        if let boundary = pre.lastIndex(where: { clauseBoundaries.contains($0) || $0.isNewline }) {
            attemptStart = pre.index(after: boundary)
        }
        let rawAttempt = pre[attemptStart...]
        let leading = rawAttempt.prefix(while: { $0.isWhitespace })
        attemptStart = leading.endIndex
        let attempt = pre[attemptStart...]
        guard !attempt.isEmpty, sharesRestart(Array(attempt), Array(restart)) else { return nil }
        return attemptStart
    }

    private static func sharesRestart(_ attempt: [Character], _ restart: [Character]) -> Bool {
        for a in 0...2 where a < attempt.count {
            for b in 0...2 where b < restart.count {
                var length = 0
                while length < 4, a + length < attempt.count, b + length < restart.count,
                      attempt[a + length] == restart[b + length], PolishTypography.isCJK(attempt[a + length]) {
                    length += 1
                }
                if length == 4 { return true }
            }
        }
        return false
    }

    private static func dropTrailingWhitespace(_ text: Substring) -> Substring {
        var text = text
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return text
    }

    /// Drops one trailing hesitation group (`啊，`, `嗯 `, `呃呃`); a lone comma without a hesitation sound stays.
    private static func dropTrailingHesitation(_ text: Substring) -> Substring {
        var candidate = text
        while let last = candidate.last, last == " " { candidate = candidate.dropLast() }
        if let last = candidate.last, commas.contains(last) { candidate = candidate.dropLast() }
        guard let last = candidate.last, hesitations.contains(last) else { return text }
        while let last = candidate.last, hesitations.contains(last) { candidate = candidate.dropLast() }
        return candidate
    }
}

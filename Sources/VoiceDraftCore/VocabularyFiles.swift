import Foundation

public enum VocabularyFile {
    private struct Archive: Codable { let version: Int; let entries: [VocabularyEntry] }
    public static func export(_ vocabulary: AppVocabulary) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archive(version: 1, entries: vocabulary.entries))
    }
    public static func entries(_ data: Data) throws -> [VocabularyEntry] {
        guard data.count <= 20_000_000 else { throw FeatureError("Dictionary files must be smaller than 20 MB.") }
        let trimmed = String(decoding: data.prefix(100), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.entries.count <= 200_000, Set(archive.entries.map(\.id)).count == archive.entries.count else { throw FeatureError("Unsupported dictionary format.") }
            for entry in archive.entries { try entry.validate() }
            return archive.entries
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FeatureError("Use a UTF-8 text or VoiceDraft JSON dictionary.") }
        var vocabulary = AppVocabulary(); vocabulary.appendLines(text); try vocabulary.validate(); return vocabulary.entries
    }
    public static func merge(_ entries: [VocabularyEntry], into vocabulary: inout AppVocabulary) throws {
        var updated = vocabulary
        var known = Set(updated.entries.map { AppVocabulary.automaticTermKey($0.text) })
        for var entry in entries where known.insert(AppVocabulary.automaticTermKey(entry.text)).inserted {
            entry.id = UUID(); updated.entries.append(entry.normalized)
        }
        try updated.validate(); vocabulary = updated
    }
}

extension AppVocabulary {
    /// Count a term at most once per completed take, with word boundaries for Latin terms.
    @discardableResult public mutating func recordUsage(in text: String) -> Bool {
        guard enabled else { return false }
        var changed = false
        for index in entries.indices where entries[index].enabled {
            let terms = [entries[index].text, entries[index].displayAs] + entries[index].aliases
            let present = terms.filter { !$0.isEmpty && $0.count <= 200 }.contains { term in
                let latin = term.unicodeScalars.allSatisfy { $0.isASCII }
                let pattern = (latin ? "(?<![A-Za-z0-9_])" : "") + NSRegularExpression.escapedPattern(for: term) + (latin ? "(?![A-Za-z0-9_])" : "")
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if present { entries[index].useCount = min(1_000_000_000, entries[index].useCount + 1); changed = true }
        }
        return changed
    }
}

/// Offline, explicit file import. JSONL imports only user-authored text, not tool output or assistant replies.
public enum ContextVocabulary {
    public static func candidates(data: Data, filename: String) throws -> [String] {
        guard data.count <= 5_000_000, let source = String(data: data, encoding: .utf8) else { throw FeatureError("Choose a UTF-8 context file smaller than 5 MB.") }
        var text = source
        if filename.lowercased().hasSuffix(".jsonl") {
            text = source.split(separator: "\n").compactMap { line -> String? in
                guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
                let payload = root["payload"] as? [String: Any] ?? root["message"] as? [String: Any] ?? root
                guard payload["role"] as? String == "user" || (root["type"] as? String == "event_msg" && payload["type"] as? String == "user_message") else { return nil }
                if let content = payload["content"] as? String { return content }
                if let message = payload["message"] as? String { return message }
                return (payload["content"] as? [[String: Any]] ?? []).filter { ["text", "input_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }.joined(separator: "\n")
        }
        // Avoid lines containing credentials/URLs and cap the proposed list. The user reviews every import.
        text = text.components(separatedBy: .newlines).filter { line in
            !["api_key", "api-key", "secret", "password", "bearer ", "private key", "token=", "https://", "http://"].contains { line.lowercased().contains($0) }
        }.joined(separator: "\n")
        let pattern = #"(?<![A-Za-z0-9_-])(?:[A-Z][a-z]+(?:[A-Z][A-Za-z0-9]*)+|[A-Z]{2,12}|[A-Za-z]{2,20}_[A-Za-z_]{2,30})(?![A-Za-z0-9_-])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var counts: [String: Int] = [:]
        for match in regex.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            let term = String(text[range])
            if (2...64).contains(term.count) { counts[term, default: 0] += 1 }
        }
        // Quoted local terminology also covers Chinese product/project names.
        let quoted = try NSRegularExpression(pattern: #"[`「『]([\p{Han}A-Za-z0-9_]{2,24})[`」』]"#)
        for match in quoted.matches(in: text, range: range) {
            guard let termRange = Range(match.range(at: 1), in: text) else { continue }
            counts[String(text[termRange]), default: 0] += 1
        }
        return Array(counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0]! > counts[$1]! }.prefix(200))
    }
}

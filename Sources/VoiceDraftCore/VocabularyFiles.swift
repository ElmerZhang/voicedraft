import Foundation

public enum VocabularyFile {
    private struct Archive: Codable { let version: Int; let entries: [VocabularyEntry] }
    public static func export(_ vocabulary: AppVocabulary) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archive(version: 1, entries: vocabulary.entries))
    }
    public static func entries(_ data: Data) throws -> [VocabularyEntry] {
        guard data.count <= 20_000_000 else { throw FeatureError("Vocabulary files must be smaller than 20 MB.") }
        let trimmed = String(decoding: data.prefix(100), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.entries.count <= 200_000, Set(archive.entries.map(\.id)).count == archive.entries.count else { throw FeatureError("Unsupported vocabulary format.") }
            for entry in archive.entries { try entry.validate() }
            return archive.entries
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FeatureError("Use a UTF-8 text or VoiceDraft JSON vocabulary.") }
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

/// Local extraction shared by automatic discovery and explicit context-file callers.
public enum ContextVocabulary {
    struct Document { let text: String; let projects: [String] }

    public static func candidates(data: Data, filename: String) throws -> [String] {
        try terms(in: document(data: data, filename: filename).text)
    }

    static func document(data: Data, filename: String) throws -> Document {
        guard data.count <= 5_000_000, let source = String(data: data, encoding: .utf8) else { throw FeatureError("Use a UTF-8 context file smaller than 5 MB.") }
        guard filename.lowercased().hasSuffix(".jsonl") else { return Document(text: source, projects: []) }
        var messages: [String] = []
        var seen = Set<String>()
        var projects: [String] = []
        for line in source.split(separator: "\n") {
            try Task.checkCancellation()
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if root["isSidechain"] as? Bool == true || root["isMeta"] as? Bool == true { continue }
            let payload = root["payload"] as? [String: Any] ?? root["message"] as? [String: Any] ?? root
            if root["type"] as? String == "session_meta" {
                if (payload["source"] as? [String: Any])?["subagent"] != nil || payload["source"] as? String == "subagent" {
                    return Document(text: "", projects: [])
                }
                if let cwd = payload["cwd"] as? String { projects.append(cwd) }
                continue
            }
            var text: String?
            if filename.lowercased() == "history.jsonl" {
                if root["session_id"] is String, root["ts"] != nil { text = root["text"] as? String }
                if root["timestamp"] != nil, let display = root["display"] as? String {
                    text = display
                    if let project = root["project"] as? String { projects.append(project) }
                }
            }
            if payload["role"] as? String == "user" || (root["type"] as? String == "event_msg" && payload["type"] as? String == "user_message") {
                if let content = payload["content"] as? String { text = content }
                else if let message = payload["message"] as? String { text = message }
                else {
                    let blocks = payload["content"] as? [[String: Any]] ?? []
                    // Claude wraps tool responses as user messages; none of that wrapper is user prose.
                    guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                    text = blocks.filter { ["text", "input_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                if let cwd = root["cwd"] as? String { projects.append(cwd) }
            }
            guard let text, !text.isEmpty else { continue }
            let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !["# agents.md instructions", "<environment_context>", "<instructions>", "<system-reminder>", "<local-command-", "<command-name>", "<turn_aborted>"].contains(where: start.hasPrefix) else { continue }
            if seen.insert(text).inserted { messages.append(text) }
        }
        // Most recent project references win the scanner's bounded project budget.
        return Document(text: messages.joined(separator: "\n"), projects: projects.reversed())
    }

    static func terms(in source: String) throws -> [String] {
        try TermExtractor.candidates(in: source, options: .agentContext).map(\.text)
    }
}

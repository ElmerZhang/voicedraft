import Foundation
import CryptoKit

public enum VocabularyOrigin: String, Codable { case manual, automatic }

/// Provider-independent source of truth. Adapters only derive request data from this value.
public struct VocabularyEntry: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var text: String
    public var enabled = true
    public var boost: Int = 50
    public var priority = false
    public var language = ""
    public var displayAs = ""
    public var aliases: [String] = []
    public var pronunciation = "" // IPA; retained for adapters that support pronunciation lexicons.
    public var origin: VocabularyOrigin = .manual
    public var useCount = 0
    public init(text: String = "", boost: Int = 50, priority: Bool = false) {
        self.text = text; self.boost = boost; self.priority = priority
    }
    private enum CodingKeys: String, CodingKey {
        case id, text, enabled, boost, priority, language, displayAs, aliases, pronunciation, origin, useCount
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        boost = try c.decode(Int.self, forKey: .boost)
        priority = try c.decode(Bool.self, forKey: .priority)
        language = try c.decode(String.self, forKey: .language)
        displayAs = try c.decode(String.self, forKey: .displayAs)
        aliases = try c.decode([String].self, forKey: .aliases)
        pronunciation = try c.decode(String.self, forKey: .pronunciation)
        useCount = max(0, min(1_000_000_000, try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0))
        origin = try c.decodeIfPresent(VocabularyOrigin.self, forKey: .origin) ?? .manual
    }
    public var normalized: Self {
        var value = self
        value.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        value.displayAs = displayAs.trimmingCharacters(in: .whitespacesAndNewlines)
        value.pronunciation = pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        value.aliases = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return value
    }
    public func validate() throws {
        let fields = [text, language, displayAs, pronunciation] + aliases
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...100).contains(boost), aliases.count <= 50,
              fields.allSatisfy({ $0.count <= 30_000 && !$0.contains(where: { $0.isNewline || $0 == "\t" }) }),
              language.isEmpty || language.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != nil else {
            throw VoiceDraftError.message("Use a nonempty single-line term, strength 0–100, and an optional language code such as zh-CN or en-US. Each field can contain up to 30,000 characters and each term up to 50 aliases.")
        }
    }
}

public struct LegacyVocabularyReference: Codable, Equatable {
    public var model: String
    public var endpoint: String
    public var resourceID: String
}

public struct AppVocabulary: Codable, Equatable {
    public var enabled = true
    public var entries: [VocabularyEntry] = []
    public var learnFromCorrections = true
    public var discoverFromDictation = true
    // Hashes suppress relearning deleted terms without retaining deleted spelling.
    public var excludedAutomaticTerms: Set<String> = []
    // Remote lists cannot be reconstructed without fetching them. Preserve references for
    // manual recovery, but never combine an unknown remote list with the app-owned projection.
    public var legacyReferences: [LegacyVocabularyReference] = []
    public init() {}
    public init(words: String) { appendLines(words) }
    private enum CodingKeys: String, CodingKey {
        case enabled, entries, legacyReferences, learnFromCorrections, discoverFromDictation, excludedAutomaticTerms
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        entries = try c.decode([VocabularyEntry].self, forKey: .entries)
        legacyReferences = try c.decode([LegacyVocabularyReference].self, forKey: .legacyReferences)
        learnFromCorrections = try c.decodeIfPresent(Bool.self, forKey: .learnFromCorrections) ?? true
        discoverFromDictation = try c.decodeIfPresent(Bool.self, forKey: .discoverFromDictation) ?? true
        excludedAutomaticTerms = try c.decodeIfPresent(Set<String>.self, forKey: .excludedAutomaticTerms) ?? []
    }
    public mutating func removeEntry(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        for term in [entry.text, entry.displayAs] + entry.aliases where !term.isEmpty {
            excludedAutomaticTerms.insert(Self.automaticTermKey(term))
        }
        entries.removeAll { $0.id == id }
    }
    public static func automaticTermKey(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult
    public mutating func learn(_ terms: [String], fromDiscovery: Bool = false) -> [String] {
        guard enabled, fromDiscovery ? discoverFromDictation : learnFromCorrections else { return [] }
        var known = Set(entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.map(Self.automaticTermKey))
        var added: [String] = []
        for term in terms.prefix(5) {
            let key = Self.automaticTermKey(term)
            guard VocabularyLearning.isTerm(term), !excludedAutomaticTerms.contains(key),
                  entries.count < 200_000, known.insert(key).inserted else { continue }
            var entry = VocabularyEntry(text: term); entry.origin = .automatic
            entries.append(entry); added.append(term)
        }
        return added
    }
    public mutating func appendLines(_ words: String) {
        var seen = Set(entries.map(\.text))
        for line in words.split(whereSeparator: \.isNewline) {
            let text = line.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, seen.insert(text).inserted { entries.append(.init(text: text)) }
        }
    }
    public func validate() throws {
        guard entries.count <= 200_000, Set(entries.map(\.id)).count == entries.count,
              excludedAutomaticTerms.count <= 200_000,
              excludedAutomaticTerms.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw VoiceDraftError.message("The app vocabulary contains too many entries or duplicate entry IDs.")
        }
        for entry in entries { try entry.validate() }
    }
    /// Manual spellings and aliases take precedence over an old automatically
    /// discovered duplicate. This is a request projection, never a storage edit.
    var inferenceEntries: [VocabularyEntry] {
        guard enabled else { return [] }
        let manualKeys = Set(entries.filter { $0.origin == .manual && $0.enabled }
            .flatMap { [$0.text, $0.displayAs] + $0.aliases }.filter { !$0.isEmpty }.map(Self.automaticTermKey))
        return entries.enumerated().filter {
            $0.element.enabled && ($0.element.origin == .manual || !manualKeys.contains(Self.automaticTermKey($0.element.text)))
        }.sorted {
            if $0.element.origin != $1.element.origin { return $0.element.origin == .manual }
            if $0.element.priority != $1.element.priority { return $0.element.priority }
            if $0.element.boost != $1.element.boost { return $0.element.boost > $1.element.boost }
            if $0.element.useCount != $1.element.useCount { return $0.element.useCount > $1.element.useCount }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    public var writingContext: String {
        guard enabled else { return "" }
        // These are structured spelling hints, not executable instructions or automatic replacements.
        let values = inferenceEntries.prefix(300).map { entry in
            ["term": entry.text, "display_as": entry.displayAs, "aliases": entry.aliases.joined(separator: ", "), "source": entry.origin.rawValue]
        }
        return (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func migrate(words: String, profiles: inout [ModelProfile], activeID: UUID) -> AppVocabulary {
        var result = AppVocabulary()
        let active = profiles.first { $0.id == activeID }?.legacySpeechOptions ?? LegacySpeechOptions()
        result.enabled = active.useVocabulary
        result.appendLines(words)
        for i in result.entries.indices { result.entries[i].boost = (active.defaultWeight - 1) * 25 }
        // Inactive profiles first, active profile last. The active model's old override wins
        // a conflict; all other terms survive. Stable ordering and IDs make sync equality repeatable.
        var indices = Dictionary(uniqueKeysWithValues: result.entries.enumerated().map { ($0.element.text, $0.offset) })
        let ordered = profiles.filter { $0.role == .speech && $0.id != activeID } + profiles.filter { $0.id == activeID }
        for profile in ordered {
            for old in profile.legacySpeechOptions?.hotwords ?? [] {
                let text = old.text.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var value = VocabularyEntry(text: text, boost: old.weight == 50 ? 100 : (old.weight - 1) * 25, priority: old.weight == 50)
                value.enabled = profile.id == activeID || (profile.legacySpeechOptions?.useVocabulary ?? true)
                if let index = indices[text] { result.entries[index] = value }
                else { indices[text] = result.entries.count; result.entries.append(value) }
            }
        }
        for i in result.entries.indices {
            let hash = Array(SHA256.hash(data: Data(("VoiceDraft.vocabulary.v3:" + result.entries[i].text).utf8)))
            result.entries[i].id = UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
        }
        for i in profiles.indices {
            profiles[i].legacySpeechOptions = nil
            guard profiles[i].role == .speech,
                  var parameters = try? QwenRequests.extras(profiles[i].extraJSON),
                  let reference = parameters.removeValue(forKey: "vocabulary_id") as? String else { continue }
            result.legacyReferences.append(.init(model: profiles[i].model, endpoint: profiles[i].endpoint, resourceID: reference))
            if let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]) {
                profiles[i].extraJSON = String(decoding: data, as: UTF8.self)
            }
        }
        return result
    }
}

public struct VocabularyProjection: Equatable {
    public var weighted: [String: Int] = [:]
    public var terms: [String] = []
    public var omitted = 0
    public var shadowedAutomatic = 0
    public var downgradedPriority = 0
    public var hasUnsupportedMetadata = false
    /// Temporary on-screen terms actually included, after all vocabulary.
    public var screenTerms: [String] = []
    /// On-screen terms that did not fit the leftover budget or capability.
    public var screenOmitted = 0
    public var context: String { terms.joined(separator: ", ") }

    /// Vocabulary first, unchanged. `screenTerms` only use the leftover budget,
    /// at weight 1 for weighted capabilities, and never affect `omitted`,
    /// `shadowedAutomatic` or `downgradedPriority`.
    public static func make(_ source: AppVocabulary, for capability: VocabularyCapability, screenTerms: [String] = []) -> Self {
        guard source.enabled else { return Self() }
        var result = Self()
        let sorted = source.inferenceEntries
        result.shadowedAutomatic = source.entries.filter(\.enabled).count - sorted.count
        var seen = Set<String>(), priorityCount = 0, contextSize = 0
        for entry in sorted {
            if !entry.language.isEmpty || !entry.displayAs.isEmpty || !entry.pronunciation.isEmpty || !entry.aliases.isEmpty {
                result.hasUnsupportedMetadata = true
            }
            // Current Qwen APIs have no alias/output-form mapping; projecting aliases as
            // separate words would incorrectly imply that the mapping was honored.
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(text).inserted else { continue }
            switch capability {
            case .none: result.omitted += 1
            case .context:
                // Client context budget; never truncate a term into a different term.
                guard result.terms.count < 300, contextSize + text.utf8.count + 2 <= 6000 else { result.omitted += 1; continue }
                result.terms.append(text); contextSize += text.utf8.count + 2
            case .weighted:
                let ascii = text.unicodeScalars.allSatisfy(\.isASCII)
                let validLength = ascii ? text.split(whereSeparator: \.isWhitespace).count <= 7 : text.unicodeScalars.count <= 15
                guard !text.isEmpty, validLength, result.weighted.count < 2000 else { result.omitted += 1; continue }
                var weight = 1 + Int((Double(entry.boost) / 25).rounded())
                if entry.origin == .automatic {
                    // Repeated recognition is weak evidence. A user edit confirms
                    // the spelling as manual and restores the full strength range.
                    weight = min(weight, 2)
                } else if entry.priority {
                    if priorityCount < 50 { weight = 50; priorityCount += 1 }
                    else { weight = 5; result.downgradedPriority += 1 }
                }
                result.weighted[text] = weight; result.terms.append(text)
            }
        }
        var folded = Set(seen.map { $0.lowercased() })
        for raw in screenTerms {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains(where: \.isNewline), folded.insert(text.lowercased()).inserted else { continue }
            switch capability {
            case .none: result.screenOmitted += 1
            case .context:
                guard result.terms.count < 300, contextSize + text.utf8.count + 2 <= 6000 else { result.screenOmitted += 1; continue }
                result.terms.append(text); result.screenTerms.append(text); contextSize += text.utf8.count + 2
            case .weighted:
                let ascii = text.unicodeScalars.allSatisfy(\.isASCII)
                let validLength = ascii ? text.split(whereSeparator: \.isWhitespace).count <= 7 : text.unicodeScalars.count <= 15
                guard validLength, result.weighted.count < 2000 else { result.screenOmitted += 1; continue }
                result.weighted[text] = 1; result.terms.append(text); result.screenTerms.append(text)
            }
        }
        return result
    }
}

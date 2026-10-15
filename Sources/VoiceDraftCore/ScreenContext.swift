import Foundation

// On-screen context: pure, device-local building blocks. Nothing here is
// Codable, persisted or synced; the app target supplies AX/OCR input and
// passes results to requests as explicit parameters.

public enum ScreenContextSource: String, Sendable, Equatable { case accessibility, ocr }

public struct ScreenTerm: Equatable, Sendable {
    public enum Kind: String, Sendable { case quoted, identifier, camelCase, acronym, properName, embeddedLatin, cjkRun }
    public let text: String
    public let kind: Kind
    /// `cjkRun` is the only low-confidence kind.
    public let highConfidence: Bool
    public let count: Int
    public let score: Double
    public init(text: String, kind: Kind, count: Int = 1, score: Double = 0) {
        self.text = text; self.kind = kind; self.highConfidence = kind != .cjkRun; self.count = count; self.score = score
    }
}

public struct ScreenContextLimits: Equatable, Sendable {
    public var axNodes = 2_000
    public var axDepth = 12
    public var axSeconds: TimeInterval = 0.15
    /// Per AX message, fresh objects only.
    public var axMessageTimeout: Float = 0.05
    public var characterPerNode = 2_000
    public var charactersCollected = 20_000
    public var asrGateSeconds: TimeInterval = 0.25
    public var ocrSeconds: TimeInterval = 2
    public var ocrMaxPixelsLongEdge = 2_560
    public var ocrCharacters = 8_000
    public var cacheSeconds: TimeInterval = 60
    public var cacheEntries = 4
    public var asrTerms = 300
    /// UTF-8 bytes, including ", " separators.
    public var asrBytes = 6_000
    public var excerptCharacters = 1_500
    public var writingTerms = 40
    /// Non-whitespace content characters below which OCR may run.
    public var ocrThresholdCharacters = 120
    public init() {}
    public static let standard = Self()
}

// MARK: - Collected text

public struct ScreenTextAttributes: Equatable, Sendable {
    public var role: String
    public var subrole: String
    /// Only when the AX value is a string.
    public var value: String?
    public var title: String?
    public var description: String?
    /// AXVisibleCharacterRange + AXStringForRange, when available.
    public var visibleText: String?
    public var hidden: Bool
    public init(role: String, subrole: String = "", value: String? = nil, title: String? = nil,
                description: String? = nil, visibleText: String? = nil, hidden: Bool = false) {
        self.role = role; self.subrole = subrole; self.value = value; self.title = title
        self.description = description; self.visibleText = visibleText; self.hidden = hidden
    }
    public var isSecure: Bool { subrole == "AXSecureTextField" }
}

public struct ScreenTextSegment: Equatable, Sendable {
    public enum Kind: Int, Sendable { case focused, windowTitle, heading, neighbour, body, control, ocrLine }
    public var kind: Kind
    public var text: String
    /// Discovery order (reading-order proxy).
    public var order: Int
    /// UTF-16 offset in `text`; focused segments only.
    public var caretOffset: Int?
    public init(kind: Kind, text: String, order: Int, caretOffset: Int? = nil) {
        self.kind = kind; self.text = text; self.order = order; self.caretOffset = caretOffset
    }
}

public struct ScreenTextCollection: Equatable, Sendable {
    public var segments: [ScreenTextSegment] = []
    public var nodesVisited = 0
    public var charactersCollected = 0
    public var truncated = false
    public var skippedSecure = 0
    public init(segments: [ScreenTextSegment] = [], nodesVisited: Int = 0, charactersCollected: Int = 0,
                truncated: Bool = false, skippedSecure: Int = 0) {
        self.segments = segments; self.nodesVisited = nodesVisited; self.charactersCollected = charactersCollected
        self.truncated = truncated; self.skippedSecure = skippedSecure
    }
    /// Non-whitespace characters from heading/neighbour/body segments (not the
    /// window title, controls or the focused field).
    public var contentCharacters: Int {
        segments.filter { [.heading, .neighbour, .body].contains($0.kind) }
            .reduce(0) { $0 + $1.text.unicodeScalars.filter { !$0.properties.isWhitespace }.count }
    }
}

// MARK: - AX walker

/// Bounded, focus-first traversal of a window's accessibility tree. Generic so
/// it can be tested with fake trees; the app target supplies AX closures.
public enum ScreenTextWalker {
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private static let controlRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXCheckBox"]
    private static let menuRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem"]
    private static let visibleChildRoles: Set<String> = ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea"]

    public static func collect<Node: Hashable>(
        window: Node, windowTitle: String?,
        focused: Node?, focusedValue: String?, focusedRange: NSRange?,
        attributes: (Node) -> ScreenTextAttributes,
        children: (Node, _ visibleOnly: Bool) -> [Node],
        parent: (Node) -> Node?,
        limits: ScreenContextLimits = .standard,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> ScreenTextCollection {
        var result = ScreenTextCollection()
        let deadline = now() + limits.axSeconds
        var visited = Set<Node>(), seenText = Set<String>(), order = 0, stopped = false

        func emit(_ kind: ScreenTextSegment.Kind, _ raw: String?, caret: Int? = nil) {
            guard !stopped, let raw else { return }
            var text = normalize(raw, limit: limits.characterPerNode)
            guard !text.isEmpty, seenText.insert(text).inserted else { return }
            let remaining = limits.charactersCollected - result.charactersCollected
            guard remaining > 0 else { result.truncated = true; stopped = true; return }
            if text.count > remaining { text = String(text.prefix(remaining)) }
            result.segments.append(ScreenTextSegment(kind: kind, text: text, order: order, caretOffset: caret.map { min($0, text.utf16.count) }))
            order += 1
            result.charactersCollected += text.count
            if result.charactersCollected >= limits.charactersCollected { result.truncated = true; stopped = true }
        }

        func visit(_ node: Node, context: ScreenTextSegment.Kind, inherited: ScreenTextSegment.Kind?)
            -> (descend: Bool, visibleOnly: Bool, inherit: ScreenTextSegment.Kind?) {
            let a = attributes(node)
            if a.hidden { return (false, false, nil) }
            if a.isSecure { result.skippedSecure += 1; return (false, false, nil) }
            let kind = inherited ?? context
            let role = a.role
            if role == "AXStaticText" {
                emit(kind, first(a.value, a.title, a.description)); return (false, false, nil)
            }
            if textRoles.contains(role) {
                emit(kind, first(a.visibleText, a.value.map { String($0.prefix(limits.characterPerNode)) })); return (false, false, nil)
            }
            if role == "AXHeading" {
                let headingKind: ScreenTextSegment.Kind = inherited == .control ? .control : .heading
                emit(headingKind, first(a.title, a.value, a.description)); return (true, false, headingKind)
            }
            if role == "AXLink" { emit(kind, first(a.title, a.description)); return (true, false, inherited) }
            if menuRoles.contains(role) { return (false, false, nil) }
            if role == "AXToolbar" { return (true, false, .control) }
            if controlRoles.contains(role) || a.subrole == "AXTab" { emit(.control, a.title); return (false, false, nil) }
            if role == "AXImage" {
                if let description = a.description, description.count <= 80 { emit(.control, description) }
                return (false, false, nil)
            }
            emit(kind, a.title)
            return (true, visibleChildRoles.contains(role), inherited)
        }

        func walk(from root: Node, context: ScreenTextSegment.Kind) {
            var queue: [(node: Node, depth: Int, inherited: ScreenTextSegment.Kind?)] = [(root, 0, nil)]
            var head = 0
            while head < queue.count, !stopped {
                let item = queue[head]; head += 1
                guard visited.insert(item.node).inserted else { continue }
                if result.nodesVisited >= limits.axNodes || now() >= deadline { result.truncated = true; stopped = true; return }
                result.nodesVisited += 1
                let step = visit(item.node, context: context, inherited: item.inherited)
                guard step.descend else { continue }
                guard item.depth < limits.axDepth else { result.truncated = true; continue }
                for child in children(item.node, step.visibleOnly) where !visited.contains(child) {
                    queue.append((child, item.depth + 1, step.inherit))
                }
            }
        }

        // 1. Focused field first, from the already captured value; no AX calls.
        if let focusedValue {
            if let focused { visited.insert(focused) }
            let windowed = focusedWindow(focusedValue, caret: focusedRange?.location, limit: limits.characterPerNode)
            emit(.focused, windowed.text, caret: windowed.caret)
        }
        // 2. Window title.
        if let windowTitle { emit(.windowTitle, String(windowTitle.prefix(200))) }
        // 3. Neighbourhood: up to three ancestors of the focused element, nearest first.
        if let focused {
            var current = focused, climbed: [Node] = [], seen: Set<Node> = [focused]
            while climbed.count < 3, !stopped, let up = parent(current), up != window, seen.insert(up).inserted {
                climbed.append(up); current = up
            }
            for ancestor in climbed where !stopped { walk(from: ancestor, context: .neighbour) }
        }
        // 4. Rest of the window in child (reading) order.
        if !stopped { walk(from: window, context: .body) }
        return result
    }

    /// Strips C0/C1 controls (except newline), bidi overrides/isolates and
    /// zero-width characters, collapses spaces, and caps at `limit` characters.
    public static func normalize(_ text: String, limit: Int = ScreenContextLimits.standard.characterPerNode) -> String {
        String(collapse(text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(max(0, limit)))
    }

    static func isInvisibleControl(_ value: UInt32) -> Bool {
        (value < 0x20 && value != 0x0A && value != 0x09) || (0x7F...0x9F).contains(value)
            || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
            || (0x200B...0x200F).contains(value) || value == 0x2060 || value == 0xFEFF
    }

    private static func collapse(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastSpace = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A { scalars.append(scalar); lastSpace = false; continue }
            if isInvisibleControl(value) { continue }
            if value == 0x09 || scalar.properties.isWhitespace {
                if !lastSpace { scalars.append(" ") }
                lastSpace = true; continue
            }
            scalars.append(scalar); lastSpace = false
        }
        return String(scalars)
    }

    /// Normalizes the focused value and keeps at most `limit` characters around the caret.
    static func focusedWindow(_ value: String, caret: Int?, limit: Int) -> (text: String, caret: Int?) {
        guard let caret else {
            let text = collapse(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return (String(text.suffix(limit)), nil)
        }
        let split = ScreenExcerptBuilder.characterIndex(in: value, utf16Offset: caret)
        var before = collapse(String(value[..<split])), after = collapse(String(value[split...]))
        while before.first?.isWhitespace == true { before.removeFirst() }
        while after.last?.isWhitespace == true { after.removeLast() }
        if before.count + after.count > limit {
            let keepBefore = min(before.count, max(limit - min(after.count, limit / 4), 0))
            before = String(before.suffix(keepBefore))
            after = String(after.prefix(limit - keepBefore))
        }
        return (before + after, before.utf16.count)
    }

    private static func first(_ values: String?...) -> String? {
        values.first { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) == false } ?? nil
    }
}

// MARK: - Terms

public enum ScreenTermExtractor {
    public static let kindWeights: [ScreenTerm.Kind: Double] = [
        .quoted: 3, .identifier: 3, .camelCase: 3, .embeddedLatin: 2.5, .properName: 2, .acronym: 1.5, .cjkRun: 0.5
    ]

    /// Ranked, filtered terms: high-confidence first, then score, then first occurrence.
    /// Deduplicated by `AppVocabulary.automaticTermKey`; at most `limits.asrTerms`.
    public static func terms(from collection: ScreenTextCollection, excludingKeys: Set<String>,
                             limits: ScreenContextLimits = .standard) -> [ScreenTerm] {
        let ordered = collection.segments.sorted { $0.order < $1.order }
        let main = ordered.filter { $0.kind != .control }.map(\.text).joined(separator: "\n")
        let controls = ordered.filter { $0.kind == .control }.map(\.text).joined(separator: "\n")
        let mainCandidates = (try? TermExtractor.candidates(in: main, options: .screenContext)) ?? []
        let controlCandidates = (try? TermExtractor.candidates(in: controls, options: .screenContext)) ?? []
        let controlBase = main.utf16.count + 1

        struct Entry { var text: String; var kind: ScreenTerm.Kind; var count: Int; var offset: Int; var inMain: Bool }
        var entries: [String: Entry] = [:], order: [String] = []
        for (candidate, inMain) in mainCandidates.map({ ($0, true) }) + controlCandidates.map({ ($0, false) }) {
            let key = AppVocabulary.automaticTermKey(candidate.text)
            guard !excludingKeys.contains(key) else { continue }
            let offset = inMain ? candidate.firstOffset : controlBase + candidate.firstOffset
            if var entry = entries[key] {
                entry.count += candidate.count
                if offset < entry.offset { entry.text = candidate.text; entry.offset = offset }
                entry.inMain = entry.inMain || inMain
                entries[key] = entry
            } else {
                entries[key] = Entry(text: candidate.text, kind: candidate.kind, count: candidate.count, offset: offset, inMain: inMain)
                order.append(key)
            }
        }
        let focused = ordered.filter { $0.kind == .focused }.map(\.text)
        let titled = ordered.filter { $0.kind == .heading || $0.kind == .windowTitle }.map(\.text)
        let ranked: [(term: ScreenTerm, offset: Int)] = order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            var score = (kindWeights[entry.kind] ?? 1) * (1 + log2(Double(max(1, entry.count))))
            if !entry.inMain { score *= 0.5 }
            if focused.contains(where: { $0.contains(entry.text) }) { score += 2 }
            if titled.contains(where: { $0.contains(entry.text) }) { score += 1 }
            return (ScreenTerm(text: entry.text, kind: entry.kind, count: entry.count, score: score), entry.offset)
        }
        return Array(ranked.sorted {
            if $0.term.highConfidence != $1.term.highConfidence { return $0.term.highConfidence }
            if $0.term.score != $1.term.score { return $0.term.score > $1.term.score }
            return $0.offset < $1.offset
        }.map(\.term).prefix(max(0, limits.asrTerms)))
    }
}

// MARK: - Excerpt

public enum ScreenExcerptBuilder {
    /// Bounded, redacted excerpt for the writing model: the focused field around
    /// the caret, the title and nearest heading, neighbours, then body/OCR lines.
    public static func excerpt(from collection: ScreenTextCollection, limit: Int = 1_500,
                               excludingSelection selection: String = "") -> String {
        guard limit > 0 else { return "" }
        let segments = collection.segments.sorted { $0.order < $1.order }
        var lines: [String] = [], seen = Set<String>(), total = 0
        /// Adds redacted lines while the running total stays within `cap`.
        func add(_ piece: String, cap: Int) {
            let cap = min(cap, limit)
            for line in redact(piece) {
                guard total < cap else { return }
                guard !line.isEmpty, !seen.contains(line) else { continue }
                let separator = lines.isEmpty ? 0 : 1
                let room = cap - total - separator
                guard room > 0 else { return }
                let kept = line.count > room ? String(line.prefix(room)) : line
                seen.insert(line); lines.append(kept); total += kept.count + separator
            }
        }
        if let focused = segments.first(where: { $0.kind == .focused }) {
            var piece = focusedPiece(focused)
            if !selection.isEmpty { piece = piece.replacingOccurrences(of: selection, with: "") }
            add(piece, cap: 900)
        }
        let phaseStart = total
        let title = segments.first { $0.kind == .windowTitle }?.text
        let heading = segments.first { $0.kind == .heading }?.text
        let titleParts = [title, heading].compactMap { $0 }.filter { !$0.isEmpty }
        if !titleParts.isEmpty {
            let line = ("Title: " + titleParts.joined(separator: " · ")).replacingOccurrences(of: "\n", with: " ")
            add(String(line.prefix(160)), cap: phaseStart + 161)
        }
        for segment in segments where segment.kind == .neighbour { add(segment.text, cap: 1_300) }
        for segment in segments where segment.kind == .body || segment.kind == .ocrLine { add(segment.text, cap: limit) }
        let result = lines.joined(separator: "\n")
        return result.count > limit ? String(result.prefix(limit)) : result
    }

    private static func focusedPiece(_ segment: ScreenTextSegment) -> String {
        let text = segment.text
        guard let offset = segment.caretOffset else {
            guard text.count > 900 else { return text }
            return cutLeading(String(text.suffix(900)))
        }
        let caret = characterIndex(in: text, utf16Offset: offset)
        let beforeAll = text[..<caret], afterAll = text[caret...]
        var before = String(beforeAll.suffix(700)), after = String(afterAll.prefix(200))
        if beforeAll.count > 700 { before = cutLeading(before) }
        if afterAll.count > 200, let space = after.suffix(40).lastIndex(where: \.isWhitespace) { after = String(after[..<space]) }
        return before + after
    }

    /// Drops a leading partial word when a whitespace or line boundary is near the cut.
    private static func cutLeading(_ text: String) -> String {
        guard let space = text.prefix(40).firstIndex(where: \.isWhitespace) else { return text }
        return String(text[text.index(after: space)...])
    }

    /// A Character boundary at or before a UTF-16 offset, clamped to the string.
    public static func characterIndex(in text: String, utf16Offset: Int) -> String.Index {
        let clamped = max(0, min(utf16Offset, text.utf16.count))
        let raw = text.utf16.index(text.utf16.startIndex, offsetBy: clamped)
        if raw == text.endIndex { return text.endIndex }
        var boundary = text.startIndex
        for index in text.indices {
            if index > raw { break }
            boundary = index
        }
        return boundary
    }

    private static let longDigits = try! NSRegularExpression(pattern: #"[0-9]{13,}"#)
    private static let tokenPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9_+/=-]{20,}"#)

    /// Drops credential/URL lines, masks long digit runs and secret-like tokens.
    static func redact(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !TermExtractor.isUnsafeLine(line) else { return nil }
            var value = longDigits.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "[number]")
            let ns = value as NSString
            for match in tokenPattern.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed()
            where TermExtractor.isSecretLike(ns.substring(with: match.range)) {
                value = (value as NSString).replacingCharacters(in: match.range, with: "[redacted]")
            }
            return value
        }
    }
}

// MARK: - Snapshot

public struct ScreenContextSnapshot: Equatable, Sendable {
    /// `[.accessibility]`, `[.ocr]` or both, AX first.
    public var sources: [ScreenContextSource]
    public var bundleID: String
    public var applicationName: String
    /// At most `ScreenContextLimits.excerptCharacters`.
    public var excerpt: String
    /// Ranked, policy-filtered, at most `ScreenContextLimits.asrTerms`.
    public var terms: [ScreenTerm]
    public var nodesVisited: Int
    public var charactersCollected: Int
    /// Any budget was hit.
    public var truncated: Bool
    public var skippedSecure: Int
    public var capturedAt: Date

    public init(sources: [ScreenContextSource], bundleID: String, applicationName: String, excerpt: String, terms: [ScreenTerm],
                nodesVisited: Int = 0, charactersCollected: Int = 0, truncated: Bool = false, skippedSecure: Int = 0, capturedAt: Date = Date()) {
        self.sources = sources; self.bundleID = bundleID; self.applicationName = applicationName; self.excerpt = excerpt
        self.terms = terms; self.nodesVisited = nodesVisited; self.charactersCollected = charactersCollected
        self.truncated = truncated; self.skippedSecure = skippedSecure; self.capturedAt = capturedAt
    }

    /// Builds a snapshot from collected text, excluding existing vocabulary spellings.
    /// Nil when the collection yields neither terms nor an excerpt.
    public static func make(collection: ScreenTextCollection, source: ScreenContextSource, bundleID: String,
                            applicationName: String, vocabulary: AppVocabulary,
                            limits: ScreenContextLimits = .standard, now: Date = Date()) -> Self? {
        let terms = ScreenTermExtractor.terms(from: collection, excludingKeys: ScreenContextPolicy.vocabularyKeys(vocabulary), limits: limits)
        let excerpt = ScreenExcerptBuilder.excerpt(from: collection, limit: limits.excerptCharacters)
        guard !terms.isEmpty || !excerpt.isEmpty else { return nil }
        return Self(sources: [source], bundleID: bundleID, applicationName: applicationName, excerpt: excerpt, terms: terms,
                    nodesVisited: collection.nodesVisited, charactersCollected: collection.charactersCollected,
                    truncated: collection.truncated, skippedSecure: collection.skippedSecure, capturedAt: now)
    }

    /// AX excerpt first, then OCR lines; terms unioned by `automaticTermKey` in AX order
    /// first, high-confidence terms before low-confidence ones.
    public static func merged(_ ax: Self?, _ ocr: Self?, limits: ScreenContextLimits = .standard) -> Self? {
        guard let ax else { return ocr }
        guard let ocr else { return ax }
        var seenLines = Set<String>(), lines: [String] = []
        for line in (ax.excerpt + "\n" + ocr.excerpt).components(separatedBy: "\n") where !line.isEmpty && seenLines.insert(line).inserted {
            lines.append(line)
        }
        var excerpt = lines.joined(separator: "\n")
        if excerpt.count > limits.excerptCharacters { excerpt = String(excerpt.prefix(limits.excerptCharacters)) }
        var keys = Set<String>(), terms: [ScreenTerm] = []
        for term in ax.terms + ocr.terms where keys.insert(AppVocabulary.automaticTermKey(term.text)).inserted { terms.append(term) }
        terms = terms.filter(\.highConfidence) + terms.filter { !$0.highConfidence }
        return Self(sources: [.accessibility, .ocr], bundleID: ax.bundleID, applicationName: ax.applicationName, excerpt: excerpt,
                    terms: Array(terms.prefix(limits.asrTerms)), nodesVisited: ax.nodesVisited + ocr.nodesVisited,
                    charactersCollected: ax.charactersCollected + ocr.charactersCollected,
                    truncated: ax.truncated || ocr.truncated, skippedSecure: ax.skippedSecure + ocr.skippedSecure,
                    capturedAt: max(ax.capturedAt, ocr.capturedAt))
    }
}

/// What a writing request receives. Built from a snapshot for a mode.
public struct ScreenWritingContext: Equatable, Sendable {
    /// Primary source of the excerpt.
    public var source: ScreenContextSource
    /// Empty for Edit mode (terms only).
    public var excerpt: String
    /// At most `writingTerms`, high-confidence only.
    public var terms: [String]

    public init(source: ScreenContextSource, excerpt: String, terms: [String]) {
        self.source = source; self.excerpt = excerpt; self.terms = terms
    }

    /// Nil for Verbatim and Ask, and when nothing remains to send.
    public init?(snapshot: ScreenContextSnapshot, mode: WritingMode, limits: ScreenContextLimits = .standard) {
        let excerpt: String
        switch mode {
        case .verbatim, .ask: return nil
        case .polish, .translate: excerpt = String(snapshot.excerpt.prefix(limits.excerptCharacters))
        case .edit: excerpt = ""
        }
        let terms = Array(snapshot.terms.filter(\.highConfidence).map(\.text).prefix(limits.writingTerms))
        guard !excerpt.isEmpty || !terms.isEmpty else { return nil }
        self.init(source: snapshot.sources.first ?? .accessibility, excerpt: excerpt, terms: terms)
    }

    public var isEmpty: Bool { excerpt.isEmpty && terms.isEmpty }
}

/// Result of "Extract from this screen" for the Vocabulary review sheet.
public struct ScreenContextScan: Sendable {
    /// Text only; sources empty; isProject false.
    public var candidates: [AgentContextCandidate]
    public var source: ScreenContextSource?
    public var applicationName: String
    public var charactersRead: Int
    public var excluded: Bool
    public var limited: Bool

    public init(candidates: [AgentContextCandidate] = [], source: ScreenContextSource? = nil, applicationName: String = "",
                charactersRead: Int = 0, excluded: Bool = false, limited: Bool = false) {
        self.candidates = candidates; self.source = source; self.applicationName = applicationName
        self.charactersRead = charactersRead; self.excluded = excluded; self.limited = limited
    }

    /// At most 200 candidates of 2–64 characters without newlines (the
    /// `ContextVocabularyFilter.request` precondition), excluding vocabulary spellings.
    public static func make(collections: [ScreenTextCollection], source: ScreenContextSource?, applicationName: String,
                            vocabulary: AppVocabulary) -> Self {
        var order = 0
        var merged = ScreenTextCollection()
        for collection in collections {
            for segment in collection.segments.sorted(by: { $0.order < $1.order }) {
                var copy = segment; copy.order = order; order += 1; merged.segments.append(copy)
            }
            merged.charactersCollected += collection.charactersCollected
            merged.truncated = merged.truncated || collection.truncated
        }
        var limits = ScreenContextLimits.standard
        limits.asrTerms = Int.max
        let terms = ScreenTermExtractor.terms(from: merged, excludingKeys: ScreenContextPolicy.vocabularyKeys(vocabulary), limits: limits)
            .map(\.text).filter { (2...64).contains($0.count) && !$0.contains(where: \.isNewline) }
        return Self(candidates: terms.prefix(200).map { AgentContextCandidate(text: $0, sources: []) }, source: source,
                    applicationName: applicationName, charactersRead: merged.charactersCollected,
                    excluded: false, limited: merged.truncated || terms.count > 200)
    }
}

// MARK: - Cache

/// OCR-derived snapshots keyed by "pid:windowID", memory only.
public struct ScreenContextCache {
    private struct Entry { let key: String; let snapshot: ScreenContextSnapshot; let storedAt: Date }
    private var entries: [Entry] = []
    private let limits: ScreenContextLimits
    public init(limits: ScreenContextLimits = .standard) { self.limits = limits }

    public static func key(pid: Int32, windowID: UInt32) -> String { "\(pid):\(windowID)" }

    public var count: Int { entries.count }

    public mutating func store(_ snapshot: ScreenContextSnapshot, key: String, now: Date) {
        entries.removeAll { $0.key == key || now.timeIntervalSince($0.storedAt) >= limits.cacheSeconds }
        entries.append(Entry(key: key, snapshot: snapshot, storedAt: now))
        if entries.count > max(0, limits.cacheEntries) { entries.removeFirst(entries.count - max(0, limits.cacheEntries)) }
    }

    public mutating func snapshot(for key: String, now: Date) -> ScreenContextSnapshot? {
        entries.removeAll { now.timeIntervalSince($0.storedAt) >= limits.cacheSeconds }
        return entries.first { $0.key == key }?.snapshot
    }

    public mutating func remove(pid: Int32) { entries.removeAll { $0.key.hasPrefix("\(pid):") } }
    public mutating func clear() { entries.removeAll() }
}

// MARK: - Policy

public enum ScreenContextPolicy {
    /// Verified password-manager bundle IDs. Never removable.
    public static let builtInExcludedBundleIDs: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords"
    ]

    /// Trims, drops invalid IDs, deduplicates case-insensitively (first spelling wins), keeps at most 200.
    public static func sanitizedExclusions(_ ids: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"#, options: .regularExpression) != nil,
                  seen.insert(id.lowercased()).inserted else { continue }
            result.append(id)
            if result.count == 200 { break }
        }
        return result
    }

    /// Case-insensitive, exact match. VoiceDraft itself is always excluded.
    public static func allows(bundleID: String?, options: DesktopOptions, ownBundleID: String?) -> Bool {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { return false }
        if let own = ownBundleID?.lowercased(), own == id { return false }
        return !(builtInExcludedBundleIDs + options.screenContextExcludedApps).contains { $0.lowercased() == id }
    }

    /// A dictation take reads the screen only for another app's non-secure field,
    /// with the master switch and at least one consumer on.
    public static func shouldCapture(options: DesktopOptions, external: Bool, secure: Bool, bundleID: String?, ownBundleID: String?) -> Bool {
        options.screenContext && (options.screenContextASR || options.screenContextWriting) && external && !secure
            && allows(bundleID: bundleID, options: options, ownBundleID: ownBundleID)
    }

    /// True when AX was unavailable or exposed too little content text.
    public static func needsOCR(_ collection: ScreenTextCollection?, limits: ScreenContextLimits = .standard) -> Bool {
        guard let collection else { return true }
        return collection.contentCharacters < limits.ocrThresholdCharacters
    }

    /// Lowest-priority recognition hints. Empty when vocabulary is globally disabled;
    /// never re-introduces an existing (even disabled) or deleted vocabulary term.
    public static func asrTerms(_ snapshot: ScreenContextSnapshot?, vocabulary: AppVocabulary,
                                limits: ScreenContextLimits = .standard) -> [String] {
        guard vocabulary.enabled, let snapshot else { return [] }
        let known = vocabularyKeys(vocabulary)
        var result: [String] = [], keys = Set<String>(), bytes = 0
        let ordered = snapshot.terms.filter(\.highConfidence) + snapshot.terms.filter { !$0.highConfidence }
        for term in ordered {
            guard result.count < limits.asrTerms else { break }
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...64).contains(text.count), !text.contains(where: \.isNewline),
                  text.split(whereSeparator: \.isWhitespace).count <= 4 else { continue }
            let key = AppVocabulary.automaticTermKey(text)
            guard !known.contains(key), !keys.contains(key) else { continue }
            let added = text.utf8.count + (result.isEmpty ? 0 : 2)
            guard bytes + added <= limits.asrBytes else { continue }
            keys.insert(key); result.append(text); bytes += added
        }
        return result
    }

    /// `automaticTermKey` values, for excluding screen terms from discovery learning.
    public static func keys(of terms: [String]) -> Set<String> { Set(terms.map(AppVocabulary.automaticTermKey)) }

    /// Keys of every vocabulary spelling (enabled or not) plus deletion suppressions.
    public static func vocabularyKeys(_ vocabulary: AppVocabulary) -> Set<String> {
        Set(vocabulary.entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.filter { !$0.isEmpty }.map(AppVocabulary.automaticTermKey))
            .union(vocabulary.excludedAutomaticTerms)
    }

    /// Interface language's OCR code, then zh-Hans, then en-US; filtered by `supported`, at most 3.
    public static func ocrLanguages(interface: String, supported: [String]) -> [String] {
        let code = interface.lowercased().replacingOccurrences(of: "_", with: "-")
        let mapped: String?
        if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") || code.hasPrefix("zh-mo") { mapped = "zh-Hant" }
        else if code.hasPrefix("zh") { mapped = "zh-Hans" }
        else {
            let table = ["en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "de": "de-DE", "fr": "fr-FR", "es": "es-ES"]
            mapped = table[String(code.prefix(while: { $0 != "-" }))]
        }
        var result: [String] = []
        for language in [mapped, "zh-Hans", "en-US"].compactMap({ $0 }) where supported.contains(language) && !result.contains(language) {
            result.append(language)
        }
        return Array(result.prefix(3))
    }
}

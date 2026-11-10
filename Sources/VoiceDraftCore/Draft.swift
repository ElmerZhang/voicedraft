import Foundation

/// What a programmatic write into a draft was.
public enum DraftTakeKind: String, Codable, Sendable, CaseIterable {
    /// A dictated paragraph inserted at the caret (or over the selection).
    case dictation
    /// A voice instruction applied to the selected text.
    case selectionEdit
    /// A voice instruction applied to the whole draft (Edit with nothing selected).
    case wholeDraftEdit
    /// A named writing style applied to the selected text.
    case styleApply
    /// The last take written again from its transcript, usually with another style.
    case repolish
}

/// One programmatic write into a draft. Keyboard edits are not takes.
public struct DraftTake: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// UTF-16 location of `result` in the draft text. `NSNotFound` once an edit
    /// overlapped the written text, so the take is no longer intact.
    public var location: Int
    /// UTF-16 length of `result`.
    public var length: Int
    /// The recognized speech (the instruction for Edit kinds, the source text for style apply).
    public var transcript: String
    /// The text written into the draft.
    public var result: String
    /// History entry saved for the take, when History is on.
    public var historyID: UUID?
    public var kind: DraftTakeKind
    /// Writing mode of the take; re-polish keeps Translate for a translated take.
    public var mode: WritingMode

    public init(id: UUID = UUID(), date: Date = Date(), range: NSRange, transcript: String, result: String,
                historyID: UUID? = nil, kind: DraftTakeKind, mode: WritingMode = .polish) {
        self.id = id; self.date = date; location = range.location; length = range.length
        self.transcript = transcript; self.result = result; self.historyID = historyID; self.kind = kind; self.mode = mode
    }

    public var range: NSRange {
        get { NSRange(location: location, length: length) }
        set { location = newValue.location; length = newValue.length }
    }

    /// Whether re-polishing makes sense: the transcript is the text to write
    /// again, not an instruction (Edit kinds).
    public var canRepolish: Bool { kind == .dictation || kind == .repolish || kind == .styleApply }

    /// The take's range after a text edit. `editedRange` and `changeInLength`
    /// are `NSTextStorage`'s post-edit values. An edit entirely before the take
    /// shifts it, one entirely after leaves it, and an overlapping edit
    /// invalidates it (`location == NSNotFound`).
    public func shifted(byEditIn editedRange: NSRange, changeInLength delta: Int) -> DraftTake {
        guard location != NSNotFound else { return self }
        var copy = self
        // The replaced pre-edit span is [start, oldEnd); an insertion has oldEnd == start.
        let start = editedRange.location, oldEnd = editedRange.location + editedRange.length - delta
        if oldEnd <= location { copy.location += delta }            // before the take, or inserted at its start
        else if start >= location + length { }                     // after the take, or inserted at its end
        else { copy.location = NSNotFound }                         // overlaps the written text
        return copy
    }
}

/// A long-form draft written by voice one paragraph per take.
public struct DraftDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var text: String
    public var takes: [DraftTake]

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String = "", takes: [DraftTake] = []) {
        self.id = id; self.createdAt = createdAt; updatedAt = createdAt; self.text = text; self.takes = takes
    }

    /// Characters shown in the drafts list at most.
    public static let titleLimit = 60

    /// The first non-empty line, trimmed and capped; nil for a blank draft.
    public var title: String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return trimmed.count > Self.titleLimit ? String(trimmed.prefix(Self.titleLimit)) + "…" : trimmed
        }
        return nil
    }

    /// The title, or the localized "Untitled draft".
    public var displayTitle: String { title ?? D("Untitled draft") }

    /// Whether the last take's recorded range still holds exactly its result.
    public static func lastTakeIsIntact(_ document: DraftDocument) -> Bool {
        guard let take = document.takes.last else { return false }
        return DraftText.holds(take, in: document.text)
    }
}

/// Where a dictated passage goes in a draft.
public struct DraftInsertion: Equatable, Sendable {
    /// The range of the current text to replace (UTF-16).
    public var replacementRange: NSRange
    /// The text that replaces it, including any paragraph separators.
    public var replacement: String
    /// The caret after the write (UTF-16), at the end of the dictated text.
    public var caretAfter: Int
    /// Where the dictated text itself lands in the new text (UTF-16), without separators.
    public var textRange: NSRange
}

/// Pure text rules of the draft window. Offsets are UTF-16, like `NSTextView`.
public enum DraftText {
    /// Where `dictated` goes for the current `selection`:
    ///
    /// - a non-empty selection is replaced by the passage;
    /// - a caret on an empty line, or at the start or end of a non-empty line
    ///   (the neighbouring side is a line break or the document edge), makes the
    ///   passage its own paragraph: the line breaks around the caret are
    ///   replaced by exactly one blank line on each side that touches existing
    ///   text, and no blank line at the document edges;
    /// - a caret inside a paragraph inserts inline, without spaces, except one
    ///   ASCII space on a side where both neighbours are Latin letters or digits.
    ///
    /// Line breaks at the passage's own edges are dropped.
    public static func insertion(for dictated: String, into text: String, selection: NSRange) -> DraftInsertion {
        let passage = dictated.trimmingCharacters(in: .newlines)
        let units = Array(text.utf16)
        let count = units.count
        let location = min(max(0, selection.location == NSNotFound ? count : selection.location), count)
        let length = min(max(0, selection.length), count - location)
        let passageLength = passage.utf16.count
        if length > 0 {
            return DraftInsertion(replacementRange: NSRange(location: location, length: length), replacement: passage,
                                  caretAfter: location + passageLength, textRange: NSRange(location: location, length: passageLength))
        }
        let before = location > 0 ? units[location - 1] : nil
        let after = location < count ? units[location] : nil
        let atLineStart = before.map(isLineBreak) ?? true
        let atLineEnd = after.map(isLineBreak) ?? true
        if atLineStart || atLineEnd {
            var start = location, end = location
            while start > 0, isLineBreak(units[start - 1]) { start -= 1 }
            while end < count, isLineBreak(units[end]) { end += 1 }
            let prefix = start > 0 ? "\n\n" : ""
            let suffix = end < count ? "\n\n" : ""
            let textStart = start + prefix.utf16.count
            return DraftInsertion(replacementRange: NSRange(location: start, length: end - start), replacement: prefix + passage + suffix,
                                  caretAfter: textStart + passageLength, textRange: NSRange(location: textStart, length: passageLength))
        }
        let first = passage.utf16.first, last = passage.utf16.last
        let leading = before.map(isLatinAlphanumeric) == true && first.map(isLatinAlphanumeric) == true ? " " : ""
        let trailing = after.map(isLatinAlphanumeric) == true && last.map(isLatinAlphanumeric) == true ? " " : ""
        let textStart = location + leading.utf16.count
        return DraftInsertion(replacementRange: NSRange(location: location, length: 0), replacement: leading + passage + trailing,
                              caretAfter: textStart + passageLength, textRange: NSRange(location: textStart, length: passageLength))
    }

    /// Whether `take`'s recorded range in `text` holds exactly its result.
    public static func holds(_ take: DraftTake, in text: String) -> Bool {
        holds(take.result, at: take.range, in: text)
    }

    /// Whether `range` (UTF-16) of `text` is exactly `expected`.
    public static func holds(_ expected: String, at range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location + range.length <= ns.length else { return false }
        return ns.substring(with: range) == expected
    }

    /// Reference text around a range for the long-form Polish variant: at most
    /// `beforeLimit` characters before it and `afterLimit` after it, never
    /// splitting a character.
    public static func surroundings(of range: NSRange, in text: String, beforeLimit: Int = 1500,
                                    afterLimit: Int = 500) -> (before: String, after: String) {
        let ns = text as NSString
        let location = min(max(0, range.location == NSNotFound ? ns.length : range.location), ns.length)
        let end = min(location + max(0, range.length), ns.length)
        let before = ns.substring(to: location), after = ns.substring(from: end)
        return (String(before.suffix(beforeLimit)), String(after.prefix(afterLimit)))
    }

    static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x0B || unit == 0x0C || unit == 0x85
    }

    static func isLatinAlphanumeric(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }
}

/// Persistence of drafts; the Mac app uses `FileDraftStore`.
public protocol DraftStore: AnyObject {
    /// Every readable draft, most recently updated first.
    func list() throws -> [DraftDocument]
    func save(_ document: DraftDocument) throws
    func delete(_ id: UUID) throws
}

/// One JSON file per draft (`<uuid>.json`) in a directory, written atomically.
/// Directory mode 0700, files 0600. Unreadable files are skipped by `list`.
public final class FileDraftStore: DraftStore {
    public let directory: URL
    // Default date encoding (like history.json), so dates round-trip exactly.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(directory: URL) { self.directory = directory }

    public func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    public func list() throws -> [DraftDocument] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let documents = files.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { try? decoder.decode(DraftDocument.self, from: Data(contentsOf: $0)) }
        return documents.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.createdAt > $1.createdAt }
    }

    public func save(_ document: DraftDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = url(for: document.id)
        try encoder.encode(document).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(_ id: UUID) throws {
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Draft-window context for a writing request, passed like `ScreenWritingContext`.
/// Never stored, synced or written to History.
public enum DraftWritingContext: Equatable, Sendable {
    /// A dictated passage at a point in the draft (Polish only): the text just
    /// before and after the insertion point, as reference data.
    case passage(before: String, after: String)
    /// An Edit whose selected text is the complete draft.
    case wholeDraft

    /// The passage context for `range` of `text` (1,500 characters before, 500 after).
    public static func passage(at range: NSRange, in text: String) -> DraftWritingContext {
        let around = DraftText.surroundings(of: range, in: text)
        return .passage(before: around.before, after: around.after)
    }
}

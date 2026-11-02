import Foundation

/// One calendar day of history entries, newest first, as the desktop History page shows them.
public struct HistoryDayGroup: Equatable, Identifiable {
    public let day: Date
    public let entries: [HistoryEntry]
    public var id: Date { day }
    public init(day: Date, entries: [HistoryEntry]) {
        self.day = day; self.entries = entries
    }
}

/// Filters, sorts and groups history for the History page in a single pass.
public enum HistoryListing {
    /// `filter`: 0 all entries, 1 everything except Ask anything, 2 Ask anything only.
    /// `query` is trimmed and matched case-insensitively against the result or the original transcript.
    /// Entries are sorted newest first and grouped by `calendar`'s start of day; days are newest first.
    public static func groups(_ history: [HistoryEntry], query: String, filter: Int, calendar: Calendar = .current) -> [HistoryDayGroup] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = history.filter {
            (filter == 0 || (filter == 2 ? $0.mode == .ask : $0.mode != .ask)) &&
            (term.isEmpty || $0.result.localizedCaseInsensitiveContains(term) || $0.original.localizedCaseInsensitiveContains(term))
        }.sorted { $0.date > $1.date }
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { HistoryDayGroup(day: $0, entries: byDay[$0] ?? []) }
    }
}

/// Filters and orders app vocabulary for the Vocabulary page.
public enum VocabularyListing {
    /// `originFilter`: 0 all, 1 automatic, 2 manual. `statusFilter`: 0 all, 1 enabled, 2 disabled.
    /// `query` is trimmed and matched case-insensitively against the text or any alias.
    /// Priority entries come first, then higher use counts, then the text in localized standard order.
    public static func entries(_ vocabulary: AppVocabulary, query: String, originFilter: Int, statusFilter: Int) -> [VocabularyEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return vocabulary.entries.filter {
            (originFilter == 0 || (originFilter == 1 ? $0.origin == .automatic : $0.origin == .manual)) &&
            (statusFilter == 0 || (statusFilter == 1 ? $0.enabled : !$0.enabled)) &&
            (term.isEmpty || $0.text.localizedCaseInsensitiveContains(term) || $0.aliases.contains { $0.localizedCaseInsensitiveContains(term) })
        }.sorted {
            if $0.priority != $1.priority { return $0.priority }
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }
    }
}

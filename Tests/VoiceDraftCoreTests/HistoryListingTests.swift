import XCTest
@testable import VoiceDraftCore

final class HistoryListingTests: XCTestCase {
    private let calendar: Calendar = {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return result
    }()
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func entry(_ timestamp: String, mode: WritingMode = .polish, original: String = "draft", result: String = "Draft") -> HistoryEntry {
        var entry = HistoryEntry(mode: mode, original: original, result: result, application: "Fixture", duration: 10)
        entry.date = date(timestamp)
        return entry
    }

    func testGroupsByLocalDayNewestFirst() {
        let early = entry("2026-10-14T17:00:00Z") // 15 Oct 01:00 local.
        let late = entry("2026-10-15T15:59:00Z") // 15 Oct 23:59 local.
        let older = entry("2026-10-14T15:00:00Z") // 14 Oct 23:00 local.
        let newest = entry("2026-10-15T16:00:00Z") // 16 Oct 00:00 local.
        let groups = HistoryListing.groups([early, older, newest, late], query: "", filter: 0, calendar: calendar)
        XCTAssertEqual(groups.map(\.day), [date("2026-10-15T16:00:00Z"), date("2026-10-14T16:00:00Z"), date("2026-10-13T16:00:00Z")])
        XCTAssertEqual(groups.map { $0.entries.map(\.id) }, [[newest.id], [late.id, early.id], [older.id]])
        XCTAssertEqual(groups.first?.id, groups.first?.day)
    }

    func testModeFilter() {
        let dictation = entry("2026-10-15T01:00:00Z", mode: .polish)
        let verbatim = entry("2026-10-15T02:00:00Z", mode: .verbatim)
        let ask = entry("2026-10-15T03:00:00Z", mode: .ask)
        let history = [dictation, verbatim, ask]
        XCTAssertEqual(HistoryListing.groups(history, query: "", filter: 0, calendar: calendar).flatMap(\.entries).map(\.id), [ask.id, verbatim.id, dictation.id])
        XCTAssertEqual(HistoryListing.groups(history, query: "", filter: 1, calendar: calendar).flatMap(\.entries).map(\.id), [verbatim.id, dictation.id])
        XCTAssertEqual(HistoryListing.groups(history, query: "", filter: 2, calendar: calendar).flatMap(\.entries).map(\.id), [ask.id])
    }

    func testQueryMatchesOriginalOrResultCaseInsensitivelyAfterTrimming() {
        let byResult = entry("2026-10-15T01:00:00Z", original: "um the plan", result: "The Roadmap")
        let byOriginal = entry("2026-10-15T02:00:00Z", original: "roadmap review", result: "Review notes")
        let neither = entry("2026-10-15T03:00:00Z", original: "lunch", result: "Lunch")
        let groups = HistoryListing.groups([byResult, byOriginal, neither], query: "  ROADMAP \n", filter: 0, calendar: calendar)
        XCTAssertEqual(groups.flatMap(\.entries).map(\.id), [byOriginal.id, byResult.id])
        XCTAssertTrue(HistoryListing.groups([neither], query: "roadmap", filter: 0, calendar: calendar).isEmpty)
        XCTAssertTrue(HistoryListing.groups([], query: "", filter: 0, calendar: calendar).isEmpty)
    }

    private func word(_ text: String, origin: VocabularyOrigin = .manual, enabled: Bool = true, priority: Bool = false,
                      uses: Int = 0, aliases: [String] = []) -> VocabularyEntry {
        var entry = VocabularyEntry(text: text, priority: priority)
        entry.origin = origin; entry.enabled = enabled; entry.useCount = uses; entry.aliases = aliases
        return entry
    }

    func testVocabularyOrderingPriorityThenUsesThenText() {
        var vocabulary = AppVocabulary()
        vocabulary.entries = [word("item10"), word("item2"), word("Busy", uses: 5), word("Starred", priority: true), word("Alpha")]
        let texts = VocabularyListing.entries(vocabulary, query: "", originFilter: 0, statusFilter: 0).map(\.text)
        XCTAssertEqual(texts, ["Starred", "Busy", "Alpha", "item2", "item10"])
    }

    func testVocabularyFiltersAndQuery() {
        var vocabulary = AppVocabulary()
        let manual = word("Kubernetes", aliases: ["k8s"])
        let automatic = word("Qwen", origin: .automatic)
        let disabled = word("Doubao", enabled: false)
        vocabulary.entries = [manual, automatic, disabled]
        func ids(_ query: String = "", origin: Int = 0, status: Int = 0) -> [UUID] {
            VocabularyListing.entries(vocabulary, query: query, originFilter: origin, statusFilter: status).map(\.id)
        }
        XCTAssertEqual(Set(ids()), [manual.id, automatic.id, disabled.id])
        XCTAssertEqual(ids(origin: 1), [automatic.id])
        XCTAssertEqual(Set(ids(origin: 2)), [manual.id, disabled.id])
        XCTAssertEqual(Set(ids(status: 1)), [manual.id, automatic.id])
        XCTAssertEqual(ids(status: 2), [disabled.id])
        XCTAssertEqual(ids(" K8S "), [manual.id])
        XCTAssertEqual(ids("qw"), [automatic.id])
        XCTAssertEqual(ids("qw", origin: 2), [])
    }
}

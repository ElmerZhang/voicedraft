import XCTest
@testable import VoiceDraftCore

final class UsageActivityTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Singapore", firstWeekday: Int = 1) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        result.firstWeekday = firstWeekday
        return result
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func entry(_ timestamp: String, duration: Double = 30) -> HistoryEntry {
        var entry = HistoryEntry(mode: .polish, original: "test", result: "test", application: "Fixture", duration: duration)
        entry.date = date(timestamp)
        return entry
    }

    func testLocalDayAggregationAndWindowBoundaries() {
        let activity = UsageActivity(history: [
            entry("2025-10-16T15:59:59Z"), // Before first local day.
            entry("2025-10-16T16:00:00Z", duration: 60),
            entry("2026-10-15T15:59:59Z", duration: 10),
            entry("2026-10-15T16:00:00Z", duration: 20),
            entry("2026-10-16T08:00:00Z", duration: 40),
            entry("2026-10-16T16:00:00Z") // Tomorrow locally.
        ], now: date("2026-10-16T10:00:00Z"), calendar: calendar())
        XCTAssertEqual(activity.days.count, 365)
        XCTAssertEqual(activity.totalCount, 4)
        XCTAssertEqual(activity.activeDays, 3)
        XCTAssertEqual(activity.totalDuration, 130)
        XCTAssertEqual(activity.days.first?.count, 1)
        XCTAssertEqual(activity.days.last?.count, 2)
        XCTAssertEqual(activity.days.last?.duration, 60)
        XCTAssertEqual(activity.weeks.flatMap { $0 }.compactMap { $0 }.map(\.date), activity.days.map(\.date))
    }

    func testLeapDayAndWeekAlignment() {
        for firstWeekday in [1, 2, 7] {
            let calendar = calendar(firstWeekday: firstWeekday)
            let activity = UsageActivity(history: [entry("2024-02-29T04:00:00Z")], now: date("2024-12-31T04:00:00Z"), calendar: calendar)
            XCTAssertEqual(activity.totalCount, 1)
            XCTAssertEqual(Set(activity.days.map(\.date)).count, 365)
            XCTAssertTrue(activity.weeks.allSatisfy { $0.count == 7 })
            for week in activity.weeks {
                for (row, day) in week.enumerated() {
                    guard let day else { continue }
                    XCTAssertEqual(calendar.component(.weekday, from: day.date), (firstWeekday - 1 + row) % 7 + 1)
                }
            }
        }
    }

    func testDaylightSavingUsesCalendarDays() {
        let activity = UsageActivity(history: [
            entry("2026-03-08T09:30:00Z"), // 01:30 before spring-forward.
            entry("2026-03-08T10:30:00Z")  // 03:30 after spring-forward.
        ], now: date("2026-03-10T12:00:00Z"), calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(activity.activeDays, 1)
        XCTAssertEqual(activity.days[362].count, 2)
        XCTAssertEqual(Set(activity.days.map(\.date)).count, 365)
        XCTAssertEqual(activity.days[363].date.timeIntervalSince(activity.days[362].date), 23 * 3600)
    }

    func testEmptyHistoryAndRemovalRecomputeWithoutPhantomActivity() {
        let now = date("2026-10-16T04:00:00Z")
        let entries = (0..<16).map { _ in entry("2026-10-16T03:00:00Z", duration: 0) }
        for (count, level) in [(0, 0), (1, 1), (3, 1), (4, 2), (7, 2), (8, 3), (15, 3), (16, 4)] {
            let activity = UsageActivity(history: Array(entries.prefix(count)), now: now, calendar: calendar())
            XCTAssertEqual(activity.days.last?.level, level)
            XCTAssertEqual(activity.totalCount, count)
            XCTAssertEqual(activity.activeDays, count == 0 ? 0 : 1)
            XCTAssertEqual(activity.totalDuration, 0)
        }
    }
}

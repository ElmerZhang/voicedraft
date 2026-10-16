import Foundation

/// Compact Home totals over all retained history, with yesterday omitted when empty.
public struct UsageSummary {
    public private(set) var totalCount = 0
    public private(set) var totalDuration: TimeInterval = 0
    public private(set) var yesterday: UsageActivity.Day?

    public init(history: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: today)!
        for entry in history {
            let day = calendar.startOfDay(for: entry.date)
            guard day <= today else { continue }
            let duration = entry.duration.isFinite ? max(0, entry.duration) : 0
            totalCount += 1
            totalDuration += duration
            if day == previousDay {
                if yesterday == nil { yesterday = UsageActivity.Day(date: previousDay) }
                yesterday?.count += 1
                yesterday?.duration += duration
            }
        }
    }
}

/// A calendar projection of retained local history, not a lifetime usage ledger.
public struct UsageActivity {
    public struct Day: Identifiable {
        public var id: Date { date }
        public let date: Date
        public var count = 0
        public var duration: TimeInterval = 0

        public var level: Int {
            switch count {
            case 0: return 0
            case 1...3: return 1
            case 4...7: return 2
            case 8...15: return 3
            default: return 4
            }
        }
    }

    public let days: [Day]
    /// Complete calendar weeks; padding outside the 365-day window is not a zero-use day.
    public let weeks: [[Day?]]
    public var totalCount: Int { days.reduce(0) { $0 + $1.count } }
    public var activeDays: Int { days.filter { $0.count > 0 }.count }
    public var totalDuration: TimeInterval { days.reduce(0) { $0 + $1.duration } }

    public init(history: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -364, to: today)!
        var totals: [Date: Day] = [:]
        for entry in history {
            let date = calendar.startOfDay(for: entry.date)
            guard date >= start, date <= today else { continue }
            var day = totals[date] ?? Day(date: date)
            day.count += 1
            if entry.duration.isFinite { day.duration += max(0, entry.duration) }
            totals[date] = day
        }
        days = (0..<365).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return totals[date] ?? Day(date: date)
        }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var cells = Array<Day?>(repeating: nil, count: leading) + days.map(Optional.some)
        cells += Array<Day?>(repeating: nil, count: (7 - cells.count % 7) % 7)
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}

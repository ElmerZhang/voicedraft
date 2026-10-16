import SwiftUI
import VoiceDraftCore

struct UsageSummaryView: View {
    let history: [HistoryEntry]
    let viewMore: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = UsageSummary(history: history, now: context.date)
            VDSurface(spacing: VD.Space.xl) {
                HStack {
                    Text(D("Usage activity")).font(VD.Font.cardTitle)
                    Spacer()
                    Button(action: viewMore) {
                        HStack(spacing: VD.Space.xs) {
                            Text(D("View more"))
                            Image(systemName: "arrow.up.right").accessibilityHidden(true)
                        }.font(VD.Font.detail).padding(.vertical, VD.Space.s)
                            .padding(.horizontal, VD.Space.xs).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(VD.Palette.accent)
                }
                HStack(alignment: .top, spacing: VD.Space.xxl) {
                    if let yesterday = summary.yesterday {
                        metric(D("Yesterday"), count: yesterday.count, duration: yesterday.duration)
                        Divider()
                    }
                    metric(D("Total usage"), count: summary.totalCount, duration: summary.totalDuration)
                }.fixedSize(horizontal: false, vertical: true)
                Text(D("Based on history on this Mac.")).font(VD.Font.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, count: Int, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: VD.Space.s) {
            Text(title).font(VD.Font.detail).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: VD.Space.s) {
                Text(count.formatted(.number.locale(locale))).font(VD.Font.pageTitle).monospacedDigit()
                Text(D("saved entries")).font(VD.Font.detail).foregroundStyle(.secondary)
            }
            Text("\(Int(duration / 60).formatted(.number.locale(locale))) \(D("minutes recorded"))")
                .font(VD.Font.detail).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct UsageActivityView: View {
    let history: [HistoryEntry]
    let keepHistory: Bool
    @State private var hoveredDate: Date?
    @Environment(\.locale) private var locale

    var body: some View {
        // Refresh the date window even when Usage stays open overnight.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let activity = UsageActivity(history: history, now: context.date)
            VDSurface(spacing: VD.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text(D("Usage activity")).font(VD.Font.sectionTitle)
                    Spacer()
                    Text(D("Last 365 days")).font(VD.Font.detail).foregroundStyle(.secondary)
                }
                HStack(spacing: VD.Space.xxl) {
                    metric(activity.totalCount, label: D("saved entries"))
                    metric(activity.activeDays, label: D("active days"))
                    metric(Int(activity.totalDuration / 60), label: D("minutes recorded"))
                }.padding(.bottom, VD.Space.s)
                GeometryReader { geometry in
                    let size = max(9, min(16, (geometry.size.width - 60) / CGFloat(activity.weeks.count) - 4))
                    calendarGrid(activity, size: size)
                }.frame(height: 164)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: VD.Space.m) { dayDetail(activity); Spacer(); legend }
                    VStack(alignment: .leading, spacing: VD.Space.s) { dayDetail(activity); legend }
                }
                Divider()
                Text(D("Based on saved history on this Mac. Deleted and expired entries are not included."))
                    .font(VD.Font.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !keepHistory {
                    Text(D("History is off. New activity will appear after you enable history."))
                        .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if activity.totalCount == 0 {
                    Text(D("Use a dictation shortcut to start filling your activity calendar."))
                        .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func calendarGrid(_ activity: UsageActivity, size: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: VD.Space.xs) {
                VStack(spacing: VD.Space.xs) {
                    Color.clear.frame(height: 20)
                    ForEach(0..<7) { row in
                        Text(row % 2 == 1 ? weekday(row) : "")
                            .font(VD.Font.footnote).foregroundStyle(.secondary)
                            .frame(width: 32, height: size, alignment: .leading)
                    }
                }.accessibilityHidden(true)
                HStack(alignment: .top, spacing: VD.Space.xs) {
                    ForEach(activity.weeks.indices, id: \.self) { weekIndex in
                        VStack(spacing: VD.Space.xs) {
                            Text(monthLabel(activity.weeks[weekIndex]))
                                .font(VD.Font.footnote).foregroundStyle(.secondary)
                                .fixedSize().frame(width: size, height: 20, alignment: .leading)
                                .accessibilityHidden(true)
                            ForEach(0..<7) { row in
                                if let day = activity.weeks[weekIndex][row] {
                                    RoundedRectangle(cornerRadius: VD.Radius.activityCell)
                                        .fill(VD.Palette.activityLevels[day.level])
                                        .overlay(RoundedRectangle(cornerRadius: VD.Radius.activityCell)
                                            .strokeBorder(hoveredDate == day.date ? VD.Palette.ink : VD.Palette.line, lineWidth: 1))
                                        .frame(width: size, height: size)
                                        .help(description(day))
                                        .onHover { hovering in
                                            if hovering { hoveredDate = day.date }
                                            else if hoveredDate == day.date { hoveredDate = nil }
                                        }
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel(description(day))
                                } else {
                                    Color.clear.frame(width: size, height: size).accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }.padding(.trailing, VD.Space.xl)
        }
    }

    private func metric(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: VD.Space.xs) {
            Text(value.formatted(.number.locale(locale))).font(VD.Font.statValue).monospacedDigit()
            Text(label).font(VD.Font.detail).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func dayDetail(_ activity: UsageActivity) -> some View {
        let day = activity.days.first { $0.date == hoveredDate } ?? activity.days.last!
        return Text(description(day)).font(VD.Font.detail).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func description(_ day: UsageActivity.Day) -> String {
        let date = day.date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale))
        return "\(date) · \(String(format: D("%d entries · %d min recorded"), day.count, Int(day.duration / 60)))"
    }

    private func weekday(_ row: Int) -> String {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar.shortWeekdaySymbols[(Calendar.current.firstWeekday - 1 + row) % 7]
    }

    private func monthLabel(_ week: [UsageActivity.Day?]) -> String {
        // Suppress an initial partial month: its label could collide with the next month's.
        guard let day = week.compactMap({ $0 }).first(where: { Calendar.current.component(.day, from: $0.date) == 1 }) else { return "" }
        return day.date.formatted(.dateTime.month(.abbreviated).locale(locale))
    }

    private var legend: some View {
        HStack(spacing: VD.Space.xs) {
            Text(D("Less"))
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: VD.Radius.activityCell).fill(VD.Palette.activityLevels[level])
                    .frame(width: 11, height: 11)
            }
            Text(D("More"))
        }.font(VD.Font.footnote).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

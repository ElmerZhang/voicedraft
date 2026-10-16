import SwiftUI
import VoiceDraftCore

/// Home's summary: four Total-usage tiles, one Yesterday line (omitted when empty) and a footnote.
/// Personalization stays in Settings → Usage.
struct UsageSummaryView: View {
    let history: [HistoryEntry]
    let vocabulary: AppVocabulary
    let viewMore: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = UsageSummary(history: history, now: context.date, vocabulary: vocabulary)
            VDSurface(padding: VD.Space.l, spacing: 0) {
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
                }.padding(.vertical, -VD.Space.xs).padding(.bottom, 10)
                tiles(summary.metrics)
                if let yesterday = summary.yesterday {
                    yesterdayLine(yesterday.metrics).padding(.top, 14)
                }
                Text(D("Based on history on this Mac.")).font(VD.Font.footnote).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        }
    }

    private func tiles(_ metrics: UsageMetrics) -> some View {
        let format = UsageFormat(locale: locale)
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                tile(Text(format.time(metrics.duration)), title: D("Dictation time"))
                tile(Text(format.words(metrics.words)), title: D("Dictated words"))
            }
            GridRow {
                tile(speed(metrics, format: format), title: D("Average speed"))
                tile(Text(format.time(metrics.estimatedTimeSaved)), title: D("Est. time saved"))
            }
        }
    }

    private func tile(_ value: Text, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value.font(Self.tileValue).lineLimit(1).fixedSize()
            Text(title).font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    /// The number at tile size followed by a smaller "WPM" unit.
    private func speed(_ metrics: UsageMetrics, format: UsageFormat) -> Text {
        guard let value = format.speedNumber(metrics) else { return Text(verbatim: "—") }
        var number = AttributedString(value)
        number.font = Self.tileValue
        var unit = AttributedString(" WPM")
        unit.font = VD.Font.cardTitle
        return Text(number + unit)
    }

    /// "Yesterday · 10m dictated · …" at 12pt secondary with the values in 12pt semibold primary.
    private func yesterdayLine(_ metrics: UsageMetrics) -> some View {
        let format = UsageFormat(locale: locale)
        let values = [format.time(metrics.duration), format.words(metrics.words), format.time(metrics.estimatedTimeSaved)]
        // Format with sentinels, then swap each sentinel for its emphasized value.
        let marker = "\u{1}"
        let template = String(format: D("Yesterday · %1$@ dictated · %2$@ words · %3$@ saved"),
                              marker + "0", marker + "1", marker + "2")
        var line = AttributedString()
        for (index, part) in template.components(separatedBy: marker).enumerated() {
            guard index > 0, let slot = part.first?.wholeNumberValue, values.indices.contains(slot) else {
                line += AttributedString(part); continue
            }
            var value = AttributedString(values[slot])
            value.font = VD.Font.detail.weight(.semibold)
            value.foregroundColor = VD.Palette.ink
            line += value + AttributedString(String(part.dropFirst()))
        }
        return Text(line).font(VD.Font.detail).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let tileValue = SwiftUI.Font.system(size: 26, weight: .semibold).monospacedDigit()
}

/// Shared value formatting for Home's summary and the Settings → Usage card.
private struct UsageFormat {
    let locale: Locale

    func words(_ count: Int) -> String {
        count.formatted(.number.locale(locale).notation(.compactName).precision(.fractionLength(0...1)))
    }

    func speedNumber(_ metrics: UsageMetrics) -> String? {
        metrics.wordsPerMinute.map { $0.formatted(.number.locale(locale).precision(.fractionLength(0))) }
    }

    func time(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.maximumUnitCount = 1
        return formatter.string(from: seconds) ?? "—"
    }
}

/// The same five definitions are used for yesterday, all history and the calendar window.
private struct UsageMetricsView: View {
    let metrics: UsageMetrics
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: VD.Space.l) {
            row("clock", title: D("Dictation time"), value: format.time(metrics.duration),
                help: D("Time in saved voice transcripts. Typed tests and empty transcripts are excluded."))
            row("mic", title: D("Dictated words"), value: format.words(metrics.words),
                help: D("Counts the original transcript, not generated answers. Chinese and Japanese characters count individually; other languages count words."))
            row("bolt", title: D("Average speed"),
                value: format.speedNumber(metrics).map { "\($0) WPM" } ?? "—",
                help: D("Total dictated words divided by total dictation minutes. No recording means no speed estimate."))
            row("hourglass", title: D("Est. time saved"), value: format.time(metrics.estimatedTimeSaved),
                help: D("Estimated against typing 45 words per minute, minus dictation time. Processing and editing time are not measured."))
            row("signature", title: D("Personalization"),
                value: metrics.personalization.map { $0.formatted(.percent.locale(locale).precision(.fractionLength(1))) } ?? "—",
                help: D("Share of dictated words matching your currently enabled vocabulary, including aliases. Overlapping matches count once. This is vocabulary coverage, not recognition accuracy; changing vocabulary updates past statistics."))
        }
    }

    private func row(_ icon: String, title: String, value: String, help: String) -> some View {
        HStack(spacing: VD.Space.m) {
            Image(systemName: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                .frame(width: 24).accessibilityHidden(true)
            Text(title).font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: VD.Space.s)
            Text(value).font(VD.Font.statValue).monospacedDigit().fixedSize()
        }.help(help).accessibilityElement(children: .combine).accessibilityHint(help)
    }

    private var format: UsageFormat { UsageFormat(locale: locale) }
}

struct UsageActivityView: View {
    let history: [HistoryEntry]
    let vocabulary: AppVocabulary
    let keepHistory: Bool

    var body: some View {
        // Refresh the date window even when Usage stays open overnight.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let activity = UsageActivity(history: history, now: context.date, vocabulary: vocabulary)
            VDSurface(spacing: VD.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text(D("Usage activity")).font(VD.Font.sectionTitle)
                    Spacer()
                    Text(D("Last 365 days")).font(VD.Font.detail).foregroundStyle(.secondary)
                }
                UsageMetricsView(metrics: activity.metrics)
                HStack(spacing: VD.Space.l) {
                    Text("\(activity.totalCount) \(D("saved entries"))")
                    Text("\(activity.activeDays) \(D("active days"))")
                }.font(VD.Font.footnote).foregroundStyle(.secondary)
                UsageCalendarView(activity: activity)
                Divider()
                DisclosureGroup(D("How these are calculated")) {
                    VStack(alignment: .leading, spacing: VD.Space.s) {
                        Text(D("Time in saved voice transcripts. Typed tests and empty transcripts are excluded."))
                        Text(D("Counts the original transcript, not generated answers. Chinese and Japanese characters count individually; other languages count words."))
                        Text(D("Total dictated words divided by total dictation minutes. No recording means no speed estimate."))
                        Text(D("Estimated against typing 45 words per minute, minus dictation time. Processing and editing time are not measured."))
                        Text(D("Share of dictated words matching your currently enabled vocabulary, including aliases. Overlapping matches count once. This is vocabulary coverage, not recognition accuracy; changing vocabulary updates past statistics."))
                        Text(D("Statistics use retained voice history. Reprocessed recordings count again; deleted or expired records are excluded."))
                    }.padding(.top, VD.Space.s).fixedSize(horizontal: false, vertical: true)
                }.font(VD.Font.footnote).foregroundStyle(.secondary)
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
}

/// Hover updates stay in this subtree, without recounting all history and vocabulary.
private struct UsageCalendarView: View {
    let activity: UsageActivity
    @State private var hoveredDate: Date?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            GeometryReader { geometry in
                let size = max(9, min(16, (geometry.size.width - 60) / CGFloat(activity.weeks.count) - 4))
                calendarGrid(activity, size: size)
            }.frame(height: 164)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VD.Space.m) { dayDetail(activity); Spacer(); legend }
                VStack(alignment: .leading, spacing: VD.Space.s) { dayDetail(activity); legend }
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

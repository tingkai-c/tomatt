import SwiftUI

private enum TBStatsDisplayMode: String, CaseIterable, Hashable {
    case day
    case week
}

struct TBStatsWindowView: View {
    @ObservedObject var store: TBStatsStore
    @State private var mode: TBStatsDisplayMode = .day
    @State private var selectedDate = Date()

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                if mode == .day {
                    dayContent
                } else {
                    weekContent
                }
            }
        }
        .frame(width: 980, height: 680)
        .background(
            ZStack {
                TBVisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                TBDesignTokens.ColorToken.glassOverlay
            }
            .ignoresSafeArea()
        )
        .onAppear {
            store.reload()
        }
    }

    private var header: some View {
        VStack(spacing: 20) {
            modePicker

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    Text(NSLocalizedString("StatsView.subtitle.label", comment: "Stats subtitle"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TBDesignTokens.ColorToken.subduedText)
                }
                Spacer()
                navigationControls
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text(NSLocalizedString("StatsView.day.label", comment: "Day stats mode")).tag(TBStatsDisplayMode.day)
            Text(NSLocalizedString("StatsView.week.label", comment: "Week stats mode")).tag(TBStatsDisplayMode.week)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 230)
    }

    private var navigationControls: some View {
        HStack(spacing: 8) {
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48)
            }
            Button {
                selectedDate = Date()
            } label: {
                Text(NSLocalizedString("StatsView.today.label", comment: "Today navigation button"))
                    .font(.headline)
                    .frame(width: 104)
            }
            Button {
                moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48)
            }
        }
        .controlSize(.large)
    }

    private var dayContent: some View {
        let summary = store.summary(forDay: selectedDate, calendar: calendar)
        return VStack(spacing: 18) {
            MetricRow(summary: summary)

            FocusBreakdownCard(summary: summary)

            TBStatsSectionCard(title: NSLocalizedString("StatsView.timeline.label", comment: "Timeline section"),
                               subtitle: NSLocalizedString("StatsView.timeline.help", comment: "Timeline help")) {
                TBStatsDayTimeline(records: summary.records)
                    .frame(height: 84)
            }

            TBStatsSessionList(records: summary.records)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    private var weekContent: some View {
        let days = weekDays(containing: selectedDate)
        let summary = store.summary(forWeekContaining: selectedDate, calendar: calendar)
        return VStack(spacing: 18) {
            MetricRow(summary: summary)
            FocusBreakdownCard(summary: summary)

            TBStatsSectionCard(title: NSLocalizedString("StatsView.weekSummary.label", comment: "Week summary"),
                               subtitle: NSLocalizedString("StatsView.weekSummary.help", comment: "Week summary help")) {
                TBStatsWeekColumns(store: store, days: days)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    private var title: String {
        switch mode {
        case .day:
            return TBStatsFormatters.dayTitle.string(from: selectedDate)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
            return String(format: NSLocalizedString("StatsView.weekOf.label", comment: "Week of date title"),
                          TBStatsFormatters.weekTitle.string(from: start))
        }
    }

    private func moveSelection(by value: Int) {
        let component: Calendar.Component = mode == .day ? .day : .weekOfYear
        selectedDate = calendar.date(byAdding: component, value: value, to: selectedDate) ?? selectedDate
    }

    private func weekDays(containing date: Date) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }
}

private struct MetricRow: View {
    let summary: TBStatsSummary

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricCard(value: "\(summary.sessions)",
                       title: NSLocalizedString("StatsView.sessions.label", comment: "Sessions label"),
                       accent: TBStatsColors.workColor)
            MetricCard(value: formatDuration(summary.focusTime),
                       title: NSLocalizedString("StatsView.focusTime.label", comment: "Focus time label"),
                       accent: .primary,
                       isProminent: true)
            MetricCard(value: formatDuration(summary.overtimeFocusTime),
                       title: NSLocalizedString("StatsView.overtime.label", comment: "Overtime label"),
                       accent: TBStatsColors.overtimeColor)
            MetricCard(value: formatDuration(summary.breakTime),
                       title: NSLocalizedString("StatsView.breakTime.label", comment: "Break time label"),
                       accent: TBStatsColors.breakColor)
        }
    }
}

private struct MetricCard: View {
    let value: String
    let title: String
    let accent: Color
    var isProminent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: isProminent ? 42 : 36, weight: .semibold, design: .rounded))
                .foregroundColor(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TBDesignTokens.ColorToken.subduedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(TBDesignTokens.ColorToken.glassFill)
        .clipShape(RoundedRectangle(cornerRadius: TBDesignTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TBDesignTokens.Radius.card, style: .continuous)
                .strokeBorder(TBDesignTokens.ColorToken.hairline, lineWidth: 0.75)
        )
    }
}

private struct FocusBreakdownCard: View {
    let summary: TBStatsSummary

    var body: some View {
        TBStatsSectionCard(title: NSLocalizedString("StatsView.focusBreakdown.label", comment: "Focus breakdown"),
                           subtitle: NSLocalizedString("StatsView.focusBreakdown.help", comment: "Focus breakdown help")) {
            HStack(spacing: 12) {
                BreakdownPill(title: NSLocalizedString("StatsView.completedFocus.label", comment: "Completed focus"),
                              value: formatDuration(summary.completedFocusTime),
                              color: TBStatsColors.workColor)
                BreakdownPill(title: NSLocalizedString("StatsView.partialFocus.label", comment: "Partial focus"),
                              value: formatDuration(summary.partialFocusTime),
                              color: TBStatsColors.partialColor)
                BreakdownPill(title: NSLocalizedString("StatsView.overtimeFocus.label", comment: "Overtime focus"),
                              value: formatDuration(summary.overtimeFocusTime),
                              color: TBStatsColors.overtimeColor)
            }
        }
    }
}

private struct BreakdownPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(TBDesignTokens.ColorToken.subduedText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TBDesignTokens.ColorToken.glassFill.opacity(0.72))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(TBDesignTokens.ColorToken.hairline, lineWidth: 0.75))
    }
}

private struct TBStatsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String,
         subtitle: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(TBDesignTokens.ColorToken.subduedText)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(TBDesignTokens.ColorToken.glassFill)
        .clipShape(RoundedRectangle(cornerRadius: TBDesignTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TBDesignTokens.Radius.card, style: .continuous)
                .strokeBorder(TBDesignTokens.ColorToken.hairline, lineWidth: 0.75)
        )
    }
}

private struct TBStatsDayTimeline: View {
    let records: [TBSessionRecord]

    var body: some View {
        VStack(spacing: 10) {
            if records.isEmpty {
                emptyTimeline
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                            .frame(height: 14)
                        ForEach(records) { record in
                            wallSegment(for: record, width: proxy.size.width)
                            activeSegment(for: record, width: proxy.size.width)
                            overtimeSegment(for: record, width: proxy.size.width)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 28)
            }
            HStack {
                Text(startLabel)
                Spacer()
                Text(endLabel)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(TBDesignTokens.ColorToken.subduedText)
        }
    }

    private var emptyTimeline: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.14))
            .frame(height: 14)
            .overlay(
                Text(NSLocalizedString("StatsView.noTimeline.label", comment: "No timeline data"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(TBDesignTokens.ColorToken.subduedText)
            )
    }

    private var bounds: DateInterval? {
        guard let first = records.map(\.startedAt).min(), let last = records.map(\.endedAt).max() else {
            return nil
        }
        return DateInterval(start: first, end: max(last, first.addingTimeInterval(60)))
    }

    private var startLabel: String {
        guard let start = bounds?.start else { return "--" }
        return TBStatsFormatters.time.string(from: start)
    }

    private var endLabel: String {
        guard let end = bounds?.end else { return "--" }
        return TBStatsFormatters.time.string(from: end)
    }

    private func wallSegment(for record: TBSessionRecord, width: CGFloat) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(record.pausedDuration > 0 ? 0.18 : 0.08))
            .frame(width: segmentWidth(duration: record.endedAt.timeIntervalSince(record.startedAt), in: width), height: 14)
            .offset(x: segmentOffset(record.startedAt, in: width))
    }

    private func activeSegment(for record: TBSessionRecord, width: CGFloat) -> some View {
        Capsule()
            .fill(color(for: record))
            .frame(width: segmentWidth(duration: activeVisibleDuration(for: record), in: width), height: 14)
            .offset(x: segmentOffset(activeStart(for: record), in: width))
    }

    private func overtimeSegment(for record: TBSessionRecord, width: CGFloat) -> some View {
        Capsule()
            .fill(TBStatsColors.overtimeColor)
            .frame(width: segmentWidth(duration: record.overtimeFocusDuration, in: width), height: 14)
            .offset(x: segmentOffset(activeStart(for: record).addingTimeInterval(record.plannedFocusDuration), in: width))
            .opacity(record.overtimeFocusDuration > 0 ? 1 : 0)
    }

    private func activeStart(for record: TBSessionRecord) -> Date {
        // Records only store aggregate paused time, not each pause segment. Placing the
        // muted pause span before the active span keeps the timeline honest about total
        // work length without pretending pause time was ordinary focus.
        record.startedAt.addingTimeInterval(record.pausedDuration)
    }

    private func segmentOffset(_ date: Date, in width: CGFloat) -> CGFloat {
        guard let bounds = bounds, bounds.duration > 0 else { return 0 }
        return width * CGFloat(date.timeIntervalSince(bounds.start) / bounds.duration)
    }

    private func segmentWidth(duration: TimeInterval, in width: CGFloat) -> CGFloat {
        guard let bounds = bounds, bounds.duration > 0, duration > 0 else { return 0 }
        let value = width * CGFloat(duration / bounds.duration)
        return max(2, value)
    }

    private func activeVisibleDuration(for record: TBSessionRecord) -> TimeInterval {
        if record.kind == .work {
            return max(0, record.focusDuration - record.overtimeFocusDuration)
        }
        return record.activeDuration
    }

    private func color(for record: TBSessionRecord) -> Color {
        if record.kind.isBreak {
            return TBStatsColors.breakColor
        }
        return record.completion == .completed ? TBStatsColors.workColor : TBStatsColors.partialColor
    }
}

private struct TBStatsSessionList: View {
    let records: [TBSessionRecord]

    private var visibleRecords: [TBSessionRecord] {
        records.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        TBStatsSectionCard(title: NSLocalizedString("StatsView.sessionsList.label", comment: "Session list"),
                           subtitle: NSLocalizedString("StatsView.sessionsList.help", comment: "Session list help")) {
            if visibleRecords.isEmpty {
                Text(NSLocalizedString("StatsView.noSessions.label", comment: "No sessions"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TBDesignTokens.ColorToken.subduedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(visibleRecords.prefix(8)) { record in
                        SessionRow(record: record)
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let record: TBSessionRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(timeRange)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TBDesignTokens.ColorToken.subduedText)
            }
            Spacer()
            Text(durationSummary)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(TBDesignTokens.ColorToken.glassFill.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: TBDesignTokens.Radius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TBDesignTokens.Radius.button, style: .continuous)
                .strokeBorder(TBDesignTokens.ColorToken.hairline, lineWidth: 0.6)
        )
    }

    private var title: String {
        let kind: String
        if record.kind == .work {
            kind = NSLocalizedString("StatsView.work.label", comment: "Work label")
        } else {
            kind = NSLocalizedString("StatsView.break.label", comment: "Break label")
        }
        return "\(kind) · \(completionLabel)"
    }

    private var completionLabel: String {
        switch record.completion {
        case .completed:
            return NSLocalizedString("StatsView.completed.label", comment: "Completed label")
        case .skipped:
            return NSLocalizedString("StatsView.skipped.label", comment: "Skipped label")
        case .stopped:
            return NSLocalizedString("StatsView.stopped.label", comment: "Stopped label")
        case .abandoned:
            return NSLocalizedString("StatsView.abandoned.label", comment: "Abandoned label")
        }
    }

    private var timeRange: String {
        "\(TBStatsFormatters.time.string(from: record.startedAt)) – \(TBStatsFormatters.time.string(from: record.endedAt))"
    }

    private var durationSummary: String {
        if record.kind == .work, record.overtimeFocusDuration > 0 {
            return String(format: NSLocalizedString("StatsView.durationWithOvertime.format", comment: "Duration plus overtime"),
                          formatDuration(record.focusDuration),
                          formatDuration(record.overtimeFocusDuration))
        }
        if record.pausedDuration > 0 {
            return String(format: NSLocalizedString("StatsView.durationWithPaused.format", comment: "Duration minus paused"),
                          formatDuration(record.activeDuration),
                          formatDuration(record.pausedDuration))
        }
        return formatDuration(record.activeDuration)
    }

    private var color: Color {
        if record.kind.isBreak {
            return TBStatsColors.breakColor
        }
        return record.completion == .completed ? TBStatsColors.workColor : TBStatsColors.partialColor
    }
}

private struct TBStatsWeekColumns: View {
    @ObservedObject var store: TBStatsStore
    let days: [Date]

    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    weekNumbers(for: day)
                    Text(TBStatsFormatters.weekday.string(from: day))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    if calendar.isDateInToday(day) {
                        Circle()
                            .fill(Color.primary.opacity(0.85))
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 210)
                if index < days.count - 1 {
                    Divider().frame(height: 180)
                }
            }
        }
    }

    private func weekNumbers(for day: Date) -> some View {
        let summary = store.summary(forDay: day, calendar: calendar)
        return VStack(spacing: 6) {
            if summary.focusTime > 0 {
                Text(formatDuration(summary.focusTime))
                    .foregroundColor(TBStatsColors.workColor)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            if summary.overtimeFocusTime > 0 {
                Text("+\(formatDuration(summary.overtimeFocusTime))")
                    .foregroundColor(TBStatsColors.overtimeColor)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            if summary.breaks > 0 {
                Text("\(summary.breaks) \(NSLocalizedString("StatsView.breaks.label", comment: "Breaks label"))")
                    .foregroundColor(TBStatsColors.breakColor)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(height: 110, alignment: .bottom)
    }
}

private enum TBStatsColors {
    static let workColor = Color.pink
    static let breakColor = Color(red: 0.48, green: 0.44, blue: 1.0)
    static let partialColor = Color.orange
    static let overtimeColor = Color.green
}

private enum TBStatsFormatters {
    static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()

    static let weekTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = max(0, Int((duration / 60).rounded()))
    if totalMinutes < 60 {
        return String(format: NSLocalizedString("StatsView.minutes.format", comment: "Minutes duration"), totalMinutes)
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if minutes == 0 {
        return String(format: NSLocalizedString("StatsView.hours.format", comment: "Hours duration"), hours)
    }
    return String(format: NSLocalizedString("StatsView.hoursMinutes.format", comment: "Hours and minutes duration"), hours, minutes)
}

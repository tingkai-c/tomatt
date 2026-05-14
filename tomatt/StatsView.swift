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
            modePicker
                .padding(.top, 16)

            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                navigationControls
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            if mode == .day {
                dayContent
            } else {
                weekContent
            }
        }
        .frame(width: 920, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            store.reload()
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text(NSLocalizedString("StatsView.day.label", comment: "Day stats mode")).tag(TBStatsDisplayMode.day)
            Text(NSLocalizedString("StatsView.week.label", comment: "Week stats mode")).tag(TBStatsDisplayMode.week)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 210)
    }

    private var navigationControls: some View {
        HStack(spacing: 0) {
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .frame(width: 54)
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
                    .font(.title2.weight(.semibold))
                    .frame(width: 54)
            }
        }
        .controlSize(.large)
    }

    private var dayContent: some View {
        let summary = store.summary(forDay: selectedDate, calendar: calendar)
        return VStack(spacing: 44) {
            MetricRow(summary: summary)
                .padding(.horizontal, 40)
                .padding(.top, 76)

            TBStatsDayTimeline(records: summary.records)
                .frame(height: 72)
                .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
    }

    private var weekContent: some View {
        let days = weekDays(containing: selectedDate)
        let summary = store.summary(forWeekContaining: selectedDate, calendar: calendar)
        return VStack(spacing: 28) {
            MetricRow(summary: summary)
                .padding(.horizontal, 40)
                .padding(.top, 36)

            TBStatsWeekColumns(store: store, days: days)
                .padding(.horizontal, 56)
                .padding(.top, 8)

            Text(String(format: NSLocalizedString("StatsView.totalSessionTime.label", comment: "Total session time"),
                        formatDuration(summary.sessionTime)))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
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
        HStack(spacing: 0) {
            MetricCell(value: "\(summary.sessions)",
                       title: NSLocalizedString("StatsView.sessions.label", comment: "Sessions label"),
                       color: .pink)
            Divider().frame(height: 96)
            MetricCell(value: "\(summary.breaks)",
                       title: NSLocalizedString("StatsView.breaks.label", comment: "Breaks label"),
                       color: .indigo)
            Divider().frame(height: 96)
            MetricCell(value: formatDuration(summary.sessionTime),
                       title: NSLocalizedString("StatsView.sessionTime.label", comment: "Session time label"),
                       color: .primary)
            Divider().frame(height: 96)
            MetricCell(value: formatDuration(summary.breakTime),
                       title: NSLocalizedString("StatsView.breakTime.label", comment: "Break time label"),
                       color: .primary)
        }
    }
}

private struct MetricCell: View {
    let value: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(value)
                .font(.system(size: 54, weight: .regular, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TBStatsDayTimeline: View {
    let records: [TBSessionRecord]

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 12)
                    ForEach(records) { record in
                        Capsule()
                            .fill(color(for: record.kind))
                            .frame(width: segmentWidth(record, in: proxy.size.width), height: 12)
                            .offset(x: segmentOffset(record, in: proxy.size.width))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            HStack {
                Text(startLabel)
                Spacer()
                Text(endLabel)
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.secondary)
            .monospacedDigit()
        }
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

    private func segmentOffset(_ record: TBSessionRecord, in width: CGFloat) -> CGFloat {
        guard let bounds = bounds, bounds.duration > 0 else { return 0 }
        return width * CGFloat(record.startedAt.timeIntervalSince(bounds.start) / bounds.duration)
    }

    private func segmentWidth(_ record: TBSessionRecord, in width: CGFloat) -> CGFloat {
        guard let bounds = bounds, bounds.duration > 0 else { return 0 }
        let value = width * CGFloat(record.endedAt.timeIntervalSince(record.startedAt) / bounds.duration)
        return max(2, value)
    }

    private func color(for kind: TBStatsIntervalKind) -> Color {
        kind == .work ? .pink : .indigo
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
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.primary)
                    if calendar.isDateInToday(day) {
                        Circle()
                            .fill(Color.primary.opacity(0.85))
                            .frame(width: 12, height: 12)
                    } else {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 12, height: 12)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 230)
                if index < days.count - 1 {
                    Divider().frame(height: 200)
                }
            }
        }
    }

    private func weekNumbers(for day: Date) -> some View {
        let summary = store.summary(forDay: day, calendar: calendar)
        return VStack(spacing: 8) {
            if summary.sessions > 0 {
                Text("\(summary.sessions)")
                    .foregroundColor(.pink)
            }
            if summary.breaks > 0 {
                Text("\(summary.breaks)")
                    .foregroundColor(.indigo)
            }
        }
        .font(.system(size: 40, weight: .regular, design: .rounded))
        .monospacedDigit()
        .frame(height: 100, alignment: .bottom)
    }
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

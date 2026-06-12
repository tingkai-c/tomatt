import Foundation
import Combine

// Durable stats records are product data, separate from diagnostic TBLogger cache logs.
struct TBSessionRecord: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    let id: UUID
    let kind: TBStatsIntervalKind
    let startedAt: Date
    let endedAt: Date
    let plannedDuration: TimeInterval
    let activeDuration: TimeInterval
    let pausedDuration: TimeInterval
    let completion: TBStatsCompletion
    let preset: TimerPresetSnapshot
    let workIntervalIndex: Int
    let timezoneIdentifier: String
    let calendarIdentifier: String
    var overtimeDuration: TimeInterval? = nil

    var focusDuration: TimeInterval {
        kind == .work ? activeDuration : 0
    }

    var plannedFocusDuration: TimeInterval {
        guard kind == .work else { return 0 }
        return min(activeDuration, plannedDuration)
    }

    var overtimeFocusDuration: TimeInterval {
        guard kind == .work else { return 0 }
        return max(0, overtimeDuration ?? (activeDuration - plannedDuration))
    }

    var isCompletedWork: Bool {
        kind == .work && completion == .completed
    }

    var isPartialWork: Bool {
        kind == .work && completion != .completed
    }
}

struct TBStatsSummary {
    let records: [TBSessionRecord]

    var sessions: Int {
        records.filter { $0.kind == .work && $0.completion == .completed }.count
    }

    var breaks: Int {
        records.filter { $0.kind.isBreak && $0.completion == .completed }.count
    }

    var sessionTime: TimeInterval {
        focusTime
    }

    var focusTime: TimeInterval {
        records.filter { $0.kind == .work }.reduce(0) { $0 + $1.focusDuration }
    }

    var completedFocusTime: TimeInterval {
        records.filter { $0.isCompletedWork }.reduce(0) { $0 + $1.focusDuration }
    }

    var partialFocusTime: TimeInterval {
        records.filter { $0.isPartialWork }.reduce(0) { $0 + $1.focusDuration }
    }

    var overtimeFocusTime: TimeInterval {
        records.filter { $0.kind == .work }.reduce(0) { $0 + $1.overtimeFocusDuration }
    }

    var breakTime: TimeInterval {
        records.filter { $0.kind.isBreak }.reduce(0) { $0 + $1.activeDuration }
    }
}

final class TBStatsStore: ObservableObject {
    static let shared = TBStatsStore()

    @Published private(set) var records: [TBSessionRecord]

    private let eventStore: TBJSONLEventStore

    init(fileURL: URL? = nil) {
        eventStore = TBJSONLEventStore(fileURL: fileURL ?? TBStatsStore.defaultFileURL())
        records = []
        records = loadRecords()
    }

    func append(_ record: TBSessionRecord) {
        do {
            let existingEnvelopes = (try? eventStore.load()) ?? []
            let sequence = (existingEnvelopes.map(\.sequence).max() ?? 0) + 1
            let envelope = TBEventEnvelope(streamID: "local",
                                           sequence: sequence,
                                           event: .statsRecordAppended(TBStatsRecordAppended(record: record)))
            try eventStore.append(envelope)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.records = self.loadRecords()
            }
        } catch {
            print("cannot write stats record: \(error)")
        }
    }

    func reload() {
        records = loadRecords()
    }

    func summary(forDay date: Date, calendar: Calendar = .current) -> TBStatsSummary {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            return TBStatsSummary(records: [])
        }
        return TBStatsSummary(records: records(in: dayInterval))
    }

    func summary(forWeekContaining date: Date, calendar: Calendar = .current) -> TBStatsSummary {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return TBStatsSummary(records: [])
        }
        return TBStatsSummary(records: records(in: weekInterval))
    }

    func records(onDay date: Date, calendar: Calendar = .current) -> [TBSessionRecord] {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else { return [] }
        return records(in: dayInterval)
    }

    private func records(in interval: DateInterval) -> [TBSessionRecord] {
        records
            .filter { interval.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func loadRecords() -> [TBSessionRecord] {
        guard let envelopes = try? eventStore.load() else { return [] }
        return TBEventProjector.project(envelopes).stats.sorted { $0.startedAt < $1.startedAt }
    }

    private static func defaultFileURL() -> URL {
        TBJSONLEventStore.defaultFileURL()
    }
}

struct TBActiveStatsInterval {
    let id: UUID
    let kind: TBStatsIntervalKind
    let startedAt: Date
    let plannedDuration: TimeInterval
    let preset: TimerPresetSnapshot
    let workIntervalIndex: Int
    var pausedDuration: TimeInterval = 0
    var pauseStartedAt: Date?

    mutating func pause(at date: Date) {
        guard pauseStartedAt == nil else { return }
        pauseStartedAt = date
    }

    mutating func resume(at date: Date) {
        guard let pauseStartedAt = pauseStartedAt else { return }
        pausedDuration += max(0, date.timeIntervalSince(pauseStartedAt))
        self.pauseStartedAt = nil
    }

    mutating func record(completion: TBStatsCompletion,
                         at endedAt: Date,
                         includeOvertime: Bool = false) -> TBSessionRecord {
        resume(at: endedAt)
        let wallDuration = max(0, endedAt.timeIntervalSince(startedAt))
        let uncappedActiveDuration = max(0, wallDuration - pausedDuration)
        let overtimeDuration = kind == .work && includeOvertime ? max(0, uncappedActiveDuration - plannedDuration) : 0
        let activeDuration = min(plannedDuration, uncappedActiveDuration) + overtimeDuration
        return TBSessionRecord(id: id,
                               kind: kind,
                               startedAt: startedAt,
                               endedAt: endedAt,
                               plannedDuration: plannedDuration,
                               activeDuration: activeDuration,
                               pausedDuration: pausedDuration,
                               completion: completion,
                               preset: preset,
                               workIntervalIndex: workIntervalIndex,
                               timezoneIdentifier: TimeZone.current.identifier,
                               calendarIdentifier: Calendar.current.identifier.debugDescription,
                               overtimeDuration: overtimeDuration)
    }
}

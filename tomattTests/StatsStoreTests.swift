import XCTest

final class StatsStoreTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testStatsStoreAppendReloadAndSummaries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("records.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TBStatsStore(fileURL: fileURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let work = record(kind: .work,
                          startedAt: base,
                          endedAt: base.addingTimeInterval(1_500),
                          activeDuration: 1_500,
                          completion: .completed)
        let breakRecord = record(kind: .shortRest,
                                 startedAt: base.addingTimeInterval(1_600),
                                 endedAt: base.addingTimeInterval(1_900),
                                 activeDuration: 300,
                                 completion: .completed)
        let skippedWork = record(kind: .work,
                                 startedAt: base.addingTimeInterval(2_000),
                                 endedAt: base.addingTimeInterval(2_100),
                                 activeDuration: 100,
                                 completion: .skipped)

        store.append(work)
        store.append(breakRecord)
        store.append(skippedWork)
        try "not json\n".data(using: .utf8)!.append(to: fileURL)

        let reloaded = TBStatsStore(fileURL: fileURL)
        let day = reloaded.summary(forDay: base, calendar: calendar)
        XCTAssertEqual(day.records.count, 3)
        XCTAssertEqual(day.sessions, 1)
        XCTAssertEqual(day.breaks, 1)
        XCTAssertEqual(day.sessionTime, 1_600)
        XCTAssertEqual(day.breakTime, 300)

        let week = reloaded.summary(forWeekContaining: base, calendar: calendar)
        XCTAssertEqual(week.records.count, 3)
    }

    func testActiveStatsIntervalTracksPausedAndCapsActiveDuration() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var interval = TBActiveStatsInterval(id: UUID(),
                                             kind: .work,
                                             startedAt: startedAt,
                                             plannedDuration: 60,
                                             preset: TimerPresetSnapshot(preset: TimerPreset()),
                                             workIntervalIndex: 1)
        interval.pause(at: startedAt.addingTimeInterval(10))
        interval.resume(at: startedAt.addingTimeInterval(25))
        interval.pause(at: startedAt.addingTimeInterval(40))

        let record = interval.record(completion: .completed,
                                     at: startedAt.addingTimeInterval(120))
        XCTAssertEqual(record.pausedDuration, 95)
        XCTAssertEqual(record.activeDuration, 25)
        XCTAssertEqual(record.completion, .completed)
    }

    private func record(kind: TBStatsIntervalKind,
                        startedAt: Date,
                        endedAt: Date,
                        activeDuration: TimeInterval,
                        completion: TBStatsCompletion) -> TBSessionRecord {
        TBSessionRecord(id: UUID(),
                        kind: kind,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        plannedDuration: activeDuration,
                        activeDuration: activeDuration,
                        pausedDuration: 0,
                        completion: completion,
                        preset: TimerPresetSnapshot(preset: TimerPreset()),
                        workIntervalIndex: 1,
                        timezoneIdentifier: "UTC",
                        calendarIdentifier: "gregorian")
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

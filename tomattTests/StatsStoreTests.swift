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
        let fileURL = directory.appendingPathComponent("events.jsonl")
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

        let rawEvents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(rawEvents.contains("statsRecordAppended"))
        XCTAssertFalse(rawEvents.split(separator: "\n").contains { line in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(TBSessionRecord.self, from: Data(String(line).utf8))) != nil
        })

        let reloaded = TBStatsStore(fileURL: fileURL)
        let day = reloaded.summary(forDay: base, calendar: calendar)
        XCTAssertEqual(day.records.count, 3)
        XCTAssertEqual(day.sessions, 1)
        XCTAssertEqual(day.breaks, 1)
        XCTAssertEqual(day.sessionTime, 1_600)
        XCTAssertEqual(day.focusTime, 1_600)
        XCTAssertEqual(day.completedFocusTime, 1_500)
        XCTAssertEqual(day.partialFocusTime, 100)
        XCTAssertEqual(day.overtimeFocusTime, 0)
        XCTAssertEqual(day.breakTime, 300)

        let week = reloaded.summary(forWeekContaining: base, calendar: calendar)
        XCTAssertEqual(week.records.count, 3)
    }

    func testStatsStoreIgnoresLegacySessionRecordsFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let eventURL = directory.appendingPathComponent("events.jsonl")
        let legacyURL = directory.appendingPathComponent("session-records.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = record(kind: .work,
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            endedAt: Date(timeIntervalSince1970: 1_700_001_500),
                            activeDuration: 1_500,
                            completion: .completed)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try (encoder.encode(legacy) + Data([0x0A])).write(to: legacyURL)

        let store = TBStatsStore(fileURL: eventURL)

        XCTAssertEqual(store.records, [])
    }

    func testActiveStatsIntervalTracksPausedAndExcludesPausedDuration() {
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

    func testActiveStatsIntervalIncludesExtendedWorkAsOvertime() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        var interval = TBActiveStatsInterval(id: UUID(),
                                             kind: .work,
                                             startedAt: startedAt,
                                             plannedDuration: 60,
                                             preset: TimerPresetSnapshot(preset: TimerPreset()),
                                             workIntervalIndex: 1)
        interval.pause(at: startedAt.addingTimeInterval(30))
        interval.resume(at: startedAt.addingTimeInterval(45))

        let record = interval.record(completion: .completed,
                                     at: startedAt.addingTimeInterval(100),
                                     includeOvertime: true)
        XCTAssertEqual(record.pausedDuration, 15)
        XCTAssertEqual(record.activeDuration, 85)
        XCTAssertEqual(record.overtimeFocusDuration, 25)
        XCTAssertEqual(record.plannedFocusDuration, 60)
    }

    func testLateWorkCompletionWithoutExtensionStaysCapped() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        var interval = TBActiveStatsInterval(id: UUID(),
                                             kind: .work,
                                             startedAt: startedAt,
                                             plannedDuration: 60,
                                             preset: TimerPresetSnapshot(preset: TimerPreset()),
                                             workIntervalIndex: 1)

        let record = interval.record(completion: .completed,
                                     at: startedAt.addingTimeInterval(100))
        XCTAssertEqual(record.activeDuration, 60)
        XCTAssertEqual(record.overtimeFocusDuration, 0)
    }

    func testLegacyRecordsWithoutOvertimeStillDecode() throws {
        let json = """
        {"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","kind":"work","startedAt":"2024-01-01T00:00:00Z","endedAt":"2024-01-01T00:25:00Z","plannedDuration":1500,"activeDuration":1500,"pausedDuration":0,"completion":"completed","preset":{"workIntervalLength":25,"shortRestIntervalLength":5,"longRestIntervalLength":15,"workIntervalsInSet":4},"workIntervalIndex":1,"timezoneIdentifier":"UTC","calendarIdentifier":"gregorian"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(TBSessionRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.overtimeDuration)
        XCTAssertEqual(record.overtimeFocusDuration, 0)
        XCTAssertEqual(record.focusDuration, 1_500)
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

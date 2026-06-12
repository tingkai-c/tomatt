import XCTest

final class EventCoreTests: XCTestCase {
    func testEmptyReplayDefaults() {
        let state = TBEventProjector.project([])

        XCTAssertEqual(state.settings, TBSettingsProjection())
        XCTAssertEqual(state.presets, [])
        XCTAssertEqual(state.stats, [])
        XCTAssertNil(state.timer)
        XCTAssertNil(state.activeTimerSession)
    }

    func testSettingsAndPresetReplay() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let preset = NamedTimerPreset(id: presetID,
                                      name: "Deep Work",
                                      preset: TimerPreset(workIntervalLength: 50,
                                                          shortRestIntervalLength: 10,
                                                          longRestIntervalLength: 20,
                                                          workIntervalsInSet: 3))

        let state = TBEventProjector.project([
            envelope(sequence: 2, event: .settingChanged(TBSettingChanged(key: .pauseAfterRestFinish,
                                                                          value: .bool(true)))),
            envelope(sequence: 1, event: .settingChanged(TBSettingChanged(key: .workDurationMinutes,
                                                                          value: .int(45)))),
            envelope(sequence: 3, event: .presetUpserted(TBPresetUpserted(preset: preset))),
            envelope(sequence: 4, event: .settingChanged(TBSettingChanged(key: .workIntervalsPerSet,
                                                                          value: .int(5))))
        ])

        XCTAssertEqual(state.settings.preset.workIntervalLength, 45)
        XCTAssertEqual(state.settings.preset.workIntervalsInSet, 5)
        XCTAssertTrue(state.settings.pauseAfterRestFinish)
        XCTAssertEqual(state.presets, [preset])
    }

    func testPresetSelectionAndOrderReplay() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let first = NamedTimerPreset(id: firstID, name: "First", preset: TimerPreset())
        let second = NamedTimerPreset(id: secondID, name: "Second", preset: TimerPreset())
        let third = NamedTimerPreset(id: thirdID, name: "Third", preset: TimerPreset())

        let state = TBEventProjector.project([
            envelope(sequence: 1, event: .presetUpserted(TBPresetUpserted(preset: first))),
            envelope(sequence: 2, event: .presetUpserted(TBPresetUpserted(preset: second))),
            envelope(sequence: 3, event: .presetUpserted(TBPresetUpserted(preset: third))),
            envelope(sequence: 4, event: .presetSelected(TBPresetSelected(presetID: secondID))),
            envelope(sequence: 5, event: .presetOrderChanged(TBPresetOrderChanged(presetIDs: [thirdID, firstID, secondID])))
        ])

        XCTAssertEqual(state.presets.map(\.id), [thirdID, firstID, secondID])
        XCTAssertEqual(state.selectedPresetID, secondID)
    }

    func testDeletingSelectedPresetFallsBackToFirstRemainingPreset() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        let first = NamedTimerPreset(id: firstID, name: "First", preset: TimerPreset())
        let second = NamedTimerPreset(id: secondID, name: "Second", preset: TimerPreset())

        let state = TBEventProjector.project([
            envelope(sequence: 1, event: .presetUpserted(TBPresetUpserted(preset: first))),
            envelope(sequence: 2, event: .presetUpserted(TBPresetUpserted(preset: second))),
            envelope(sequence: 3, event: .presetSelected(TBPresetSelected(presetID: secondID))),
            envelope(sequence: 4, event: .presetDeleted(TBPresetDeleted(presetID: secondID)))
        ])

        XCTAssertEqual(state.presets.map(\.id), [firstID])
        XCTAssertEqual(state.selectedPresetID, firstID)
    }

    func testLocalEventLogSeedsDefaultPresetsBeforeFirstMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
        let defaultPreset = NamedTimerPreset(id: defaultID, name: "Default", preset: TimerPreset())
        let newPreset = NamedTimerPreset(id: newID, name: "New", preset: TimerPreset(workIntervalLength: 50))
        let log = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL))

        log.seedDefaultPresetsIfEmpty([defaultPreset])
        log.append(.presetUpserted(TBPresetUpserted(preset: newPreset)))

        let reloaded = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL))
        XCTAssertEqual(reloaded.projection.presets.map(\.id), [defaultID, newID])
        XCTAssertEqual(reloaded.projection.selectedPresetID, defaultID)
    }

    func testDuplicateImportAndReadBehavior() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let first = envelope(eventID: duplicateID,
                             sequence: 2,
                             event: .settingChanged(TBSettingChanged(key: .workDurationMinutes,
                                                                     value: .int(30))))
        let second = envelope(eventID: duplicateID,
                              sequence: 1,
                              event: .settingChanged(TBSettingChanged(key: .workDurationMinutes,
                                                                      value: .int(40))))
        let third = envelope(sequence: 3,
                             event: .settingChanged(TBSettingChanged(key: .extendWorkAfterFinish,
                                                                     value: .bool(true))))
        let store = TBJSONLEventStore(fileURL: fileURL)

        try store.append(first)
        try store.append(second)
        try store.append(contentsOf: [first, third])

        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.eventID), [duplicateID, third.eventID])
        XCTAssertEqual(loaded.map(\.sequence), [1, 3])

        let state = TBEventProjector.project(loaded)
        XCTAssertEqual(state.settings.preset.workIntervalLength, 40)
        XCTAssertTrue(state.settings.extendWorkAfterFinish)
    }

    func testMalformedLineAndFutureSchemaRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TBJSONLEventStore(fileURL: fileURL)
        let valid = envelope(sequence: 2,
                             event: .settingChanged(TBSettingChanged(key: .shortRestDurationMinutes,
                                                                     value: .int(8))))
        try store.append(valid)
        let invalidLines = "not json\n{\"schemaVersion\":999,\"eventID\":\"00000000-0000-0000-0000-000000000999\"}\n"
        try Data(invalidLines.utf8).append(to: fileURL)

        let loaded = try store.load()
        XCTAssertEqual(loaded, [valid])
        XCTAssertEqual(TBEventProjector.project(loaded).settings.preset.shortRestIntervalLength, 8)
    }

    func testBasicTimerProjectionStartPauseResumeStop() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let setID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let state = TBEventProjector.project([
            envelope(sequence: 1,
                     event: .timerStarted(TBTimerStarted(sessionID: sessionID,
                                                         setID: setID,
                                                         kind: .work,
                                                         startedAt: start,
                                                         plannedDuration: 1_500,
                                                         preset: TimerPresetSnapshot(preset: TimerPreset()),
                                                         workIntervalIndex: 1))),
            envelope(sequence: 2,
                     event: .timerPaused(TBTimerPaused(sessionID: sessionID,
                                                       pausedAt: start.addingTimeInterval(300)))),
            envelope(sequence: 3,
                     event: .timerResumed(TBTimerResumed(sessionID: sessionID,
                                                         resumedAt: start.addingTimeInterval(420)))),
            envelope(sequence: 4,
                     event: .timerStopped(TBTimerStopped(sessionID: sessionID,
                                                         stoppedAt: start.addingTimeInterval(900))))
        ])

        XCTAssertNil(state.timer)
        XCTAssertEqual(state.stats.count, 0)
    }

    func testActiveTimerSessionSnapshotProjectionAndClear() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = persistedSession(startedAt: now,
                                       finishAt: now.addingTimeInterval(1_500))

        let persisted = envelope(sequence: 1,
                                 event: .activeTimerSessionPersisted(TBActiveTimerSessionPersisted(session: session)))
        let projected = TBEventProjector.project([persisted])
        XCTAssertEqual(projected.activeTimerSession, session)

        let cleared = envelope(sequence: 2,
                               event: .activeTimerSessionCleared(
                                   TBActiveTimerSessionCleared(clearedAt: now.addingTimeInterval(10))
                               ))
        let clearedProjection = TBEventProjector.project([persisted, cleared])
        XCTAssertNil(clearedProjection.activeTimerSession)
    }

    func testActiveTimerSessionProjectionHasNoTimerRestoredDurableEvent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = envelope(sequence: 1,
                                event: .activeTimerSessionPersisted(TBActiveTimerSessionPersisted(
                                    session: persistedSession(startedAt: now,
                                                              finishAt: now.addingTimeInterval(1_500))
                                )))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(envelope)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("activeTimerSessionPersisted"))
        XCTAssertFalse(raw.contains("timerRestored"))
    }

    func testStatsRecordEventProjection() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!,
                           startedAt: startedAt,
                           activeDuration: 1_500,
                           completion: .completed)
        let second = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
                            startedAt: startedAt.addingTimeInterval(1_800),
                            activeDuration: 300,
                            completion: .skipped)

        let state = TBEventProjector.project([
            envelope(sequence: 2, event: .statsRecordAppended(TBStatsRecordAppended(record: second))),
            envelope(sequence: 1, event: .statsRecordAppended(TBStatsRecordAppended(record: first)))
        ])

        XCTAssertEqual(state.stats, [first, second])
    }

    func testTerminalTimerEventClearsMatchingActiveTimerSessionSnapshot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let setID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let session = persistedSession(startedAt: now,
                                       finishAt: now.addingTimeInterval(1_500),
                                       sessionID: sessionID,
                                       setID: setID)

        let state = TBEventProjector.project([
            envelope(sequence: 1,
                     event: .timerStarted(TBTimerStarted(sessionID: sessionID,
                                                         setID: setID,
                                                         kind: .work,
                                                         startedAt: now,
                                                         plannedDuration: 1_500,
                                                         preset: TimerPresetSnapshot(preset: TimerPreset()),
                                                         workIntervalIndex: 1))),
            envelope(sequence: 2,
                     event: .activeTimerSessionPersisted(TBActiveTimerSessionPersisted(session: session))),
            envelope(sequence: 3,
                     event: .timerCompleted(TBTimerCompleted(sessionID: sessionID,
                                                             completedAt: now.addingTimeInterval(1_500))))
        ])

        XCTAssertNil(state.timer)
        XCTAssertNil(state.activeTimerSession)
    }

    func testStatsRecordProjectionDedupesBySessionID() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
        let first = record(id: id,
                           startedAt: startedAt,
                           activeDuration: 1_500,
                           completion: .completed)
        let replacement = record(id: id,
                                 startedAt: startedAt,
                                 activeDuration: 300,
                                 completion: .stopped)

        let state = TBEventProjector.project([
            envelope(sequence: 1, event: .statsRecordAppended(TBStatsRecordAppended(record: first))),
            envelope(sequence: 2, event: .statsRecordAppended(TBStatsRecordAppended(record: replacement)))
        ])

        XCTAssertEqual(state.stats, [replacement])
    }

    private func envelope(eventID: UUID = UUID(),
                          sequence: Int64,
                          event: TBEvent) -> TBEventEnvelope {
        TBEventEnvelope(eventID: eventID,
                        streamID: "local",
                        sequence: sequence,
                        recordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                        event: event)
    }

    private func persistedSession(startedAt: Date,
                                  finishAt: Date,
                                  sessionID: UUID? = nil,
                                  setID: UUID? = nil) -> PersistedTimerSession {
        PersistedTimerSession(state: .work,
                              preset: TimerPreset(),
                              currentWorkInterval: 1,
                              kind: .work,
                              plannedDuration: finishAt.timeIntervalSince(startedAt),
                              startedAt: startedAt,
                              finishAt: finishAt,
                              pausedTimeRemaining: finishAt.timeIntervalSince(startedAt),
                              pausedDuration: 0,
                              workExtensionActive: false,
                              workLimitNotificationSent: false,
                              restPresentationPending: false,
                              sessionID: sessionID,
                              setID: setID)
    }

    private func record(id: UUID,
                        startedAt: Date,
                        activeDuration: TimeInterval,
                        completion: TBStatsCompletion) -> TBSessionRecord {
        TBSessionRecord(id: id,
                        kind: .work,
                        startedAt: startedAt,
                        endedAt: startedAt.addingTimeInterval(activeDuration),
                        plannedDuration: activeDuration,
                        activeDuration: activeDuration,
                        pausedDuration: 0,
                        completion: completion,
                        preset: TimerPresetSnapshot(preset: TimerPreset()),
                        workIntervalIndex: 1,
                        timezoneIdentifier: "UTC",
                        calendarIdentifier: "gregorian",
                        overtimeDuration: 0)
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

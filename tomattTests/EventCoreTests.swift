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
        let identity = TBDeviceIdentity(deviceID: "preset-test-device", displayName: "Preset Test", platform: "macOS")
        let log = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)

        log.seedDefaultPresetsIfEmpty([defaultPreset])
        log.append(.presetUpserted(TBPresetUpserted(preset: newPreset)))

        let reloaded = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
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

    func testDeterministicSyncEventIDFixture() {
        XCTAssertEqual(TBSyncEventID.derive(originDeviceID: "device-a", deviceSequence: 42),
                       UUID(uuidString: "b7ec71b7-7944-5537-98d4-9928d1c68ef6"))
    }

    func testV1EnvelopeDecodesWithoutReplicatedFields() throws {
        let raw = """
        {"event":{"payload":{"key":"workDurationMinutes","value":{"type":"int","value":30}},"type":"settingChanged"},"eventID":"00000000-0000-0000-0000-000000000101","recordedAt":"2024-01-01T00:00:00Z","schemaVersion":1,"sequence":1,"streamID":"local"}
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TBEventEnvelope.self, from: Data(raw.utf8))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.originDeviceID)
        XCTAssertNil(decoded.deviceSequence)
        XCTAssertEqual(TBEventProjector.project([decoded]).settings.preset.workIntervalLength, 30)
        XCTAssertTrue(TBAntiEntropy.missingEvents(in: [decoded], relativeTo: [:]).isEmpty)
    }

    func testLocalDeviceIdentityStoreIsInjectableAndStable() throws {
        let store = MemoryIdentityStore()
        let first = try TBDeviceIdentityProvider.loadOrCreate(store: store, defaultName: "Test Mac")
        let second = try TBDeviceIdentityProvider.loadOrCreate(store: store, defaultName: "Other")

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.displayName, "Test Mac")
    }

    func testIdentityFailurePreventsSyncableAppend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL),
                                  identityStore: ThrowingIdentityStore())

        log.append(.settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(35))))

        XCTAssertEqual(log.envelopes, [])
        XCTAssertEqual(try TBJSONLEventStore(fileURL: fileURL).load(), [])
    }

    func testSyncableOnlyDeviceSequenceAllocationSkipsLocalOnlyEvents() throws {
        let log = try makeLog(identity: TBDeviceIdentity(deviceID: "local-device",
                                                         displayName: "Local",
                                                         platform: "macOS"))

        log.append(.settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(35))))
        log.append(.activeTimerSessionCleared(TBActiveTimerSessionCleared(clearedAt: Date(timeIntervalSince1970: 2))))
        log.append(.settingChanged(TBSettingChanged(key: .shortRestDurationMinutes, value: .int(7))))

        let envelopesBySequence = Dictionary(uniqueKeysWithValues: log.envelopes.map { ($0.sequence, $0) })
        XCTAssertEqual(Set(envelopesBySequence.keys), [1, 2, 3])
        XCTAssertEqual(envelopesBySequence[1]?.deviceSequence, 1)
        XCTAssertEqual(envelopesBySequence[2]?.deviceSequence, nil)
        XCTAssertEqual(envelopesBySequence[2]?.originDeviceID, nil)
        XCTAssertEqual(envelopesBySequence[3]?.deviceSequence, 2)
        XCTAssertEqual(log.syncSummary(), ["local-device": 2])
    }

    func testProjectionCanonicalizationIndependentOfAppendOrder() {
        let first = syncEnvelope(origin: "a-device",
                                 deviceSequence: 1,
                                 recordedAt: Date(timeIntervalSince1970: 10),
                                 event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(25))))
        let second = syncEnvelope(origin: "b-device",
                                  deviceSequence: 1,
                                  recordedAt: Date(timeIntervalSince1970: 10),
                                  event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(45))))

        XCTAssertEqual(TBEventProjector.project([second, first]), TBEventProjector.project([first, second]))
        XCTAssertEqual(TBEventProjector.project([second, first]).settings.preset.workIntervalLength, 45)
    }

    func testSyncabilityTableExcludesActiveTimerSnapshots() {
        let now = Date(timeIntervalSince1970: 1)
        XCTAssertFalse(TBEvent.activeTimerSessionCleared(TBActiveTimerSessionCleared(clearedAt: now)).isSyncable)
        XCTAssertFalse(TBEvent.activeTimerSessionPersisted(
            TBActiveTimerSessionPersisted(session: persistedSession(startedAt: now, finishAt: now.addingTimeInterval(60)))
        ).isSyncable)
        XCTAssertTrue(TBEvent.devicePaired(TBDevicePaired(deviceID: "peer",
                                                          displayName: "Peer",
                                                          platform: "macOS",
                                                          pairedAt: now)).isSyncable)
        XCTAssertTrue(TBEvent.statsRecordAppended(TBStatsRecordAppended(record: record(id: UUID(), startedAt: now, activeDuration: 60, completion: .completed))).isSyncable)
    }

    func testDistributedOverlappingBranchesEarliestStartWins() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let earlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let lateID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let events = [
            timerStartEnvelope(origin: "late", sequence: 1, sessionID: lateID, startedAt: now.addingTimeInterval(10)),
            timerStartEnvelope(origin: "early", sequence: 1, sessionID: earlyID, startedAt: now)
        ]

        let state = TBEventProjector.project(events)

        XCTAssertEqual(state.timer?.sessionID, earlyID)
        XCTAssertEqual(state.distributedTimer.visibleSessionIDs, [earlyID])
        XCTAssertEqual(state.distributedTimer.losingSessionIDs, [lateID])
        XCTAssertEqual(state.distributedTimer.branches.count, 2)
    }

    func testDistributedSameStartTieBreaksBySessionOriginSequenceEventID() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let highSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let lowSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let bySession = TBEventProjector.project([
            timerStartEnvelope(origin: "a", sequence: 1, sessionID: highSessionID, startedAt: now),
            timerStartEnvelope(origin: "z", sequence: 1, sessionID: lowSessionID, startedAt: now)
        ])
        XCTAssertEqual(bySession.timer?.sessionID, lowSessionID)

        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
        let originA = timerStartEnvelope(eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                                         origin: "a", sequence: 2, sessionID: sessionID, startedAt: now)
        let originB = timerStartEnvelope(eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
                                         origin: "b", sequence: 1, sessionID: sessionID, startedAt: now)
        XCTAssertEqual(TBEventProjector.project([originB, originA]).distributedTimer.branches.first?.startEnvelope.originDeviceID, "a")

        let lowerSequence = timerStartEnvelope(eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
                                               origin: "a", sequence: 1, sessionID: sessionID, startedAt: now)
        XCTAssertEqual(TBEventProjector.project([originA, lowerSequence]).distributedTimer.branches.first?.startEnvelope.deviceSequence, 1)
    }

    func testDistributedLosingBranchEventsRemainInLogButAreExcludedFromTimerAndStats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let winningID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let losingID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        let losingRecord = record(id: losingID, startedAt: now.addingTimeInterval(10), activeDuration: 60, completion: .completed)
        let winningRecord = record(id: winningID, startedAt: now, activeDuration: 60, completion: .completed)
        let events = [
            timerStartEnvelope(origin: "a", sequence: 1, sessionID: winningID, startedAt: now),
            timerStartEnvelope(origin: "b", sequence: 1, sessionID: losingID, startedAt: now.addingTimeInterval(10)),
            syncEnvelope(origin: "b", deviceSequence: 2, event: .statsRecordAppended(TBStatsRecordAppended(record: losingRecord))),
            syncEnvelope(origin: "a", deviceSequence: 2, event: .statsRecordAppended(TBStatsRecordAppended(record: winningRecord)))
        ]

        let state = TBEventProjector.project(events)

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(state.timer?.sessionID, winningID)
        XCTAssertEqual(state.stats, [winningRecord])
        XCTAssertEqual(state.distributedTimer.branches.map(\.sessionID), [winningID, losingID])
        XCTAssertEqual(state.distributedTimer.losingSessionIDs, [losingID])
    }

    func testDistributedPauseResumeExtendsOpenBranchAndTerminalEndsVisibility() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let start = timerStartEnvelope(origin: "a", sequence: 1, sessionID: sessionID, startedAt: now)
        let paused = syncEnvelope(origin: "a", deviceSequence: 2,
                                  event: .timerPaused(TBTimerPaused(sessionID: sessionID, pausedAt: now.addingTimeInterval(60))))
        let resumed = syncEnvelope(origin: "a", deviceSequence: 3,
                                   event: .timerResumed(TBTimerResumed(sessionID: sessionID, resumedAt: now.addingTimeInterval(180))))

        let active = TBEventProjector.project([start, paused, resumed])
        XCTAssertEqual(active.timer?.status, .running)
        XCTAssertEqual(active.timer?.pausedDuration, 120)
        XCTAssertNil(active.distributedTimer.branches.first?.intervalEnd)

        let completed = syncEnvelope(origin: "a", deviceSequence: 4,
                                     event: .timerCompleted(TBTimerCompleted(sessionID: sessionID,
                                                                             completedAt: now.addingTimeInterval(1_620))))
        let ended = TBEventProjector.project([start, paused, resumed, completed])
        XCTAssertNil(ended.timer)
        XCTAssertEqual(ended.distributedTimer.branches.first?.terminalAt, now.addingTimeInterval(1_620))
        XCTAssertEqual(ended.distributedTimer.visibleSessionIDs, [sessionID])
    }

    func testCorrectionNoticeOnlyWhenVisibleTimerStateChanges() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let before = TBEventProjector.project([])
        let after = TBEventProjector.project([
            timerStartEnvelope(origin: "peer", sequence: 1, sessionID: sessionID, startedAt: now)
        ])

        XCTAssertEqual(TBTimerSyncCorrectionNoticeFactory.notice(before: before,
                                                                 after: after,
                                                                 trustedDeviceName: "Desk Mac")?.message,
                       "Timer updated after syncing with Desk Mac.")

        let settingsOnly = TBEventProjector.project([
            syncEnvelope(origin: "peer", deviceSequence: 2,
                         event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(45))))
        ])
        XCTAssertNil(TBTimerSyncCorrectionNoticeFactory.notice(before: before,
                                                               after: settingsOnly,
                                                               trustedDeviceName: "Desk Mac"))
    }

    func testStrictImportDuplicateAndCollisionRules() throws {
        let log = try makeLog(identity: TBDeviceIdentity(deviceID: "local",
                                                         displayName: "Local",
                                                         platform: "macOS"))
        let remote = syncEnvelope(origin: "remote",
                                  deviceSequence: 1,
                                  event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(40))))

        XCTAssertEqual(log.importEvents([remote]), TBImportResult(imported: 1, duplicate: 0, rejected: 0, collision: 0))
        XCTAssertEqual(log.importEvents([remote]), TBImportResult(imported: 0, duplicate: 1, rejected: 0, collision: 0))

        let eventIDCollision = syncEnvelope(eventID: remote.eventID,
                                            origin: "remote",
                                            deviceSequence: 1,
                                            event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(41))))
        let originSequenceCollision = syncEnvelope(eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                                                   origin: "remote",
                                                   deviceSequence: 1,
                                                   event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(42))))
        let rejectedLocalOnly = syncEnvelope(origin: "remote",
                                             deviceSequence: 3,
                                             event: .activeTimerSessionCleared(TBActiveTimerSessionCleared(clearedAt: Date())))
        let rejectedMissingOrigin = TBEventEnvelope(streamID: "remote",
                                                    sequence: 4,
                                                    deviceSequence: 4,
                                                    event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(43))))
        let futureSchema = syncEnvelope(schemaVersion: 999,
                                        origin: "remote",
                                        deviceSequence: 5,
                                        event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(44))))
        let nonPositiveSequence = syncEnvelope(origin: "remote",
                                               deviceSequence: 0,
                                               event: .settingChanged(TBSettingChanged(key: .workDurationMinutes,
                                                                                       value: .int(45))))

        XCTAssertEqual(log.importEvents([eventIDCollision,
                                         originSequenceCollision,
                                         rejectedLocalOnly,
                                         rejectedMissingOrigin,
                                         futureSchema,
                                         nonPositiveSequence]),
                       TBImportResult(imported: 0, duplicate: 0, rejected: 5, collision: 1))
    }

    func testGapHandlingBuffersOutOfOrderEventsWithoutAdvancingWatermark() throws {
        let log = try makeLog(identity: TBDeviceIdentity(deviceID: "local",
                                                         displayName: "Local",
                                                         platform: "macOS"))
        let third = syncEnvelope(origin: "remote", deviceSequence: 3,
                                 event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(33))))
        let first = syncEnvelope(origin: "remote", deviceSequence: 1,
                                 event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(31))))

        XCTAssertEqual(log.importEvents([third, first]).imported, 2)
        XCTAssertEqual(log.syncSummary(), ["remote": 1])

        let second = syncEnvelope(origin: "remote", deviceSequence: 2,
                                  event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(32))))
        XCTAssertEqual(log.importEvents([second]).imported, 1)
        XCTAssertEqual(log.syncSummary(), ["remote": 3])
    }

    func testImportPersistenceFailureIsReportedWithoutClaimingImportedEvents() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        let log = TBLocalEventLog(store: TBJSONLEventStore(fileURL: directoryURL),
                                  identity: TBDeviceIdentity(deviceID: "local",
                                                             displayName: "Local",
                                                             platform: "macOS"))
        let remote = syncEnvelope(origin: "remote",
                                  deviceSequence: 1,
                                  event: .settingChanged(TBSettingChanged(key: .workDurationMinutes,
                                                                          value: .int(40))))

        XCTAssertEqual(log.importEvents([remote]),
                       TBImportResult(imported: 0,
                                      duplicate: 0,
                                      rejected: 1,
                                      collision: 0,
                                      persistenceFailed: true))
    }

    func testMembershipProjectionPairRenameRemove() {
        let now = Date(timeIntervalSince1970: 1)
        let paired = syncEnvelope(origin: "local", deviceSequence: 1,
                                  event: .devicePaired(TBDevicePaired(deviceID: "peer",
                                                                      displayName: "Peer",
                                                                      platform: "macOS",
                                                                      pairedAt: now)))
        let renamed = syncEnvelope(origin: "local", deviceSequence: 2,
                                   event: .deviceRenamed(TBDeviceRenamed(deviceID: "peer", displayName: "Desk Mac", renamedAt: now.addingTimeInterval(1))))
        let projectedRename = TBEventProjector.project([paired, renamed])

        XCTAssertEqual(projectedRename.pairedDevices, [TBProjectedDevice(deviceID: "peer",
                                                                         displayName: "Desk Mac",
                                                                         platform: "macOS",
                                                                         pairedAt: now)])

        let removed = syncEnvelope(origin: "local", deviceSequence: 3,
                                   event: .deviceRemoved(TBDeviceRemoved(deviceID: "peer", removedAt: now.addingTimeInterval(2))))
        XCTAssertEqual(TBEventProjector.project([paired, renamed, removed]).pairedDevices, [])
    }

    func testTwoPeerCatchUpConvergesAndWatermarksReachTwo() throws {
        let first = try makeLog(identity: TBDeviceIdentity(deviceID: "first",
                                                           displayName: "First",
                                                           platform: "macOS"))
        let second = try makeLog(identity: TBDeviceIdentity(deviceID: "second",
                                                            displayName: "Second",
                                                            platform: "macOS"))

        first.append(.settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(30))))
        first.append(.settingChanged(TBSettingChanged(key: .shortRestDurationMinutes, value: .int(6))))
        second.append(.settingChanged(TBSettingChanged(key: .longRestDurationMinutes, value: .int(18))))
        second.append(.settingChanged(TBSettingChanged(key: .workIntervalsPerSet, value: .int(3))))

        _ = second.importEvents(first.missingEvents(relativeTo: second.syncSummary()))
        _ = first.importEvents(second.missingEvents(relativeTo: first.syncSummary()))

        XCTAssertEqual(first.syncSummary(), ["first": 2, "second": 2])
        XCTAssertEqual(second.syncSummary(), ["first": 2, "second": 2])
        XCTAssertEqual(first.projection, second.projection)
    }

    @MainActor
    func testTimerReloadAfterSyncPublishesCorrectionOnlyForVisibleTimerChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let identity = TBDeviceIdentity(deviceID: "local", displayName: "Local", platform: "macOS")
        let readerLog = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
        let writerLog = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let before = readerLog.projection

        _ = writerLog.importEvents([
            timerStartEnvelope(origin: "peer", sequence: 1, sessionID: sessionID, startedAt: Date(timeIntervalSince1970: 100))
        ])
        readerLog.reloadFromStore()

        XCTAssertEqual(TBTimerSyncCorrectionNoticeFactory.notice(before: before,
                                                                after: readerLog.projection,
                                                                trustedDeviceName: "Desk Mac")?.message,
                       "Timer updated after syncing with Desk Mac.")
    }

    @MainActor
    func testTimerReloadAfterSettingsOnlySyncDoesNotPublishCorrection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let identity = TBDeviceIdentity(deviceID: "local", displayName: "Local", platform: "macOS")
        let readerLog = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
        let writerLog = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
        let before = readerLog.projection

        _ = writerLog.importEvents([
            syncEnvelope(origin: "peer",
                         deviceSequence: 1,
                         event: .settingChanged(TBSettingChanged(key: .pauseAfterRestFinish, value: .bool(true))))
        ])
        readerLog.reloadFromStore()

        XCTAssertNil(TBTimerSyncCorrectionNoticeFactory.notice(before: before,
                                                              after: readerLog.projection,
                                                              trustedDeviceName: "Desk Mac"))
        XCTAssertTrue(readerLog.projection.settings.pauseAfterRestFinish)
    }

    func testReloadFromStoreRefreshesStatsAndTimerProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let identity = TBDeviceIdentity(deviceID: "local", displayName: "Local", platform: "macOS")
        let staleLog = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
        let writerLog = TBLocalEventLog(store: TBJSONLEventStore(fileURL: fileURL), identity: identity)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let startedAt = Date(timeIntervalSince1970: 100)
        let stats = record(id: sessionID, startedAt: startedAt, activeDuration: 1_500, completion: .completed)

        _ = writerLog.importEvents([
            timerStartEnvelope(origin: "peer", sequence: 1, sessionID: sessionID, startedAt: startedAt),
            syncEnvelope(origin: "peer", deviceSequence: 2, event: .statsRecordAppended(TBStatsRecordAppended(record: stats)))
        ])
        XCTAssertNil(staleLog.projection.timer)

        staleLog.reloadFromStore()

        XCTAssertEqual(staleLog.projection.timer?.sessionID, sessionID)
        XCTAssertEqual(staleLog.projection.stats, [stats])
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

    private func syncEnvelope(schemaVersion: Int = TBEventSchemaVersion,
                              eventID: UUID? = nil,
                              origin: String,
                              deviceSequence: Int64,
                              recordedAt: Date? = nil,
                              event: TBEvent) -> TBEventEnvelope {
        let id = eventID ?? TBSyncEventID.derive(originDeviceID: origin, deviceSequence: deviceSequence)
        return TBEventEnvelope(schemaVersion: schemaVersion,
                               eventID: id,
                               streamID: origin,
                               sequence: deviceSequence,
                               originDeviceID: origin,
                               deviceSequence: deviceSequence,
                               recordedAt: recordedAt ?? Date(timeIntervalSince1970: TimeInterval(deviceSequence)),
                               event: event)
    }

    private func timerStartEnvelope(eventID: UUID? = nil,
                                    origin: String,
                                    sequence: Int64,
                                    sessionID: UUID,
                                    startedAt: Date,
                                    plannedDuration: TimeInterval = 1_500) -> TBEventEnvelope {
        syncEnvelope(eventID: eventID,
                     origin: origin,
                     deviceSequence: sequence,
                     recordedAt: startedAt,
                     event: .timerStarted(TBTimerStarted(sessionID: sessionID,
                                                         setID: UUID(uuidString: "00000000-0000-0000-0000-000000000777")!,
                                                         kind: .work,
                                                         startedAt: startedAt,
                                                         plannedDuration: plannedDuration,
                                                         preset: TimerPresetSnapshot(preset: TimerPreset()),
                                                         workIntervalIndex: 1)))
    }

    private func makeLog(identity: TBDeviceIdentity) throws -> TBLocalEventLog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TBLocalEventLog(store: TBJSONLEventStore(fileURL: directory.appendingPathComponent("events.jsonl")),
                               identity: identity)
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

private final class MemoryIdentityStore: TBDeviceIdentityStoring {
    var identity: TBDeviceIdentity?

    func loadIdentity() throws -> TBDeviceIdentity? {
        identity
    }

    func saveIdentity(_ identity: TBDeviceIdentity) throws {
        self.identity = identity
    }
}

private struct ThrowingIdentityStore: TBDeviceIdentityStoring {
    struct IdentityError: Error {}

    func loadIdentity() throws -> TBDeviceIdentity? {
        throw IdentityError()
    }

    func saveIdentity(_: TBDeviceIdentity) throws {
        throw IdentityError()
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

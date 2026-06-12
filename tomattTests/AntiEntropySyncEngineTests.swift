import XCTest

final class AntiEntropySyncEngineTests: XCTestCase {
    func testTwoTrustedEncryptedPeersConvergeFromDivergentLogs() throws {
        let fixture = try makeFixture()
        fixture.aLog.append(.settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(30))))
        fixture.bLog.append(.settingChanged(TBSettingChanged(key: .shortRestDurationMinutes, value: .int(7))))

        let statuses = drain(fixture, initialMessages: fixture.aPeer.beginSync() + fixture.bPeer.beginSync())

        XCTAssertEqual(fixture.aLog.syncSummary(), [fixture.aID: 1, fixture.bID: 1])
        XCTAssertEqual(fixture.bLog.syncSummary(), [fixture.aID: 1, fixture.bID: 1])
        XCTAssertTrue(statuses.contains { if case .eventBatchImported = $0 { return true }; return false })
    }

    func testPeerDoesNotAdvertiseOrExportThirdPartyOriginEvents() throws {
        let cID = "00000000-0000-0000-0000-000000000103"
        let fixture = try makeFixture(seedA: [makeEnvelope(deviceID: cID, sequence: 1)])

        let summaries = try fixture.aPeer.beginSync().map { try fixture.bSession.open($0) }
        XCTAssertEqual(summaries.count, 1)
        guard case .eventSummary(let advertised)? = summaries.first?.payload else {
            return XCTFail("expected A to advertise a local summary")
        }
        XCTAssertEqual(advertised.deviceID, fixture.aID)
        XCTAssertEqual(advertised.eventCount, 0)

        let requestC = try sealMissingRequest(from: fixture.bSession,
                                              deviceID: cID,
                                              afterSequence: 0,
                                              messageID: "request-third-party-c")
        let result = fixture.aPeer.receive(requestC)

        guard case .eventBatchSent(_, let eventIDs)? = result.statuses.first(where: {
            if case .eventBatchSent = $0 { return true }
            return false
        }) else {
            return XCTFail("expected an event batch response")
        }
        XCTAssertEqual(eventIDs, [])

        let batches = try result.outgoingMessages.map { try fixture.bSession.open($0) }
        guard case .eventBatch(let batch)? = batches.first?.payload else {
            return XCTFail("expected an empty event batch response")
        }
        XCTAssertEqual(batch.events, [])

        var thirdPartySummary = Tomatt_Sync_V1_EventSummary()
        thirdPartySummary.deviceID = cID
        thirdPartySummary.eventCount = 2
        var summaryEnvelope = Tomatt_Sync_V1_Envelope()
        summaryEnvelope.messageID = "summary-third-party-c"
        summaryEnvelope.protocolMajor = fixture.bSession.context.protocolMajor
        summaryEnvelope.payload = .eventSummary(thirdPartySummary)

        let summaryResult = fixture.aPeer.receive(try fixture.bSession.seal(envelope: summaryEnvelope))

        XCTAssertEqual(summaryResult.outgoingMessages, [])
        XCTAssertFalse(summaryResult.statuses.contains {
            if case .missingEventsRequested(let deviceID, _) = $0 { return deviceID == cID }
            return false
        })
    }

    func testLocalOnlyActiveTimerSnapshotsAreNotExported() throws {
        let fixture = try makeFixture()
        let session = PersistedTimerSession(state: .work,
                                            preset: TimerPreset(),
                                            currentWorkInterval: 1,
                                            kind: .work,
                                            plannedDuration: 1500,
                                            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            finishAt: Date(timeIntervalSince1970: 1_700_001_500),
                                            pauseStartedAt: nil,
                                            pausedTimeRemaining: 0,
                                            pausedDuration: 0,
                                            workExtensionActive: false,
                                            workLimitNotificationSent: false,
                                            restPresentationPending: false,
                                            sessionID: UUID(),
                                            setID: UUID())
        fixture.aLog.append(.activeTimerSessionPersisted(TBActiveTimerSessionPersisted(session: session)))

        let request = try sealMissingRequest(from: fixture.bSession,
                                             deviceID: fixture.aID,
                                             afterSequence: 0,
                                             messageID: "request-local-only")
        let result = fixture.aPeer.receive(request)

        guard case .eventBatchSent(_, let eventIDs)? = result.statuses.first(where: {
            if case .eventBatchSent = $0 { return true }
            return false
        }) else {
            return XCTFail("expected an event batch response")
        }
        XCTAssertEqual(eventIDs, [])
    }

    func testOutOfOrderGappedEventDoesNotAdvanceWatermarkIncorrectly() throws {
        let fixture = try makeFixture(seedA: [makeEnvelope(deviceID: "00000000-0000-0000-0000-000000000101", sequence: 2)] )
        let request = try sealMissingRequest(from: fixture.bSession,
                                             deviceID: fixture.aID,
                                             afterSequence: 0,
                                             messageID: "request-gap")

        let first = fixture.aPeer.receive(request)
        let statuses = drain(fixture, initialMessages: first.outgoingMessages)

        XCTAssertEqual(fixture.bLog.missingEvents(relativeTo: [:]).map(\.deviceSequence), [2])
        XCTAssertEqual(fixture.bLog.syncSummary()[fixture.aID], nil)
        XCTAssertTrue(statuses.contains { status in
            if case .eventBatchImported(_, let outcome) = status { return outcome.imported == 1 }
            return false
        })
    }

    func testImportSignatureFailureSurfacesTypedErrorAndRejectedAck() throws {
        let fixture = try makeFixture(seedA: [makeEnvelope(deviceID: "00000000-0000-0000-0000-000000000101", sequence: 1)])
        var signed = try TBSignedSyncEvent.sign(envelope: fixture.aLog.missingEvents(relativeTo: [:])[0],
                                               signerDeviceID: fixture.aID,
                                               signer: fixture.aSigner)
        signed.signature = Data("invalid".utf8)
        let encrypted = try sealSignedBatch(from: fixture.aSession,
                                            signedEvents: [signed],
                                            messageID: "bad-batch")

        let result = fixture.bPeer.receive(encrypted)

        XCTAssertTrue(result.statuses.contains(.error(.importSecurity(.invalidSignature))))
        XCTAssertTrue(result.statuses.contains { status in
            guard case .eventBatchAcked(let ack) = status else { return false }
            return ack.batchMessageID == "bad-batch" && ack.acceptedEventIDs.isEmpty && ack.rejectedEventIDs.count == 1
        })
    }

    func testProtocolFailureSurfacesTypedStatus() throws {
        let fixture = try makeFixture()
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = "unsupported"
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.payload = .ping(Tomatt_Sync_V1_Ping())
        let encrypted = try fixture.aSession.seal(envelope: envelope)

        let result = fixture.bPeer.receive(encrypted)

        XCTAssertTrue(result.statuses.contains(.error(.protocolViolation("unsupported anti-entropy payload"))))
    }

    func testNewLocalSyncableEventTriggersNewEventsAvailableFlow() throws {
        let fixture = try makeFixture()
        fixture.aLog.append(.settingChanged(TBSettingChanged(key: .pauseAfterRestFinish, value: .bool(true))))

        let statuses = drain(fixture, initialMessages: fixture.aPeer.notifyNewLocalEventsAvailable())

        XCTAssertEqual(fixture.bLog.syncSummary()[fixture.aID], 1)
        XCTAssertTrue(statuses.contains(.newEventsAvailable(deviceID: fixture.aID, eventCount: 1)))
    }

    func testEventBatchAckContainsAcceptedStatus() throws {
        let fixture = try makeFixture(seedA: [makeEnvelope(deviceID: "00000000-0000-0000-0000-000000000101", sequence: 1)])
        let request = try sealMissingRequest(from: fixture.bSession,
                                             deviceID: fixture.aID,
                                             afterSequence: 0,
                                             messageID: "request-ack")

        let first = fixture.aPeer.receive(request)
        let statuses = drain(fixture, initialMessages: first.outgoingMessages)

        XCTAssertTrue(statuses.contains { status in
            guard case .eventBatchAcked(let ack) = status else { return false }
            return ack.acceptedEventIDs.count == 1 && ack.rejectedEventIDs.isEmpty
        })
    }

    func testEventBatchAckRejectsAllIDsWhenImportOutcomeIsPartialFailure() throws {
        let fixture = try makeFixture(
            seedA: [
                makeEnvelope(deviceID: "00000000-0000-0000-0000-000000000101", sequence: 1),
                makeEnvelope(deviceID: "00000000-0000-0000-0000-000000000101", sequence: 2),
            ],
            seedB: [makeEnvelope(deviceID: "00000000-0000-0000-0000-000000000101", sequence: 1, value: 99)]
        )
        let signedEvents = try fixture.aLog.missingEvents(relativeTo: [:]).map {
            try TBSignedSyncEvent.sign(envelope: $0, signerDeviceID: fixture.aID, signer: fixture.aSigner)
        }
        let encrypted = try sealSignedBatch(from: fixture.aSession,
                                            signedEvents: signedEvents,
                                            messageID: "partial-failure-batch")

        let result = fixture.bPeer.receive(encrypted)

        XCTAssertTrue(result.statuses.contains { status in
            guard case .eventBatchImported(_, let outcome) = status else { return false }
            return outcome.imported == 1 && outcome.collision == 1
        })
        XCTAssertTrue(result.statuses.contains { status in
            guard case .eventBatchAcked(let ack) = status else { return false }
            return ack.batchMessageID == "partial-failure-batch"
                && ack.acceptedEventIDs.isEmpty
                && ack.rejectedEventIDs == signedEvents.map { $0.envelope.eventID.uuidString.lowercased() }
        })
    }

    private func drain(_ fixture: Fixture, initialMessages: [TBEncryptedLANMessage]) -> [TBAntiEntropySyncStatus] {
        TBInMemoryEncryptedSyncHarness.drain(initialMessages) { message in
            if message.recipientDeviceID == fixture.aID { return fixture.aPeer }
            if message.recipientDeviceID == fixture.bID { return fixture.bPeer }
            return nil
        }
    }

    private func makeFixture(seedA: [TBEventEnvelope] = [], seedB: [TBEventEnvelope] = []) throws -> Fixture {
        let aID = "00000000-0000-0000-0000-000000000101"
        let bID = "00000000-0000-0000-0000-000000000102"
        let aSigner = TBDeterministicTestSigner(secret: Data("engine-a".utf8))
        let bSigner = TBDeterministicTestSigner(secret: Data("engine-b".utf8))
        let aLog = try makeLog(deviceID: aID, seed: seedA)
        let bLog = try makeLog(deviceID: bID, seed: seedB)
        let aIdentity = TBSyncDevicePublicIdentity(deviceID: aID, displayName: "A", platform: "macOS", signingPublicKey: aSigner.publicKey)
        let bIdentity = TBSyncDevicePublicIdentity(deviceID: bID, displayName: "B", platform: "macOS", signingPublicKey: bSigner.publicKey)
        let aStore = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: bID,
                                                                               displayName: "B",
                                                                               platform: "macOS",
                                                                               signingPublicKey: bSigner.publicKey)])
        let bStore = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: aID,
                                                                               displayName: "A",
                                                                               platform: "macOS",
                                                                               signingPublicKey: aSigner.publicKey)])
        let aContext = try TBAuthenticatedPeerContextBuilder.build(localIdentity: aIdentity,
                                                                   peerDeviceID: bID,
                                                                   peerStore: aStore,
                                                                   capabilities: ["encrypted-lan", "signed-events"])
        let bContext = try TBAuthenticatedPeerContextBuilder.build(localIdentity: bIdentity,
                                                                   peerDeviceID: aID,
                                                                   peerStore: bStore,
                                                                   capabilities: ["encrypted-lan", "signed-events"])
        let key = try TBSessionKeyMaterial.fixedTestKey(Data(repeating: 9, count: 32), keyID: "engine-test")
        let aSession = TBSyncSessionCryptoBox(context: aContext,
                                             keyMaterial: key,
                                             localRole: .initiator,
                                             localNonceSeed: Data(repeating: 3, count: 32),
                                             peerNonceSeed: Data(repeating: 4, count: 32))
        let bSession = TBSyncSessionCryptoBox(context: bContext,
                                             keyMaterial: key,
                                             localRole: .responder,
                                             localNonceSeed: Data(repeating: 4, count: 32),
                                             peerNonceSeed: Data(repeating: 3, count: 32))
        let aFacade = TBSyncEventLogFacade(eventLog: aLog)
        let bFacade = TBSyncEventLogFacade(eventLog: bLog)
        let aImporter = TBSignedSyncEventTrustedImporter(peerStore: aStore, verifier: bSigner, sink: aFacade)
        let bImporter = TBSignedSyncEventTrustedImporter(peerStore: bStore, verifier: aSigner, sink: bFacade)
        let aEngine = TBAntiEntropySyncEngine(session: aSession,
                                             eventLog: aFacade,
                                             signerDeviceID: aID,
                                             signer: aSigner,
                                             trustedImporter: aImporter)
        let bEngine = TBAntiEntropySyncEngine(session: bSession,
                                             eventLog: bFacade,
                                             signerDeviceID: bID,
                                             signer: bSigner,
                                             trustedImporter: bImporter)
        return Fixture(aID: aID,
                       bID: bID,
                       aSigner: aSigner,
                       aSession: aSession,
                       bSession: bSession,
                       aLog: aLog,
                       bLog: bLog,
                       aPeer: TBInMemoryEncryptedSyncPeer(engine: aEngine),
                       bPeer: TBInMemoryEncryptedSyncPeer(engine: bEngine))
    }

    private func makeLog(deviceID: String, seed: [TBEventEnvelope]) throws -> TBLocalEventLog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = TBJSONLEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        for event in seed { try store.append(event) }
        return TBLocalEventLog(store: store,
                               identity: TBDeviceIdentity(deviceID: deviceID, displayName: "Test", platform: "macOS"))
    }

    private func sealMissingRequest(from session: TBSyncSessionCryptoBox,
                                    deviceID: String,
                                    afterSequence: Int64,
                                    messageID: String) throws -> TBEncryptedLANMessage {
        var request = Tomatt_Sync_V1_MissingEventRequest()
        request.deviceID = deviceID
        request.afterSequence = UInt64(afterSequence)
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = messageID
        envelope.protocolMajor = session.context.protocolMajor
        envelope.payload = .missingEventRequest(request)
        return try session.seal(envelope: envelope)
    }

    private func sealSignedBatch(from session: TBSyncSessionCryptoBox,
                                 signedEvents: [TBSignedSyncEvent],
                                 messageID: String) throws -> TBEncryptedLANMessage {
        var batch = Tomatt_Sync_V1_EventBatch()
        batch.deviceID = session.context.localDeviceID
        batch.events = try signedEvents.map { signed in
            var event = Tomatt_Sync_V1_SyncEvent()
            event.eventID = signed.envelope.eventID.uuidString.lowercased()
            event.originDeviceID = signed.envelope.originDeviceID ?? ""
            event.sequence = UInt64(signed.envelope.deviceSequence ?? 0)
            event.canonicalJson = try JSONEncoder().encode(signed)
            return event
        }
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = messageID
        envelope.protocolMajor = session.context.protocolMajor
        envelope.payload = .eventBatch(batch)
        return try session.seal(envelope: envelope)
    }

    private static func makeEnvelope(deviceID: String, sequence: Int64) -> TBEventEnvelope {
        makeEnvelope(deviceID: deviceID, sequence: sequence, value: Int(sequence) + 20)
    }

    private static func makeEnvelope(deviceID: String, sequence: Int64, value: Int) -> TBEventEnvelope {
        TBEventEnvelope(eventID: TBSyncEventID.derive(originDeviceID: deviceID, deviceSequence: sequence),
                        streamID: "sync",
                        sequence: sequence,
                        originDeviceID: deviceID,
                        deviceSequence: sequence,
                        recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(sequence)),
                        event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(value))))
    }

    private func makeEnvelope(deviceID: String, sequence: Int64) -> TBEventEnvelope {
        Self.makeEnvelope(deviceID: deviceID, sequence: sequence)
    }

    private func makeEnvelope(deviceID: String, sequence: Int64, value: Int) -> TBEventEnvelope {
        Self.makeEnvelope(deviceID: deviceID, sequence: sequence, value: value)
    }

    private struct Fixture {
        let aID: String
        let bID: String
        let aSigner: TBDeterministicTestSigner
        let aSession: TBSyncSessionCryptoBox
        let bSession: TBSyncSessionCryptoBox
        let aLog: TBLocalEventLog
        let bLog: TBLocalEventLog
        let aPeer: TBInMemoryEncryptedSyncPeer
        let bPeer: TBInMemoryEncryptedSyncPeer
    }
}

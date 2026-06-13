import Foundation
import XCTest

final class PairingCoreTests: XCTestCase {
    func testDeterministicTranscriptDerivedCodeVector() throws {
        let transcript = makeTranscript()

        XCTAssertEqual(try transcript.verificationCode(), "599898")
        XCTAssertEqual(try transcript.verificationCode(), try makeTranscript().verificationCode())
    }

    func testOnePairDeviceModelKeepsInternalRolesOnly() {
        let flow = TBPairDeviceFlowModel(internalRole: .joinSyncGroup)

        XCTAssertEqual(flow.primaryActionTitle, "Pair Device")
        XCTAssertFalse(flow.exposesTopLevelAddOrJoinActions)
        XCTAssertEqual(flow.internalRole, .joinSyncGroup)
    }

    func testGroupCompatibilityRules() throws {
        XCTAssertEqual(try TBPairingGroupCompatibilityRules.evaluate(local: .standalone, remote: .standalone), .createNewSyncGroup)
        XCTAssertEqual(try TBPairingGroupCompatibilityRules.evaluate(local: .grouped(groupID: "group-1"), remote: .standalone), .joinExistingGroup(groupID: "group-1"))
        XCTAssertEqual(try TBPairingGroupCompatibilityRules.evaluate(local: .grouped(groupID: "group-1"), remote: .grouped(groupID: "group-1")), .sameGroup(groupID: "group-1"))
        XCTAssertThrowsError(try TBPairingGroupCompatibilityRules.evaluate(local: .grouped(groupID: "group-1"), remote: .grouped(groupID: "group-2"))) { error in
            XCTAssertEqual(error as? TBPairingGroupCompatibilityError,
                           .differentGroups(localGroupID: "group-1",
                                            remoteGroupID: "group-2",
                                            guidance: TBPairingGroupCompatibilityRules.resetGuidance))
        }
    }

    func testTranscriptCodeChangesForEndpointGroupCapabilityAndNonceFacts() throws {
        let baseline = makeTranscript()
        let baselineCode = try baseline.verificationCode()
        var manualEndpoint = baseline
        manualEndpoint.remote.endpoint.host = "192.0.2.10"
        manualEndpoint.remote.endpoint.metadata["source"] = "manual-address"
        var grouped = baseline
        grouped.remote.groupState = .grouped(groupID: "group-1")
        var capability = baseline
        capability.capabilities.append("new-capability")
        var nonce = baseline
        nonce.sessionNonce = Data("different-session-nonce".utf8)

        XCTAssertNotEqual(try manualEndpoint.verificationCode(), baselineCode)
        XCTAssertNotEqual(try grouped.verificationCode(), baselineCode)
        XCTAssertNotEqual(try capability.verificationCode(), baselineCode)
        XCTAssertNotEqual(try nonce.verificationCode(), baselineCode)
    }

    func testMirroredPeerTranscriptsDeriveSameVerificationCode() throws {
        let addDeviceView = makeTranscript()
        var joinSyncGroupView = addDeviceView
        joinSyncGroupView.role = .joinSyncGroup
        joinSyncGroupView.local = addDeviceView.remote
        joinSyncGroupView.remote = addDeviceView.local

        XCTAssertEqual(try addDeviceView.verificationCode(), try joinSyncGroupView.verificationCode())
    }

    func testMismatchOrNoConfirmationBlocksCommit() throws {
        let fixture = makeSessionFixture()
        let code = try fixture.session.start(now: fixture.now)

        XCTAssertEqual(code, try fixture.session.transcript.verificationCode())
        XCTAssertThrowsError(try fixture.session.confirmCode("000000", now: fixture.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .codeMismatch)
        }
        XCTAssertThrowsError(try fixture.session.commit(using: fixture.applier, now: fixture.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .previewNotApproved)
        }
        XCTAssertTrue(fixture.applier.trustedPeers.isEmpty)
        XCTAssertTrue(fixture.applier.syncGroupKeys.isEmpty)
        XCTAssertTrue(fixture.applier.membershipActions.isEmpty)
        XCTAssertTrue(fixture.applier.importedEvents.isEmpty)
    }

    func testTimeoutCancelAndRetryLeaveNoPermanentWrites() throws {
        let fixture = makeSessionFixture()

        XCTAssertThrowsError(try fixture.session.start(now: fixture.now.addingTimeInterval(61))) { error in
            XCTAssertEqual(error as? TBPairingGateError, .expired)
        }
        XCTAssertEqual(fixture.session.state, .expired)
        XCTAssertTrue(fixture.applier.trustedPeers.isEmpty)

        let cancelled = makeSessionFixture()
        cancelled.session.cancel()
        XCTAssertThrowsError(try cancelled.session.start(now: cancelled.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .cancelled)
        }
        XCTAssertTrue(cancelled.applier.trustedPeers.isEmpty)

        let retry = cancelled.session.retry(expiresAt: cancelled.now.addingTimeInterval(120))
        XCTAssertEqual(try retry.start(now: cancelled.now), try retry.transcript.verificationCode())
        XCTAssertTrue(cancelled.applier.trustedPeers.isEmpty)
    }

    func testNonIdleStartAndFinalGateBlockCommit() throws {
        var busyTranscript = makeTranscript()
        busyTranscript.local.idle = .busy(at: makeDate(), reason: "timer-running")
        let busyStart = makeSessionFixture(transcript: busyTranscript)

        XCTAssertThrowsError(try busyStart.session.start(now: busyStart.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .localNotIdle)
        }
        XCTAssertTrue(busyStart.applier.trustedPeers.isEmpty)

        var remoteBusyTranscript = makeTranscript()
        remoteBusyTranscript.remote.idle = .busy(at: makeDate(), reason: "timer-running")
        let remoteBusyStart = makeSessionFixture(transcript: remoteBusyTranscript)
        XCTAssertThrowsError(try remoteBusyStart.session.start(now: remoteBusyStart.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .remoteNotIdle)
        }
        XCTAssertTrue(remoteBusyStart.applier.trustedPeers.isEmpty)

        let finalGate = makeSessionFixture()
        _ = try finalGate.session.start(now: finalGate.now)
        try finalGate.session.confirmCode(try finalGate.session.transcript.verificationCode(), now: finalGate.now)
        try finalGate.session.approvePreview(makePreview(settingsSourceChoice: .keepLocal), now: finalGate.now)
        finalGate.session.updateIdleDeclarations(local: .idle(at: makeDate()),
                                                 remote: .busy(at: makeDate(), reason: "timer-running"))

        XCTAssertThrowsError(try finalGate.session.commit(using: finalGate.applier, now: finalGate.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .remoteNotIdle)
        }
        XCTAssertTrue(finalGate.applier.trustedPeers.isEmpty)
    }

    func testNoPermanentCommitBeforeCodeConfirmationPreviewApprovalAndSettingsChoice() throws {
        let fixture = makeSessionFixture()
        _ = try fixture.session.start(now: fixture.now)

        XCTAssertThrowsError(try fixture.session.approvePreview(makePreview(settingsSourceChoice: .keepLocal), now: fixture.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .codeNotConfirmed)
        }
        XCTAssertTrue(fixture.applier.trustedPeers.isEmpty)

        try fixture.session.confirmCode(try fixture.session.transcript.verificationCode(), now: fixture.now)
        XCTAssertThrowsError(try fixture.session.approvePreview(makePreview(settingsSourceChoice: nil), now: fixture.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .settingsSourceRequired)
        }
        XCTAssertThrowsError(try fixture.session.commit(using: fixture.applier, now: fixture.now)) { error in
            XCTAssertEqual(error as? TBPairingGateError, .previewNotApproved)
        }
        XCTAssertTrue(fixture.applier.trustedPeers.isEmpty)
        XCTAssertTrue(fixture.applier.syncGroupKeys.isEmpty)
        XCTAssertTrue(fixture.applier.membershipActions.isEmpty)
        XCTAssertTrue(fixture.applier.importedEvents.isEmpty)
    }

    func testSuccessfulAllOrNothingStagedCommitWritesAllActionsViaFakeApplier() throws {
        let fixture = makeSessionFixture()
        _ = try fixture.session.start(now: fixture.now)
        try fixture.session.confirmCode(try fixture.session.transcript.verificationCode(), now: fixture.now)
        try fixture.session.approvePreview(makePreview(settingsSourceChoice: .useRemote), now: fixture.now)
        try fixture.session.commit(using: fixture.applier, now: fixture.now)

        XCTAssertEqual(fixture.session.state, .committed)
        XCTAssertEqual(fixture.applier.trustedPeers, [fixture.commit.trustedPeer])
        XCTAssertEqual(fixture.applier.syncGroupKeys, [fixture.commit.syncGroupKey])
        XCTAssertEqual(fixture.applier.membershipActions, fixture.commit.membershipActions)
        XCTAssertEqual(fixture.applier.importedEvents, fixture.commit.importedEvents)
        XCTAssertEqual(fixture.applier.appliedCommits.single?.settingsSourceChoice, .useRemote)

        let failing = TBInMemoryPairingCommitApplier()
        failing.failure = NSError(domain: "pairing-test", code: 1)
        let failedFixture = makeSessionFixture(applier: failing)
        _ = try failedFixture.session.start(now: failedFixture.now)
        try failedFixture.session.confirmCode(try failedFixture.session.transcript.verificationCode(), now: failedFixture.now)
        try failedFixture.session.approvePreview(makePreview(settingsSourceChoice: .keepLocal), now: failedFixture.now)
        XCTAssertThrowsError(try failedFixture.session.commit(using: failing, now: failedFixture.now))
        XCTAssertTrue(failing.trustedPeers.isEmpty)
        XCTAssertTrue(failing.syncGroupKeys.isEmpty)
        XCTAssertTrue(failing.membershipActions.isEmpty)
        XCTAssertTrue(failing.importedEvents.isEmpty)
        XCTAssertTrue(failing.appliedCommits.isEmpty)
    }

    func testPreviewIncludesRequiredFields() {
        let preview = makePreview(settingsSourceChoice: .keepLocal)

        XCTAssertEqual(preview.localDevice.displayName, "Local Mac")
        XCTAssertEqual(preview.remoteDevice.platform, "macOS")
        XCTAssertTrue(preview.bothIdle)
        XCTAssertTrue(preview.settingsDiffer)
        XCTAssertEqual(preview.localPresetCount, 2)
        XCTAssertEqual(preview.remotePresetCount, 3)
        XCTAssertEqual(preview.localHistory.eventCount, 5)
        XCTAssertEqual(preview.remoteHistory.eventCount, 7)
        XCTAssertEqual(preview.localHistory.dateRangeStart, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(preview.remoteHistory.dateRangeEnd, Date(timeIntervalSince1970: 1_700_001_000))
        XCTAssertEqual(preview.settingsSourceChoice, .keepLocal)
    }

    private func makeSessionFixture(transcript: TBPairingTranscript? = nil,
                                    applier: TBInMemoryPairingCommitApplier = TBInMemoryPairingCommitApplier()) -> Fixture {
        let now = makeDate()
        let commit = makeStagedCommit()
        let session = TBPairingSession(transcript: transcript ?? makeTranscript(),
                                       stagedCommit: commit,
                                       expiresAt: now.addingTimeInterval(60))
        return Fixture(now: now, session: session, commit: commit, applier: applier)
    }

    private func makeTranscript() -> TBPairingTranscript {
        let date = makeDate()
        let localEphemeral = try! TBPairingEphemeralKeyPair(rawPrivateKeyRepresentation: Data(repeating: 1, count: 32))
        let remoteEphemeral = try! TBPairingEphemeralKeyPair(rawPrivateKeyRepresentation: Data(repeating: 2, count: 32))
        return TBPairingTranscript(
            protocolVersion: 1,
            role: .addDevice,
            local: makeParticipant(deviceID: "local-device",
                                    displayName: "Local Mac",
                                    ephemeralKey: localEphemeral.publicKey,
                                    signingKey: Data("local-signing-key".utf8),
                                    discoveryID: "disc-local",
                                    host: "local.local",
                                   port: 4040,
                                   idle: .idle(at: date)),
            remote: makeParticipant(deviceID: "remote-device",
                                     displayName: "Remote Mac",
                                     ephemeralKey: remoteEphemeral.publicKey,
                                     signingKey: Data("remote-signing-key".utf8),
                                    discoveryID: "disc-remote",
                                    host: "remote.local",
                                    port: 4041,
                                    idle: .idle(at: date)),
            timestamp: date,
            sessionNonce: Data("session-nonce-0001".utf8),
            capabilities: ["preview-v1", "pairing-v1"]
        )
    }

    private func makeParticipant(deviceID: String,
                                 displayName: String,
                                 ephemeralKey: Data,
                                 signingKey: Data,
                                 discoveryID: String,
                                 host: String,
                                 port: Int,
                                 idle: TBPairingIdleDeclaration) -> TBPairingTranscriptParticipant {
        TBPairingTranscriptParticipant(
            deviceID: deviceID,
            displayName: displayName,
            platform: "macOS",
            ephemeralPairingPublicKey: ephemeralKey,
            signingPublicKey: signingKey,
            ephemeralDiscoveryID: discoveryID,
            endpoint: TBPairingEndpointMetadata(host: host,
                                                port: port,
                                                transport: "ws",
                                                path: "/tomatt-sync",
                                                metadata: ["proto": "tomatt-sync", "v": "1", "transport": "ws", "encoding": "protobuf"]),
            idle: idle,
            capabilities: ["preview-v1", "pairing-v1"],
            groupState: .standalone
        )
    }

    private func makePreview(settingsSourceChoice: TBPairingSettingsSourceChoice?) -> TBPairingPreMergePreview {
        TBPairingPreMergePreview(
            localDevice: TBDeviceIdentity(deviceID: "local-device", displayName: "Local Mac", platform: "macOS"),
            remoteDevice: TBDeviceIdentity(deviceID: "remote-device", displayName: "Remote Mac", platform: "macOS"),
            bothIdle: true,
            settingsDiffer: true,
            localPresetCount: 2,
            remotePresetCount: 3,
            localHistory: TBPairingHistorySummary(eventCount: 5,
                                                  dateRangeStart: Date(timeIntervalSince1970: 1_700_000_000),
                                                  dateRangeEnd: Date(timeIntervalSince1970: 1_700_000_500)),
            remoteHistory: TBPairingHistorySummary(eventCount: 7,
                                                   dateRangeStart: Date(timeIntervalSince1970: 1_700_000_100),
                                                   dateRangeEnd: Date(timeIntervalSince1970: 1_700_001_000)),
            settingsSourceChoice: settingsSourceChoice
        )
    }

    private func makeStagedCommit() -> TBPairingStagedCommit {
        let event = TBEventEnvelope(eventID: TBSyncEventID.derive(originDeviceID: "remote-device", deviceSequence: 1),
                                    streamID: "sync",
                                    sequence: 1,
                                    originDeviceID: "remote-device",
                                    deviceSequence: 1,
                                    recordedAt: makeDate(),
                                    event: .devicePaired(TBDevicePaired(deviceID: "remote-device",
                                                                       displayName: "Remote Mac",
                                                                       platform: "macOS",
                                                                       pairedAt: makeDate())))
        return TBPairingStagedCommit(
            trustedPeer: TBTrustedPeerRecord(deviceID: "remote-device",
                                             displayName: "Remote Mac",
                                             platform: "macOS",
                                             signingPublicKey: Data("remote-signing-key".utf8)),
            syncGroupKey: try! TBSyncGroupKeyRecord.importExisting(groupID: "group-1",
                                                                   keyID: "key-1",
                                                                   secret: Data(repeating: 9, count: 32),
                                                                   createdAt: makeDate()),
            membershipActions: [.devicePaired(deviceID: "remote-device", displayName: "Remote Mac"),
                                .deviceJoinedGroup(deviceID: "remote-device", groupID: "group-1")],
            importedEvents: [event],
            settingsSourceChoice: .keepLocal
        )
    }

    private func makeDate() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private struct Fixture {
        let now: Date
        let session: TBPairingSession
        let commit: TBPairingStagedCommit
        let applier: TBInMemoryPairingCommitApplier
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}

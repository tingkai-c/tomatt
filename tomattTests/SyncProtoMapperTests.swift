import SwiftProtobuf
import XCTest

final class SyncProtoMapperTests: XCTestCase {
    func testSummaryAndMissingRequestMapping() throws {
        let deviceID = "00000000-0000-0000-0000-000000000201"
        let summary: TBSyncWatermarkSummary = [deviceID: 7]

        let protoSummary = try TomattSyncProtoMapper.protoSummaries(from: summary)
        let protoRequest = try TomattSyncProtoMapper.protoMissingRequests(from: summary, limit: 50)

        XCTAssertEqual(protoSummary.map(\.deviceID), [deviceID])
        XCTAssertEqual(protoSummary.map(\.eventCount), [7])
        XCTAssertEqual(try TomattSyncProtoMapper.syncSummary(from: protoSummary), summary)
        XCTAssertEqual(try TomattSyncProtoMapper.missingRequest(from: protoRequest[0]).remoteSummary, summary)
        XCTAssertEqual(try TomattSyncProtoMapper.missingRequest(from: protoRequest[0]).limit, 50)
    }

    func testEventBatchMappingRoundTripsCanonicalEnvelopeBytes() throws {
        let deviceID = "00000000-0000-0000-0000-000000000202"
        let envelope = syncableEnvelope(originDeviceID: deviceID, deviceSequence: 1)

        let proto = try TomattSyncProtoMapper.protoEventBatch(from: TBSyncEventBatch(events: [envelope]),
                                                              senderDeviceID: deviceID)
        let batch = try TomattSyncProtoMapper.eventBatch(from: proto)

        XCTAssertEqual(proto.deviceID, deviceID)
        XCTAssertEqual(proto.events[0].eventID, envelope.eventID.uuidString.lowercased())
        XCTAssertEqual(proto.events[0].originDeviceID, deviceID)
        XCTAssertEqual(proto.events[0].sequence, 1)
        XCTAssertEqual(batch.events, [envelope])
    }

    func testMapperRejectsMalformedUUIDAndFutureSchema() throws {
        var badUUIDEvent = Tomatt_Sync_V1_SyncEvent()
        badUUIDEvent.eventID = "not-a-uuid"
        badUUIDEvent.originDeviceID = "00000000-0000-0000-0000-000000000203"
        badUUIDEvent.sequence = 1
        badUUIDEvent.canonicalJson = Data("{}".utf8)

        XCTAssertThrowsError(try TomattSyncProtoMapper.eventEnvelope(from: badUUIDEvent))

        var futureSchema = syncableEnvelope(originDeviceID: "00000000-0000-0000-0000-000000000204",
                                            deviceSequence: 1)
        futureSchema.schemaVersion = TBEventSchemaVersion + 1

        XCTAssertThrowsError(try TomattSyncProtoMapper.protoSyncEvent(from: futureSchema))
    }

    func testEncryptedLANMessageMapperRoundTripsEnvelopePayload() throws {
        let message = TBEncryptedLANMessage(protocolVersion: 1,
                                            senderDeviceID: "00000000-0000-0000-0000-000000000211",
                                            recipientDeviceID: "00000000-0000-0000-0000-000000000212",
                                            senderSigningKeyFingerprint: String(repeating: "a", count: 64),
                                            direction: .initiatorToResponder,
                                            counter: 3,
                                            nonce: Data([1, 2, 3]),
                                            ciphertextAndTag: Data([4, 5, 6, 7]))

        let envelope = try TomattSyncProtoMapper.protoEnvelope(from: message)
        let roundTripped = try TomattSyncProtoMapper.encryptedLANMessage(from: envelope)

        XCTAssertEqual(envelope.protocolMajor, TomattSyncProtocolV1.supportedMajorVersion)
        XCTAssertEqual(envelope.encryptedLanMessage.direction, .initiatorToResponder)
        XCTAssertEqual(roundTripped, message)
    }

    func testEncryptedLANMessageMapperRejectsInvalidDirectionAndMissingData() throws {
        var envelope = try TomattSyncProtoMapper.protoEnvelope(from: TBEncryptedLANMessage(
            protocolVersion: 1,
            senderDeviceID: "00000000-0000-0000-0000-000000000213",
            recipientDeviceID: "00000000-0000-0000-0000-000000000214",
            senderSigningKeyFingerprint: String(repeating: "b", count: 64),
            direction: .responderToInitiator,
            counter: 1,
            nonce: Data([8]),
            ciphertextAndTag: Data([9])
        ))
        envelope.encryptedLanMessage.direction = .unspecified

        XCTAssertThrowsError(try TomattSyncProtoMapper.encryptedLANMessage(from: envelope)) { error in
            XCTAssertEqual(error as? TomattSyncProtoMapperError, .invalidEncryptedLANMessageDirection(0))
        }
        XCTAssertThrowsError(try TomattSyncProtoMapper.protoEnvelope(from: TBEncryptedLANMessage(
            protocolVersion: 1,
            senderDeviceID: "00000000-0000-0000-0000-000000000213",
            recipientDeviceID: "00000000-0000-0000-0000-000000000214",
            senderSigningKeyFingerprint: String(repeating: "b", count: 64),
            direction: .responderToInitiator,
            counter: 1,
            nonce: Data(),
            ciphertextAndTag: Data([9])
        ))) { error in
            XCTAssertEqual(error as? TomattSyncProtoMapperError, .invalidEncryptedLANMessageField("nonce"))
        }
    }

    func testPairingShellMappersRoundTripExistingProtoMessages() throws {
        let start = TBPairingWireStart(deviceID: "00000000-0000-0000-0000-000000000215", displayName: "Peer")
        let challenge = TBPairingWireChallenge(challengeID: "challenge", challenge: Data([1, 2]))
        let response = TBPairingWireResponse(challengeID: "challenge", response: Data([3, 4]))
        let complete = TBPairingWireComplete(pairingID: "pairing")

        XCTAssertEqual(try TomattSyncProtoMapper.pairingStart(from: TomattSyncProtoMapper.protoEnvelope(from: start)), start)
        XCTAssertEqual(try TomattSyncProtoMapper.pairingChallenge(from: TomattSyncProtoMapper.protoEnvelope(from: challenge)), challenge)
        XCTAssertEqual(try TomattSyncProtoMapper.pairingResponse(from: TomattSyncProtoMapper.protoEnvelope(from: response)), response)
        XCTAssertEqual(try TomattSyncProtoMapper.pairingComplete(from: TomattSyncProtoMapper.protoEnvelope(from: complete)), complete)
    }

    func testPairingWireMappersCarryTranscriptParticipantFacts() throws {
        let participant = Tomatt_Sync_V1_PairingTranscriptParticipant.with {
            $0.deviceID = "00000000-0000-0000-0000-000000000216"
            $0.displayName = "Peer"
            $0.platform = "macOS"
            $0.syncSigningPublicKey = Data(repeating: 1, count: 32)
            $0.syncSigningKeyFingerprint = String(repeating: "a", count: 64)
            $0.ephemeralPairingPublicKey = Data(repeating: 2, count: 65)
            $0.ephemeralDiscoveryID = "ephemeral"
            $0.endpoint.host = "peer.local"
            $0.endpoint.port = 40484
            $0.endpoint.transport = "websocket"
            $0.endpoint.path = "/tomatt-sync"
            $0.idle.isIdle = true
            $0.idle.declaredAt.seconds = 1
            $0.capabilities = ["pairing-v1"]
            $0.groupState.kind = .standalone
            $0.sessionNonce = Data(repeating: 3, count: 32)
            $0.transcriptProtocolVersion = 1
        }
        let start = TBPairingWireStart(deviceID: participant.deviceID,
                                       displayName: participant.displayName,
                                       participant: participant)
        let challenge = TBPairingWireChallenge(challengeID: "challenge",
                                               challenge: Data([1, 2]),
                                               participant: participant)

        XCTAssertEqual(try TomattSyncProtoMapper.pairingStart(from: TomattSyncProtoMapper.protoEnvelope(from: start)).participant, participant)
        XCTAssertEqual(try TomattSyncProtoMapper.pairingChallenge(from: TomattSyncProtoMapper.protoEnvelope(from: challenge)).participant, participant)
    }

    private func syncableEnvelope(originDeviceID: String, deviceSequence: Int64) -> TBEventEnvelope {
        TBEventEnvelope(eventID: TBSyncEventID.derive(originDeviceID: originDeviceID,
                                                      deviceSequence: deviceSequence),
                        streamID: "local",
                        sequence: deviceSequence,
                        originDeviceID: originDeviceID,
                        deviceSequence: deviceSequence,
                        recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(30))))
    }
}

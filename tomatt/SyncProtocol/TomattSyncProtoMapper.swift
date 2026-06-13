import Foundation
import SwiftProtobuf

enum TomattSyncProtoMapperError: Error, Equatable {
    case invalidCanonicalUUID(String)
    case invalidSequence(UInt64)
    case missingCanonicalJSON
    case invalidEventEnvelope
    case unsupportedFutureSchema(Int)
    case nonSyncableEvent
    case eventIdentityMismatch
    case missingEncryptedLANMessage
    case invalidEncryptedLANMessageField(String)
    case invalidEncryptedLANMessageDirection(Int)
    case missingPairingPayload
    case invalidPairingPayloadField(String)
}

struct TBPairingWireStart: Equatable {
    var deviceID: String
    var displayName: String
    var participant: Tomatt_Sync_V1_PairingTranscriptParticipant? = nil
}

struct TBPairingWireChallenge: Equatable {
    var challengeID: String
    var challenge: Data
    var participant: Tomatt_Sync_V1_PairingTranscriptParticipant? = nil
}

struct TBPairingWireResponse: Equatable {
    var challengeID: String
    var response: Data
}

struct TBPairingWireComplete: Equatable {
    var pairingID: String
}

enum TomattSyncProtoMapper {
    static func protoSummaries(from summary: TBSyncWatermarkSummary) throws -> [Tomatt_Sync_V1_EventSummary] {
        try summary.keys.sorted().map { deviceID in
            try validateCanonicalUUID(deviceID)
            var proto = Tomatt_Sync_V1_EventSummary()
            proto.deviceID = deviceID
            proto.eventCount = UInt64(summary[deviceID] ?? 0)
            return proto
        }
    }

    static func syncSummary(from protos: [Tomatt_Sync_V1_EventSummary]) throws -> TBSyncWatermarkSummary {
        var summary: TBSyncWatermarkSummary = [:]
        for proto in protos {
            try validateCanonicalUUID(proto.deviceID)
            summary[proto.deviceID] = Int64(proto.eventCount)
        }
        return summary
    }

    static func protoMissingRequests(from summary: TBSyncWatermarkSummary,
                                     limit: UInt32 = 0) throws -> [Tomatt_Sync_V1_MissingEventRequest] {
        try summary.keys.sorted().map { deviceID in
            try validateCanonicalUUID(deviceID)
            var proto = Tomatt_Sync_V1_MissingEventRequest()
            proto.deviceID = deviceID
            proto.afterSequence = UInt64(summary[deviceID] ?? 0)
            proto.limit = limit
            return proto
        }
    }

    static func missingRequest(from proto: Tomatt_Sync_V1_MissingEventRequest) throws -> TBSyncMissingEventsRequest {
        try validateCanonicalUUID(proto.deviceID)
        for eventID in proto.missingEventIds {
            try validateCanonicalUUID(eventID)
        }
        return TBSyncMissingEventsRequest(remoteSummary: [proto.deviceID: Int64(proto.afterSequence)],
                                          limit: proto.limit == 0 ? nil : Int(proto.limit))
    }

    static func protoEventBatch(from batch: TBSyncEventBatch, senderDeviceID: String) throws -> Tomatt_Sync_V1_EventBatch {
        try validateCanonicalUUID(senderDeviceID)
        var proto = Tomatt_Sync_V1_EventBatch()
        proto.deviceID = senderDeviceID
        proto.events = try batch.events.map(protoSyncEvent(from:))
        return proto
    }

    static func eventBatch(from proto: Tomatt_Sync_V1_EventBatch) throws -> TBSyncEventBatch {
        if !proto.deviceID.isEmpty {
            try validateCanonicalUUID(proto.deviceID)
        }
        return TBSyncEventBatch(events: try proto.events.map(eventEnvelope(from:)))
    }

    static func protoSyncEvent(from envelope: TBEventEnvelope) throws -> Tomatt_Sync_V1_SyncEvent {
        guard envelope.schemaVersion == TBEventSchemaVersion else {
            throw TomattSyncProtoMapperError.unsupportedFutureSchema(envelope.schemaVersion)
        }
        guard envelope.event.isSyncable else { throw TomattSyncProtoMapperError.nonSyncableEvent }
        guard let originDeviceID = envelope.originDeviceID,
              let deviceSequence = envelope.deviceSequence,
              deviceSequence > 0 else {
            throw TomattSyncProtoMapperError.eventIdentityMismatch
        }
        try validateCanonicalUUID(envelope.eventID.uuidString.lowercased())
        try validateCanonicalUUID(originDeviceID)
        guard envelope.eventID == TBSyncEventID.derive(originDeviceID: originDeviceID,
                                                       deviceSequence: deviceSequence) else {
            throw TomattSyncProtoMapperError.eventIdentityMismatch
        }

        var proto = Tomatt_Sync_V1_SyncEvent()
        proto.eventID = envelope.eventID.uuidString.lowercased()
        proto.originDeviceID = originDeviceID
        proto.sequence = UInt64(deviceSequence)
        proto.occurredAt = timestamp(from: envelope.recordedAt)
        proto.canonicalJson = try canonicalEnvelopeData(from: envelope)
        proto.activeDurationSeconds = activeDurationSeconds(from: envelope)
        return proto
    }

    static func eventEnvelope(from proto: Tomatt_Sync_V1_SyncEvent) throws -> TBEventEnvelope {
        try validateCanonicalUUID(proto.eventID)
        try validateCanonicalUUID(proto.originDeviceID)
        guard proto.sequence > 0 else { throw TomattSyncProtoMapperError.invalidSequence(proto.sequence) }
        guard !proto.canonicalJson.isEmpty else { throw TomattSyncProtoMapperError.missingCanonicalJSON }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(TBEventEnvelope.self, from: proto.canonicalJson) else {
            throw TomattSyncProtoMapperError.invalidEventEnvelope
        }
        guard envelope.schemaVersion == TBEventSchemaVersion else {
            throw TomattSyncProtoMapperError.unsupportedFutureSchema(envelope.schemaVersion)
        }
        guard envelope.event.isSyncable else { throw TomattSyncProtoMapperError.nonSyncableEvent }
        guard envelope.eventID.uuidString.lowercased() == proto.eventID,
              envelope.originDeviceID == proto.originDeviceID,
              envelope.deviceSequence == Int64(proto.sequence),
              envelope.eventID == TBSyncEventID.derive(originDeviceID: proto.originDeviceID,
                                                       deviceSequence: Int64(proto.sequence)) else {
            throw TomattSyncProtoMapperError.eventIdentityMismatch
        }
        return envelope
    }

    static func protoEnvelope(from encryptedMessage: TBEncryptedLANMessage) throws -> Tomatt_Sync_V1_Envelope {
        try validateEncryptedLANMessage(encryptedMessage)

        var proto = Tomatt_Sync_V1_EncryptedLANMessage()
        proto.protocolVersion = encryptedMessage.protocolVersion
        proto.senderDeviceID = encryptedMessage.senderDeviceID
        proto.recipientDeviceID = encryptedMessage.recipientDeviceID
        proto.senderSigningKeyFingerprint = encryptedMessage.senderSigningKeyFingerprint
        proto.direction = protoDirection(from: encryptedMessage.direction)
        proto.counter = encryptedMessage.counter
        proto.nonce = encryptedMessage.nonce
        proto.ciphertextAndTag = encryptedMessage.ciphertextAndTag

        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.encryptedLanMessage = proto
        return envelope
    }

    static func encryptedLANMessage(from envelope: Tomatt_Sync_V1_Envelope) throws -> TBEncryptedLANMessage {
        guard case .encryptedLanMessage(let proto)? = envelope.payload else {
            throw TomattSyncProtoMapperError.missingEncryptedLANMessage
        }
        let direction = try syncDirection(from: proto.direction)
        let message = TBEncryptedLANMessage(protocolVersion: proto.protocolVersion,
                                            senderDeviceID: proto.senderDeviceID,
                                            recipientDeviceID: proto.recipientDeviceID,
                                            senderSigningKeyFingerprint: proto.senderSigningKeyFingerprint,
                                            direction: direction,
                                            counter: proto.counter,
                                            nonce: proto.nonce,
                                            ciphertextAndTag: proto.ciphertextAndTag)
        try validateEncryptedLANMessage(message)
        return message
    }

    static func protoEnvelope(from start: TBPairingWireStart) throws -> Tomatt_Sync_V1_Envelope {
        guard !start.deviceID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("deviceID") }
        var envelope = baseEnvelope()
        envelope.pairingStart = Tomatt_Sync_V1_PairingStart.with {
            $0.deviceID = start.deviceID
            $0.displayName = start.displayName
            if let participant = start.participant { $0.participant = participant }
        }
        return envelope
    }

    static func pairingStart(from envelope: Tomatt_Sync_V1_Envelope) throws -> TBPairingWireStart {
        guard case .pairingStart(let proto)? = envelope.payload else { throw TomattSyncProtoMapperError.missingPairingPayload }
        guard !proto.deviceID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("deviceID") }
        return TBPairingWireStart(deviceID: proto.deviceID,
                                  displayName: proto.displayName,
                                  participant: proto.hasParticipant ? proto.participant : nil)
    }

    static func protoEnvelope(from challenge: TBPairingWireChallenge) throws -> Tomatt_Sync_V1_Envelope {
        guard !challenge.challengeID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("challengeID") }
        guard !challenge.challenge.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("challenge") }
        var envelope = baseEnvelope()
        envelope.pairingChallenge = Tomatt_Sync_V1_PairingChallenge.with {
            $0.challengeID = challenge.challengeID
            $0.challenge = challenge.challenge
            if let participant = challenge.participant { $0.participant = participant }
        }
        return envelope
    }

    static func pairingChallenge(from envelope: Tomatt_Sync_V1_Envelope) throws -> TBPairingWireChallenge {
        guard case .pairingChallenge(let proto)? = envelope.payload else { throw TomattSyncProtoMapperError.missingPairingPayload }
        guard !proto.challengeID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("challengeID") }
        guard !proto.challenge.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("challenge") }
        return TBPairingWireChallenge(challengeID: proto.challengeID,
                                      challenge: proto.challenge,
                                      participant: proto.hasParticipant ? proto.participant : nil)
    }

    static func protoEnvelope(from response: TBPairingWireResponse) throws -> Tomatt_Sync_V1_Envelope {
        guard !response.challengeID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("challengeID") }
        guard !response.response.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("response") }
        var envelope = baseEnvelope()
        envelope.pairingResponse = Tomatt_Sync_V1_PairingResponse.with {
            $0.challengeID = response.challengeID
            $0.response = response.response
        }
        return envelope
    }

    static func pairingResponse(from envelope: Tomatt_Sync_V1_Envelope) throws -> TBPairingWireResponse {
        guard case .pairingResponse(let proto)? = envelope.payload else { throw TomattSyncProtoMapperError.missingPairingPayload }
        guard !proto.challengeID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("challengeID") }
        guard !proto.response.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("response") }
        return TBPairingWireResponse(challengeID: proto.challengeID, response: proto.response)
    }

    static func protoEnvelope(from complete: TBPairingWireComplete) throws -> Tomatt_Sync_V1_Envelope {
        guard !complete.pairingID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("pairingID") }
        var envelope = baseEnvelope()
        envelope.pairingComplete = Tomatt_Sync_V1_PairingComplete.with { $0.pairingID = complete.pairingID }
        return envelope
    }

    static func pairingComplete(from envelope: Tomatt_Sync_V1_Envelope) throws -> TBPairingWireComplete {
        guard case .pairingComplete(let proto)? = envelope.payload else { throw TomattSyncProtoMapperError.missingPairingPayload }
        guard !proto.pairingID.isEmpty else { throw TomattSyncProtoMapperError.invalidPairingPayloadField("pairingID") }
        return TBPairingWireComplete(pairingID: proto.pairingID)
    }

    private static func canonicalEnvelopeData(from envelope: TBEventEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func baseEnvelope() -> Tomatt_Sync_V1_Envelope {
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
        return envelope
    }

    private static func validateCanonicalUUID(_ value: String) throws {
        guard TomattSyncProtocolV1.isCanonicalLowercaseUUIDString(value) else {
            throw TomattSyncProtoMapperError.invalidCanonicalUUID(value)
        }
    }

    private static func validateEncryptedLANMessage(_ message: TBEncryptedLANMessage) throws {
        guard message.protocolVersion > 0 else {
            throw TomattSyncProtoMapperError.invalidEncryptedLANMessageField("protocolVersion")
        }
        try validateCanonicalUUID(message.senderDeviceID)
        try validateCanonicalUUID(message.recipientDeviceID)
        guard !message.senderSigningKeyFingerprint.isEmpty else {
            throw TomattSyncProtoMapperError.invalidEncryptedLANMessageField("senderSigningKeyFingerprint")
        }
        guard message.counter > 0 else {
            throw TomattSyncProtoMapperError.invalidEncryptedLANMessageField("counter")
        }
        guard !message.nonce.isEmpty else {
            throw TomattSyncProtoMapperError.invalidEncryptedLANMessageField("nonce")
        }
        guard !message.ciphertextAndTag.isEmpty else {
            throw TomattSyncProtoMapperError.invalidEncryptedLANMessageField("ciphertextAndTag")
        }
    }

    private static func protoDirection(from direction: TBSyncSessionDirection) -> Tomatt_Sync_V1_EncryptedLANMessage.Direction {
        switch direction {
        case .initiatorToResponder:
            return .initiatorToResponder
        case .responderToInitiator:
            return .responderToInitiator
        }
    }

    private static func syncDirection(from direction: Tomatt_Sync_V1_EncryptedLANMessage.Direction) throws -> TBSyncSessionDirection {
        switch direction {
        case .initiatorToResponder:
            return .initiatorToResponder
        case .responderToInitiator:
            return .responderToInitiator
        case .unspecified, .UNRECOGNIZED:
            throw TomattSyncProtoMapperError.invalidEncryptedLANMessageDirection(direction.rawValue)
        }
    }

    private static func timestamp(from date: Date) -> Google_Protobuf_Timestamp {
        let interval = date.timeIntervalSince1970
        var timestamp = Google_Protobuf_Timestamp()
        timestamp.seconds = Int64(interval)
        timestamp.nanos = Int32((interval - Double(timestamp.seconds)) * 1_000_000_000)
        return timestamp
    }

    private static func activeDurationSeconds(from envelope: TBEventEnvelope) -> UInt32 {
        switch envelope.event {
        case .statsRecordAppended(let payload):
            return UInt32(max(0, payload.record.activeDuration.rounded()))
        default:
            return 0
        }
    }
}

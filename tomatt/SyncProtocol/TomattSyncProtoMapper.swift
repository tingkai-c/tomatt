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

    private static func canonicalEnvelopeData(from envelope: TBEventEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func validateCanonicalUUID(_ value: String) throws {
        guard TomattSyncProtocolV1.isCanonicalLowercaseUUIDString(value) else {
            throw TomattSyncProtoMapperError.invalidCanonicalUUID(value)
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

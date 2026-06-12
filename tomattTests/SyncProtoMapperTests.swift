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

import Foundation
import SwiftProtobuf
import XCTest

final class SyncProtocolCompatibilityTests: XCTestCase {
    func testEnvelopeRoundTripBinaryEncodeDecode() throws {
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = "00000000-0000-0000-0000-000000000001"
        envelope.correlationID = "00000000-0000-0000-0000-000000000002"
        envelope.responseToMessageID = "00000000-0000-0000-0000-000000000003"
        envelope.sentAt = timestamp(seconds: 1_700_000_000)
        envelope.protocolMajor = 1
        envelope.protocolMinor = 0
        envelope.ping = Tomatt_Sync_V1_Ping.with {
            $0.nonce = "ping-1"
        }

        let data = try envelope.serializedData()
        let decoded = try Tomatt_Sync_V1_Envelope(serializedBytes: data)

        XCTAssertEqual(decoded.messageID, envelope.messageID)
        XCTAssertEqual(decoded.correlationID, envelope.correlationID)
        XCTAssertEqual(decoded.responseToMessageID, envelope.responseToMessageID)
        XCTAssertEqual(decoded.sentAt.seconds, 1_700_000_000)
        XCTAssertEqual(decoded.protocolMajor, 1)
        XCTAssertEqual(decoded.protocolMinor, 0)
        XCTAssertEqual(decoded.ping.nonce, "ping-1")
    }

    func testHelloMajorMinorVersionCompatibilityAndCapabilities() {
        let compatible = Tomatt_Sync_V1_Hello.with {
            $0.deviceID = "00000000-0000-0000-0000-000000000010"
            $0.displayName = "MacBook"
            $0.platform = "macOS"
            $0.protocolMajor = 1
            $0.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
            $0.capabilities = ["event-summary", "event-batch"]
        }
        let incompatibleMajor = Tomatt_Sync_V1_Hello.with {
            $0.protocolMajor = 2
            $0.protocolMinor = 0
        }
        let incompatibleMinor = Tomatt_Sync_V1_Hello.with {
            $0.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
            $0.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion + 1
        }

        XCTAssertTrue(TomattSyncProtocolV1.isCompatibleHello(compatible))
        XCTAssertFalse(TomattSyncProtocolV1.isCompatibleHello(incompatibleMajor))
        XCTAssertFalse(TomattSyncProtocolV1.isCompatibleHello(incompatibleMinor))
        XCTAssertEqual(compatible.protocolMinor, TomattSyncProtocolV1.supportedMinorVersion)
        XCTAssertEqual(compatible.capabilities, ["event-summary", "event-batch"])
    }

    func testCanonicalUUIDLowercaseValidationHelper() {
        XCTAssertTrue(TomattSyncProtocolV1.isCanonicalLowercaseUUIDString("00000000-0000-0000-0000-000000000020"))
        XCTAssertFalse(TomattSyncProtocolV1.isCanonicalLowercaseUUIDString("00000000-0000-0000-0000-00000000002X"))
        XCTAssertFalse(TomattSyncProtocolV1.isCanonicalLowercaseUUIDString("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        XCTAssertFalse(TomattSyncProtocolV1.isCanonicalLowercaseUUIDString("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    }

    func testIntegerDurationSecondsAndTimestampMapping() throws {
        var event = Tomatt_Sync_V1_SyncEvent()
        event.eventID = "00000000-0000-0000-0000-000000000030"
        event.originDeviceID = "00000000-0000-0000-0000-000000000031"
        event.sequence = 42
        event.occurredAt = timestamp(seconds: 1_700_000_100, nanos: 123_000_000)
        event.canonicalJson = Data(#"{"type":"timerStarted"}"#.utf8)
        event.activeDurationSeconds = 1_500

        let decoded = try Tomatt_Sync_V1_SyncEvent(serializedBytes: event.serializedData())

        XCTAssertEqual(decoded.occurredAt.seconds, 1_700_000_100)
        XCTAssertEqual(decoded.occurredAt.nanos, 123_000_000)
        XCTAssertEqual(decoded.activeDurationSeconds, 1_500)
    }

    func testErrorCodeEncoding() throws {
        let error = Tomatt_Sync_V1_ProtocolError.with {
            $0.code = .unsupportedVersion
            $0.message = "Unsupported protocol major version"
            $0.detail = "expected=1 actual=2"
        }

        let decoded = try Tomatt_Sync_V1_ProtocolError(serializedBytes: error.serializedData())

        XCTAssertEqual(decoded.code, .unsupportedVersion)
        XCTAssertEqual(decoded.message, "Unsupported protocol major version")
        XCTAssertEqual(decoded.detail, "expected=1 actual=2")
    }

    private func timestamp(seconds: Int64, nanos: Int32 = 0) -> Google_Protobuf_Timestamp {
        var value = Google_Protobuf_Timestamp()
        value.seconds = seconds
        value.nanos = nanos
        return value
    }
}

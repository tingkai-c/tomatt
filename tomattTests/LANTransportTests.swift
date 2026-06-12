import Foundation
import XCTest

final class LANTransportTests: XCTestCase {
    func testAdvertisementTXTMetadataIsMinimalAndDoesNotExposeStableIdentity() {
        let config = LANAdvertisementConfig.internalPlaintext(
            port: 4040,
            discoveryID: LANDiscoveryID(rawValue: "ephemeral-disc")
        )

        XCTAssertEqual(config.serviceType, "_tomatt-sync._tcp")
        XCTAssertEqual(Set(config.txtMetadata.keys), LANTransportInternalPlaintext.allowedTXTKeys)
        XCTAssertEqual(config.txtMetadata["proto"], "tomatt-sync")
        XCTAssertEqual(config.txtMetadata["v"], "1")
        XCTAssertEqual(config.txtMetadata["transport"], "ws")
        XCTAssertEqual(config.txtMetadata["encoding"], "protobuf")
        XCTAssertEqual(config.txtMetadata["disc"], "ephemeral-disc")
        XCTAssertNil(config.txtMetadata["deviceId"])
        XCTAssertNil(config.txtMetadata["deviceID"])
        XCTAssertNil(config.txtMetadata["displayName"])
    }

    func testDiscoveredPeerExposesDiscoveryIDButNoStableDeviceIdentityContract() {
        let peer = LANDiscoveredPeer(host: "example.local", port: 4040, metadata: [
            "proto": "tomatt-sync",
            "v": "1",
            "transport": "ws",
            "encoding": "protobuf",
            "disc": "disc-1",
            "deviceId": "must-not-leak-through",
        ])

        XCTAssertEqual(peer?.discoveryID.rawValue, "disc-1")
        XCTAssertEqual(peer?.host, "example.local")
        XCTAssertEqual(peer?.port, 4040)
        XCTAssertNil(peer?.metadata["deviceId"])
    }

    func testHandshakeAcceptsExpectedPathAndSubprotocolOnly() {
        let accepted = LANWebSocketHandshakeValidator.validate(LANWebSocketHandshakeRequest(
            path: "/tomatt-sync",
            requestedSubprotocols: ["other", "tomatt.sync.v1.protobuf"]
        ))
        let wrongPath = LANWebSocketHandshakeValidator.validate(LANWebSocketHandshakeRequest(
            path: "/wrong",
            requestedSubprotocols: ["tomatt.sync.v1.protobuf"]
        ))
        let wrongSubprotocol = LANWebSocketHandshakeValidator.validate(LANWebSocketHandshakeRequest(
            path: "/tomatt-sync",
            requestedSubprotocols: ["json"]
        ))

        XCTAssertEqual(accepted, .accept(subprotocol: "tomatt.sync.v1.protobuf"))
        XCTAssertEqual(wrongPath, .reject(.wrongPath))
        XCTAssertEqual(wrongSubprotocol, .reject(.missingRequiredSubprotocol))
    }

    func testBinaryEnvelopeRoundTripAndNonBinaryOrInvalidProtobufRejection() throws {
        let envelope = LANControlEnvelopeFactory.ping(messageID: "msg-1", nonce: "nonce-1")
        let frame = try LANEnvelopeFrameCodec.encode(envelope)

        switch LANEnvelopeFrameCodec.decode(frame) {
        case .success(let decoded):
            XCTAssertEqual(decoded.messageID, "msg-1")
            XCTAssertEqual(decoded.ping.nonce, "nonce-1")
        case .failure(let error):
            XCTFail("Expected decode success, got \(error)")
        }

        XCTAssertEqual(LANEnvelopeFrameCodec.decode(.text("{}")), .failure(.nonBinaryFrame))
        XCTAssertEqual(LANEnvelopeFrameCodec.decode(.binary(Data([0xFF]))), .failure(.invalidProtobuf))
    }

    func testHelloPingPongHelpersBuildAndParseControlEnvelopes() {
        let hello = LANControlEnvelopeFactory.hello(
            messageID: "hello-1",
            platform: "macOS",
            capabilities: ["hello", "ping-pong"]
        )
        let ping = LANControlEnvelopeFactory.ping(messageID: "ping-1", nonce: "n")
        let pong = LANControlEnvelopeFactory.pong(messageID: "pong-1", responseToMessageID: "ping-1", nonce: "n")

        XCTAssertEqual(hello.protocolMajor, 1)
        XCTAssertEqual(hello.hello.deviceID, "")
        XCTAssertEqual(hello.hello.displayName, "")
        XCTAssertEqual(hello.hello.capabilities, ["hello", "ping-pong"])
        XCTAssertEqual(LANControlEnvelopeFactory.controlKind(of: hello), .hello(hello.hello))
        XCTAssertEqual(LANControlEnvelopeFactory.controlKind(of: ping), .ping(ping.ping))
        XCTAssertEqual(LANControlEnvelopeFactory.controlKind(of: pong), .pong(pong.pong))
        XCTAssertEqual(pong.responseToMessageID, "ping-1")
    }

    func testHeartbeatBackoffIsDeterministicWithInjectedJitterUnit() {
        let policy = LANHeartbeatBackoffPolicy(
            heartbeatInterval: 10,
            initialReconnectDelay: 2,
            maxReconnectDelay: 20,
            multiplier: 2,
            jitterFraction: 0.25
        )
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(policy.nextHeartbeat(after: now), Date(timeIntervalSince1970: 110))
        XCTAssertEqual(policy.reconnectDelay(attempt: 1, jitterUnit: 0.5), 2)
        XCTAssertEqual(policy.reconnectDelay(attempt: 2, jitterUnit: 1.0), 5)
        XCTAssertEqual(policy.reconnectDelay(attempt: 5, jitterUnit: 0.0), 15)
    }

    func testDuplicateConnectionResolutionDefersBeforeVerifiedIdentity() {
        XCTAssertEqual(
            LANDuplicateConnectionResolver.resolveBeforeVerifiedIdentity(),
            .deferUntilVerifiedIdentity
        )
    }
}

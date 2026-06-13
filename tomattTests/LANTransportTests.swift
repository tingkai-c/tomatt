import Foundation
import XCTest

final class LANTransportTests: XCTestCase {
    func testDefaultPortAndOverrideConfig() throws {
        let defaultConfig = try LANTransportConfig()
        let overrideConfig = try LANTransportConfig(port: 50505)

        XCTAssertEqual(LANTransportInternalPlaintext.defaultPort, 40484)
        XCTAssertEqual(defaultConfig.port, 40484)
        XCTAssertEqual(overrideConfig.port, 50505)
        XCTAssertThrowsError(try LANTransportConfig(port: 0)) { error in
            XCTAssertEqual(error as? LANTransportConfigurationError, .invalidPort(0))
        }
    }

    func testPortUnavailableIsSurfacedByRuntimeModel() throws {
        let runtime = LANTransportRuntimeModel(
            config: try LANTransportConfig(port: 40484),
            advertiser: FakeBonjourAdvertiser(),
            browser: FakeBonjourBrowser(),
            server: FakeWebSocketServer(startError: LANTransportRuntimeError.portUnavailable(port: 40484))
        )

        runtime.start(discoveryID: LANDiscoveryID(rawValue: "disc"))

        XCTAssertEqual(runtime.status, .failed(.portUnavailable(port: 40484)))
        XCTAssertFalse(runtime.isAdvertising)
        XCTAssertFalse(runtime.isBrowsing)
        XCTAssertFalse(runtime.isListening)
        XCTAssertFalse(runtime.shouldReconnect)
    }

    func testAdvertisementTXTMetadataIsMinimalAndDoesNotExposeStableIdentity() {
        let config = LANAdvertisementConfig.internalPlaintext(
            port: 40484,
            discoveryID: LANDiscoveryID(rawValue: "ephemeral-disc")
        )

        XCTAssertEqual(config.serviceType, "_tomatt-sync._tcp")
        XCTAssertEqual(config.port, 40484)
        XCTAssertEqual(Set(config.txtMetadata.keys), LANTransportInternalPlaintext.allowedTXTKeys)
        XCTAssertEqual(config.txtMetadata["proto"], "tomatt-sync")
        XCTAssertEqual(config.txtMetadata["v"], "1")
        XCTAssertEqual(config.txtMetadata["transport"], "ws")
        XCTAssertEqual(config.txtMetadata["encoding"], "protobuf")
        XCTAssertEqual(config.txtMetadata["disc"], "ephemeral-disc")
        XCTAssertNil(config.txtMetadata["deviceId"])
        XCTAssertNil(config.txtMetadata["deviceID"])
        XCTAssertNil(config.txtMetadata["fingerprint"])
        XCTAssertNil(config.txtMetadata["displayName"])

        let decoded = LANAdvertisementConfig.metadata(fromTXTRecord: config.txtRecordData)
        XCTAssertEqual(Set(decoded.keys), LANTransportInternalPlaintext.allowedTXTKeys)
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

    func testManualEndpointValidationAcceptsLanIPAndTailscaleHostAndRejectsInvalidValues() throws {
        let ip = try LANManualEndpoint(host: "192.168.1.23")
        let tailscale = try LANManualEndpoint(host: "macbook.tailnet.ts.net", port: 40485)

        XCTAssertEqual(ip.host, "192.168.1.23")
        XCTAssertEqual(ip.port, 40484)
        XCTAssertEqual(ip.path, "/tomatt-sync")
        XCTAssertEqual(ip.websocketSubprotocol, "tomatt.sync.v1.protobuf")
        XCTAssertEqual(tailscale.host, "macbook.tailnet.ts.net")
        XCTAssertEqual(tailscale.port, 40485)

        XCTAssertThrowsError(try LANManualEndpoint(host: "")) { error in
            XCTAssertEqual(error as? LANManualEndpointValidationError, .emptyHost)
        }
        XCTAssertThrowsError(try LANManualEndpoint(host: "bad host")) { error in
            XCTAssertEqual(error as? LANManualEndpointValidationError, .invalidHost("bad host"))
        }
        XCTAssertThrowsError(try LANManualEndpoint(host: "192.168.1.23", port: 70000)) { error in
            XCTAssertEqual(error as? LANManualEndpointValidationError, .invalidPort(70000))
        }
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

    func testClientBoundaryRejectsWrongPathAndSubprotocolBeforeNetworkUse() throws {
        let client = URLSessionLANWebSocketClient()
        let wrongPath = try LANManualEndpoint(host: "192.168.1.23", path: "/wrong")
        let wrongSubprotocol = try LANManualEndpoint(host: "192.168.1.23", websocketSubprotocol: "json")

        let pathExpectation = expectation(description: "wrong path rejected")
        client.connect(to: wrongPath) { result in
            if case .failure(let error as LANTransportRuntimeError) = result {
                XCTAssertEqual(error, .invalidEndpoint("/wrong"))
            } else {
                XCTFail("Expected wrong path failure, got \(result)")
            }
            pathExpectation.fulfill()
        }

        let subprotocolExpectation = expectation(description: "wrong subprotocol rejected")
        client.connect(to: wrongSubprotocol) { result in
            if case .failure(let error as LANWebSocketHandshakeRejection) = result {
                XCTAssertEqual(error, .missingRequiredSubprotocol)
            } else {
                XCTFail("Expected wrong subprotocol failure, got \(result)")
            }
            subprotocolExpectation.fulfill()
        }

        wait(for: [pathExpectation, subprotocolExpectation], timeout: 1)
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

    func testBinaryEnvelopeRoundTripCarriesEncryptedLANPayload() throws {
        let encrypted = TBEncryptedLANMessage(protocolVersion: 1,
                                             senderDeviceID: "00000000-0000-0000-0000-000000000221",
                                             recipientDeviceID: "00000000-0000-0000-0000-000000000222",
                                             senderSigningKeyFingerprint: String(repeating: "c", count: 64),
                                             direction: .responderToInitiator,
                                             counter: 4,
                                             nonce: Data([1, 3, 5]),
                                             ciphertextAndTag: Data([2, 4, 6, 8]))
        let envelope = try TomattSyncProtoMapper.protoEnvelope(from: encrypted)
        let frame = try LANEnvelopeFrameCodec.encode(envelope)

        switch LANEnvelopeFrameCodec.decode(frame) {
        case .success(let decoded):
            XCTAssertEqual(try TomattSyncProtoMapper.encryptedLANMessage(from: decoded), encrypted)
        case .failure(let error):
            XCTFail("Expected encrypted decode success, got \(error)")
        }
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

    func testConnectionStateWiresHeartbeatAndReconnectBackoff() {
        let policy = LANHeartbeatBackoffPolicy(
            heartbeatInterval: 10,
            initialReconnectDelay: 2,
            maxReconnectDelay: 20,
            multiplier: 2,
            jitterFraction: 0
        )
        let now = Date(timeIntervalSince1970: 100)
        var state = LANConnectionState(
            peerID: "peer-a",
            direction: .outbound,
            establishedAt: now,
            reconnectAttempt: 0,
            nextHeartbeatAt: nil,
            nextReconnectAt: nil
        )

        state.markActive(now: now, policy: policy)
        XCTAssertEqual(state.nextHeartbeatAt, Date(timeIntervalSince1970: 110))
        XCTAssertNil(state.nextReconnectAt)

        state.markDisconnected(now: now, policy: policy)
        XCTAssertEqual(state.reconnectAttempt, 1)
        XCTAssertNil(state.nextHeartbeatAt)
        XCTAssertEqual(state.nextReconnectAt, Date(timeIntervalSince1970: 102))
    }

    func testDuplicateConnectionResolutionDefersBeforeVerifiedIdentity() {
        XCTAssertEqual(
            LANDuplicateConnectionResolver.resolveBeforeVerifiedIdentity(),
            .deferUntilVerifiedIdentity
        )
    }

    func testDuplicateConnectionTieBreakerAfterVerifiedIdentity() {
        let existing = LANConnectionState(
            peerID: "peer-a",
            direction: .outbound,
            establishedAt: Date(timeIntervalSince1970: 200),
            reconnectAttempt: 0,
            nextHeartbeatAt: nil,
            nextReconnectAt: nil
        )
        let olderCandidate = LANConnectionState(
            peerID: "peer-a",
            direction: .inbound,
            establishedAt: Date(timeIntervalSince1970: 100),
            reconnectAttempt: 0,
            nextHeartbeatAt: nil,
            nextReconnectAt: nil
        )
        let newerCandidate = LANConnectionState(
            peerID: "peer-a",
            direction: .inbound,
            establishedAt: Date(timeIntervalSince1970: 300),
            reconnectAttempt: 0,
            nextHeartbeatAt: nil,
            nextReconnectAt: nil
        )
        let sameTimeInboundCandidate = LANConnectionState(
            peerID: "peer-a",
            direction: .inbound,
            establishedAt: Date(timeIntervalSince1970: 200),
            reconnectAttempt: 0,
            nextHeartbeatAt: nil,
            nextReconnectAt: nil
        )

        XCTAssertEqual(
            LANDuplicateConnectionResolver.resolveAfterVerifiedIdentity(existing: existing, candidate: olderCandidate),
            .replaceExisting
        )
        XCTAssertEqual(
            LANDuplicateConnectionResolver.resolveAfterVerifiedIdentity(existing: existing, candidate: newerCandidate),
            .keepExisting
        )
        XCTAssertEqual(
            LANDuplicateConnectionResolver.resolveAfterVerifiedIdentity(existing: existing, candidate: sameTimeInboundCandidate),
            .replaceExisting
        )
    }

    func testStartStopStateModelStopsAdvertisingBrowsingListeningAndReconnectFlags() throws {
        let advertiser = FakeBonjourAdvertiser()
        let browser = FakeBonjourBrowser()
        let server = FakeWebSocketServer()
        let runtime = LANTransportRuntimeModel(
            config: try LANTransportConfig(),
            advertiser: advertiser,
            browser: browser,
            server: server
        )

        runtime.start(discoveryID: LANDiscoveryID(rawValue: "disc"))
        XCTAssertEqual(runtime.status, .active(port: 40484))
        XCTAssertTrue(runtime.isAdvertising)
        XCTAssertTrue(runtime.isBrowsing)
        XCTAssertTrue(runtime.isListening)
        XCTAssertTrue(runtime.shouldReconnect)

        runtime.markDisconnected(peerID: "peer", direction: .outbound, now: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(runtime.reconnectState(for: "peer"))

        runtime.stop()
        XCTAssertEqual(runtime.status, .stopped)
        XCTAssertFalse(runtime.isAdvertising)
        XCTAssertFalse(runtime.isBrowsing)
        XCTAssertFalse(runtime.isListening)
        XCTAssertFalse(runtime.shouldReconnect)
        XCTAssertNil(runtime.reconnectState(for: "peer"))
    }
}

private final class FakeBonjourAdvertiser: LANBonjourAdvertising {
    private(set) var isAdvertising = false

    func start(config: LANAdvertisementConfig) throws {
        isAdvertising = true
    }

    func stop() {
        isAdvertising = false
    }
}

private final class FakeBonjourBrowser: LANBonjourBrowsing {
    private(set) var isBrowsing = false
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)?

    func start() {
        isBrowsing = true
    }

    func stop() {
        isBrowsing = false
    }
}

private final class FakeWebSocketServer: LANWebSocketServing {
    private(set) var isListening = false
    var onSessionAccepted: ((LANWebSocketSession) -> Void)?
    let startError: Error?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(port: Int) throws {
        if let startError {
            throw startError
        }
        isListening = true
    }

    func stop() {
        isListening = false
    }
}

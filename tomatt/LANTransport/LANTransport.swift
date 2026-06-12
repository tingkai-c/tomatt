import Foundation
import SwiftProtobuf

/// Internal-only plaintext LAN transport skeleton for early protocol validation.
///
/// This layer advertises and moves protobuf envelopes only. It deliberately does
/// not import events, decide event validity, establish trust, or expose sync UI.
enum LANTransportInternalPlaintext {
    static let serviceType = "_tomatt-sync._tcp"
    static let endpointPath = "/tomatt-sync"
    static let websocketSubprotocol = "tomatt.sync.v1.protobuf"

    enum TXTKey {
        static let proto = "proto"
        static let version = "v"
        static let transport = "transport"
        static let encoding = "encoding"
        static let discoveryID = "disc"
    }

    static let allowedTXTKeys: Set<String> = [
        TXTKey.proto,
        TXTKey.version,
        TXTKey.transport,
        TXTKey.encoding,
        TXTKey.discoveryID,
    ]

    static let protoValue = "tomatt-sync"
    static let versionValue = "1"
    static let transportValue = "ws"
    static let encodingValue = "protobuf"
}

struct LANDiscoveryID: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func ephemeral(uuid: UUID = UUID()) -> LANDiscoveryID {
        LANDiscoveryID(rawValue: uuid.uuidString.lowercased())
    }
}

struct LANAdvertisementConfig: Equatable {
    let serviceType: String
    let port: Int
    let discoveryID: LANDiscoveryID
    let txtMetadata: [String: String]

    static func internalPlaintext(port: Int, discoveryID: LANDiscoveryID = .ephemeral()) -> LANAdvertisementConfig {
        let metadata = [
            LANTransportInternalPlaintext.TXTKey.proto: LANTransportInternalPlaintext.protoValue,
            LANTransportInternalPlaintext.TXTKey.version: LANTransportInternalPlaintext.versionValue,
            LANTransportInternalPlaintext.TXTKey.transport: LANTransportInternalPlaintext.transportValue,
            LANTransportInternalPlaintext.TXTKey.encoding: LANTransportInternalPlaintext.encodingValue,
            LANTransportInternalPlaintext.TXTKey.discoveryID: discoveryID.rawValue,
        ]

        return LANAdvertisementConfig(
            serviceType: LANTransportInternalPlaintext.serviceType,
            port: port,
            discoveryID: discoveryID,
            txtMetadata: metadata
        )
    }

    var txtRecordData: Data {
        NetService.data(fromTXTRecord: txtMetadata.mapValues { Data($0.utf8) })
    }
}

struct LANDiscoveredPeer: Equatable {
    let discoveryID: LANDiscoveryID
    let host: String
    let port: Int
    let metadata: [String: String]

    init?(host: String, port: Int, metadata: [String: String]) {
        guard let discoveryID = metadata[LANTransportInternalPlaintext.TXTKey.discoveryID],
              !discoveryID.isEmpty else {
            return nil
        }

        self.discoveryID = LANDiscoveryID(rawValue: discoveryID)
        self.host = host
        self.port = port
        self.metadata = metadata.filter { LANTransportInternalPlaintext.allowedTXTKeys.contains($0.key) }
    }
}

struct LANWebSocketHandshakeRequest: Equatable {
    let path: String
    let requestedSubprotocols: [String]
}

enum LANWebSocketHandshakeDecision: Equatable {
    case accept(subprotocol: String)
    case reject(LANWebSocketHandshakeRejection)
}

enum LANWebSocketHandshakeRejection: Equatable {
    case wrongPath
    case missingRequiredSubprotocol
}

enum LANWebSocketHandshakeValidator {
    static func validate(_ request: LANWebSocketHandshakeRequest) -> LANWebSocketHandshakeDecision {
        guard request.path == LANTransportInternalPlaintext.endpointPath else {
            return .reject(.wrongPath)
        }

        guard request.requestedSubprotocols.contains(LANTransportInternalPlaintext.websocketSubprotocol) else {
            return .reject(.missingRequiredSubprotocol)
        }

        return .accept(subprotocol: LANTransportInternalPlaintext.websocketSubprotocol)
    }
}

enum LANWebSocketFrame: Equatable {
    case binary(Data)
    case text(String)
}

enum LANEnvelopeFrameCodecError: Error, Equatable {
    case nonBinaryFrame
    case invalidProtobuf
}

enum LANEnvelopeFrameCodec {
    static func encode(_ envelope: Tomatt_Sync_V1_Envelope) throws -> LANWebSocketFrame {
        .binary(try envelope.serializedData())
    }

    static func decode(_ frame: LANWebSocketFrame) -> Result<Tomatt_Sync_V1_Envelope, LANEnvelopeFrameCodecError> {
        guard case .binary(let data) = frame else {
            return .failure(.nonBinaryFrame)
        }

        do {
            return .success(try Tomatt_Sync_V1_Envelope(serializedBytes: data))
        } catch {
            return .failure(.invalidProtobuf)
        }
    }
}

enum LANControlEnvelopeKind: Equatable {
    case hello(Tomatt_Sync_V1_Hello)
    case ping(Tomatt_Sync_V1_Ping)
    case pong(Tomatt_Sync_V1_Pong)
    case other
}

enum LANControlEnvelopeFactory {
    static func hello(
        messageID: String,
        deviceID: String = "",
        displayName: String = "",
        platform: String = "macOS",
        capabilities: [String] = []
    ) -> Tomatt_Sync_V1_Envelope {
        baseEnvelope(messageID: messageID, payload: .hello(Tomatt_Sync_V1_Hello.with {
            $0.deviceID = deviceID
            $0.displayName = displayName
            $0.platform = platform
            $0.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
            $0.protocolMinor = 0
            $0.capabilities = capabilities
        }))
    }

    static func ping(messageID: String, nonce: String) -> Tomatt_Sync_V1_Envelope {
        baseEnvelope(messageID: messageID, payload: .ping(Tomatt_Sync_V1_Ping.with {
            $0.nonce = nonce
        }))
    }

    static func pong(messageID: String, responseToMessageID: String, nonce: String) -> Tomatt_Sync_V1_Envelope {
        var envelope = baseEnvelope(messageID: messageID, payload: .pong(Tomatt_Sync_V1_Pong.with {
            $0.nonce = nonce
        }))
        envelope.responseToMessageID = responseToMessageID
        return envelope
    }

    static func controlKind(of envelope: Tomatt_Sync_V1_Envelope) -> LANControlEnvelopeKind {
        switch envelope.payload {
        case .hello(let hello):
            return .hello(hello)
        case .ping(let ping):
            return .ping(ping)
        case .pong(let pong):
            return .pong(pong)
        default:
            return .other
        }
    }

    private static func baseEnvelope(
        messageID: String,
        payload: Tomatt_Sync_V1_Envelope.OneOf_Payload
    ) -> Tomatt_Sync_V1_Envelope {
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = messageID
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.protocolMinor = 0
        envelope.payload = payload
        return envelope
    }
}

struct LANHeartbeatBackoffPolicy: Equatable {
    let heartbeatInterval: TimeInterval
    let initialReconnectDelay: TimeInterval
    let maxReconnectDelay: TimeInterval
    let multiplier: Double
    let jitterFraction: Double

    static let `default` = LANHeartbeatBackoffPolicy(
        heartbeatInterval: 15,
        initialReconnectDelay: 1,
        maxReconnectDelay: 60,
        multiplier: 2,
        jitterFraction: 0.2
    )

    func nextHeartbeat(after now: Date) -> Date {
        now.addingTimeInterval(heartbeatInterval)
    }

    func reconnectDelay(attempt: Int, jitterUnit: Double = 0.5) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let base = min(maxReconnectDelay, initialReconnectDelay * pow(multiplier, Double(exponent)))
        let clampedJitter = min(1, max(0, jitterUnit))
        let offset = (clampedJitter * 2) - 1
        return max(0, base + (base * jitterFraction * offset))
    }
}

enum LANDuplicateConnectionResolution: Equatable {
    case deferUntilVerifiedIdentity
}

enum LANDuplicateConnectionResolver {
    static func resolveBeforeVerifiedIdentity() -> LANDuplicateConnectionResolution {
        .deferUntilVerifiedIdentity
    }
}

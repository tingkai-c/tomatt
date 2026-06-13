import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import SwiftProtobuf

/// Internal-only plaintext LAN transport for early protocol validation.
///
/// This layer advertises and moves protobuf envelopes only. It deliberately does
/// not import events, decide event validity, authenticate peers, or expose sync UI.
enum LANTransportInternalPlaintext {
    static let defaultPort = 40484
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

struct LANTransportConfig: Equatable {
    let port: Int
    let endpointPath: String
    let websocketSubprotocol: String
    let heartbeatBackoffPolicy: LANHeartbeatBackoffPolicy

    init(
        port: Int = LANTransportInternalPlaintext.defaultPort,
        endpointPath: String = LANTransportInternalPlaintext.endpointPath,
        websocketSubprotocol: String = LANTransportInternalPlaintext.websocketSubprotocol,
        heartbeatBackoffPolicy: LANHeartbeatBackoffPolicy = .default
    ) throws {
        guard LANPort.isValid(port) else {
            throw LANTransportConfigurationError.invalidPort(port)
        }

        self.port = port
        self.endpointPath = endpointPath
        self.websocketSubprotocol = websocketSubprotocol
        self.heartbeatBackoffPolicy = heartbeatBackoffPolicy
    }
}

enum LANPort {
    static func isValid(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}

enum LANTransportConfigurationError: Error, Equatable {
    case invalidPort(Int)
}

enum LANTransportStatus: Equatable {
    case stopped
    case starting
    case active(port: Int)
    case failed(LANTransportRuntimeError)
}

enum LANTransportRuntimeError: Error, Equatable {
    case portUnavailable(port: Int)
    case invalidEndpoint(String)
    case serviceFailure(String)
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

    static func internalPlaintext(
        port: Int = LANTransportInternalPlaintext.defaultPort,
        discoveryID: LANDiscoveryID = .ephemeral()
    ) -> LANAdvertisementConfig {
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

    var sanitizedTXTMetadata: [String: String] {
        txtMetadata.filter { LANTransportInternalPlaintext.allowedTXTKeys.contains($0.key) }
    }

    static func metadata(fromTXTRecord data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, element in
            guard LANTransportInternalPlaintext.allowedTXTKeys.contains(element.key),
                  let value = String(data: element.value, encoding: .utf8) else {
                return
            }
            result[element.key] = value
        }
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

enum LANManualEndpointValidationError: Error, Equatable {
    case emptyHost
    case invalidHost(String)
    case invalidPort(Int)
}

struct LANManualEndpoint: Equatable {
    let host: String
    let port: Int
    let path: String
    let websocketSubprotocol: String

    init(
        host: String,
        port: Int = LANTransportInternalPlaintext.defaultPort,
        path: String = LANTransportInternalPlaintext.endpointPath,
        websocketSubprotocol: String = LANTransportInternalPlaintext.websocketSubprotocol
    ) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw LANManualEndpointValidationError.emptyHost }
        guard LANManualEndpoint.isValidHost(trimmedHost) else {
            throw LANManualEndpointValidationError.invalidHost(host)
        }
        guard LANPort.isValid(port) else { throw LANManualEndpointValidationError.invalidPort(port) }

        self.host = trimmedHost
        self.port = port
        self.path = path
        self.websocketSubprotocol = websocketSubprotocol
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.contains(" "), !host.contains("/"), !host.contains(":") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return true
    }
}

protocol LANBonjourAdvertising: AnyObject {
    var isAdvertising: Bool { get }
    func start(config: LANAdvertisementConfig) throws
    func stop()
}

protocol LANBonjourBrowsing: AnyObject {
    var isBrowsing: Bool { get }
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)? { get set }
    func start()
    func stop()
}

final class NetServiceLANBonjourAdvertiser: NSObject, LANBonjourAdvertising, NetServiceDelegate {
    private var service: NetService?
    private(set) var isAdvertising = false

    func start(config: LANAdvertisementConfig) throws {
        stop()

        let service = NetService(
            domain: "local.",
            type: config.serviceType,
            name: Host.current().localizedName ?? "tomatt",
            port: Int32(config.port)
        )
        service.delegate = self
        service.setTXTRecord(config.txtRecordData)
        self.service = service
        isAdvertising = true
        service.publish()
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        isAdvertising = false
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        isAdvertising = false
    }
}

final class NetServiceLANBonjourBrowser: NSObject, LANBonjourBrowsing, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private(set) var isBrowsing = false
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.searchForServices(ofType: LANTransportInternalPlaintext.serviceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolvingServices.forEach { service in
            service.stop()
            service.delegate = nil
        }
        resolvingServices.removeAll()
        isBrowsing = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let metadata = LANAdvertisementConfig.metadata(fromTXTRecord: sender.txtRecordData() ?? Data())
        let host = sender.hostName ?? sender.name
        if let peer = LANDiscoveredPeer(host: host, port: sender.port, metadata: metadata) {
            onPeerDiscovered?(peer)
        }
        resolvingServices.removeAll { $0 === sender }
        sender.delegate = nil
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.removeAll { $0 === sender }
        sender.delegate = nil
    }
}

struct LANWebSocketHandshakeRequest: Equatable {
    let path: String
    let requestedSubprotocols: [String]
}

protocol LANWebSocketSession: AnyObject {
    var endpointDescription: String { get }
    var onEnvelopeReceived: ((Tomatt_Sync_V1_Envelope) -> Void)? { get set }
    func send(_ envelope: Tomatt_Sync_V1_Envelope, completion: @escaping (Result<Void, Error>) -> Void)
    func close()
}

protocol LANWebSocketServing: AnyObject {
    var isListening: Bool { get }
    var onSessionAccepted: ((LANWebSocketSession) -> Void)? { get set }
    func start(port: Int) throws
    func stop()
}

protocol LANWebSocketConnecting: AnyObject {
    func connect(to endpoint: LANManualEndpoint, completion: @escaping (Result<LANWebSocketSession, Error>) -> Void)
}

final class LANWebSocketServerBoundary: LANWebSocketServing {
    private let server = NIOWebSocketLANServer()
    var onSessionAccepted: ((LANWebSocketSession) -> Void)? {
        get { server.onSessionAccepted }
        set { server.onSessionAccepted = newValue }
    }
    var isListening: Bool { server.isListening }

    func start(port: Int) throws {
        try server.start(port: port)
    }

    func stop() {
        server.stop()
    }
}

final class NIOWebSocketLANServer: LANWebSocketServing {
    private let group: EventLoopGroup
    private var channel: Channel?
    private(set) var isListening = false
    var onSessionAccepted: ((LANWebSocketSession) -> Void)?

    init(group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)) {
        self.group = group
    }

    func start(port: Int) throws {
        guard LANPort.isValid(port) else { throw LANTransportConfigurationError.invalidPort(port) }
        stop()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeSucceededFuture(()) }
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        guard head.uri == LANTransportInternalPlaintext.endpointPath,
                              Self.requestedSubprotocols(from: head.headers).contains(LANTransportInternalPlaintext.websocketSubprotocol) else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                        var headers = HTTPHeaders()
                        headers.add(name: "Sec-WebSocket-Protocol", value: LANTransportInternalPlaintext.websocketSubprotocol)
                        return channel.eventLoop.makeSucceededFuture(headers)
                    },
                    upgradePipelineHandler: { channel, _ in
                        let session = NIOWebSocketLANSession(channel: channel,
                                                            endpointDescription: channel.remoteAddress.map(String.init(describing:)) ?? "nio-websocket-peer")
                        self.onSessionAccepted?(session)
                        return channel.pipeline.addHandler(NIOWebSocketLANFrameHandler(session: session))
                    }
                )
                let upgradeConfig = NIOHTTPServerUpgradeConfiguration(upgraders: [upgrader], completionHandler: { _ in })
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
            }

        do {
            channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
            isListening = true
        } catch {
            isListening = false
            if String(describing: error).lowercased().contains("address already in use") {
                throw LANTransportRuntimeError.portUnavailable(port: port)
            }
            throw LANTransportRuntimeError.serviceFailure(String(describing: error))
        }
    }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        isListening = false
    }

    private static func requestedSubprotocols(from headers: HTTPHeaders) -> [String] {
        headers["Sec-WebSocket-Protocol"]
            .flatMap { headerValue in
                headerValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
    }

    deinit {
        stop()
        try? group.syncShutdownGracefully()
    }
}

final class NIOWebSocketLANSession: LANWebSocketSession {
    private let channel: Channel
    let endpointDescription: String
    var onEnvelopeReceived: ((Tomatt_Sync_V1_Envelope) -> Void)?

    init(channel: Channel, endpointDescription: String) {
        self.channel = channel
        self.endpointDescription = endpointDescription
    }

    func send(_ envelope: Tomatt_Sync_V1_Envelope, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let frame = try LANEnvelopeFrameCodec.encode(envelope)
            guard case .binary(let data) = frame else {
                completion(.failure(LANEnvelopeFrameCodecError.nonBinaryFrame))
                return
            }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer)).whenComplete { result in
                completion(result.map { _ in () })
            }
        } catch {
            completion(.failure(error))
        }
    }

    func close() {
        _ = channel.close()
    }
}

private final class NIOWebSocketLANFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let session: NIOWebSocketLANSession

    init(session: NIOWebSocketLANSession) {
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var data = frame.data
        switch frame.opcode {
        case .binary:
            let bytes = data.readBytes(length: data.readableBytes) ?? []
            if case .success(let envelope) = LANEnvelopeFrameCodec.decode(.binary(Data(bytes))) {
                session.onEnvelopeReceived?(envelope)
            }
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: data)), promise: nil)
        default:
            break
        }
    }
}

final class URLSessionLANWebSocketClient: LANWebSocketConnecting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(to endpoint: LANManualEndpoint, completion: @escaping (Result<LANWebSocketSession, Error>) -> Void) {
        guard endpoint.path == LANTransportInternalPlaintext.endpointPath else {
            completion(.failure(LANTransportRuntimeError.invalidEndpoint(endpoint.path)))
            return
        }
        guard endpoint.websocketSubprotocol == LANTransportInternalPlaintext.websocketSubprotocol else {
            completion(.failure(LANWebSocketHandshakeRejection.missingRequiredSubprotocol))
            return
        }
        guard let url = endpoint.url else {
            completion(.failure(LANTransportRuntimeError.invalidEndpoint(endpoint.host)))
            return
        }

        let task = session.webSocketTask(with: url, protocols: [endpoint.websocketSubprotocol])
        let webSocketSession = URLSessionLANWebSocketSession(task: task, endpointDescription: url.absoluteString)
        task.resume()
        webSocketSession.receiveLoop()
        completion(.success(webSocketSession))
    }
}

final class URLSessionLANWebSocketSession: LANWebSocketSession {
    private let task: URLSessionWebSocketTask
    let endpointDescription: String
    var onEnvelopeReceived: ((Tomatt_Sync_V1_Envelope) -> Void)?

    init(task: URLSessionWebSocketTask, endpointDescription: String) {
        self.task = task
        self.endpointDescription = endpointDescription
    }

    func send(_ envelope: Tomatt_Sync_V1_Envelope, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let frame = try LANEnvelopeFrameCodec.encode(envelope)
            guard case .binary(let data) = frame else {
                completion(.failure(LANEnvelopeFrameCodecError.nonBinaryFrame))
                return
            }
            task.send(.data(data), completionHandler: { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            })
        } catch {
            completion(.failure(error))
        }
    }

    func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                if case .success(let envelope) = LANEnvelopeFrameCodec.decode(.binary(data)) {
                    self.onEnvelopeReceived?(envelope)
                }
                self.receiveLoop()
            case .success(.string(let string)):
                _ = LANEnvelopeFrameCodec.decode(.text(string))
                self.receiveLoop()
            case .failure:
                return
            @unknown default:
                return
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

enum LANWebSocketHandshakeDecision: Equatable {
    case accept(subprotocol: String)
    case reject(LANWebSocketHandshakeRejection)
}

enum LANWebSocketHandshakeRejection: Equatable {
    case wrongPath
    case missingRequiredSubprotocol
}

extension LANWebSocketHandshakeRejection: Error {}

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

struct LANConnectionState: Equatable {
    let peerID: String
    let direction: LANDuplicateConnectionDirection
    let establishedAt: Date
    var reconnectAttempt: Int
    var nextHeartbeatAt: Date?
    var nextReconnectAt: Date?

    mutating func markActive(now: Date, policy: LANHeartbeatBackoffPolicy) {
        reconnectAttempt = 0
        nextHeartbeatAt = policy.nextHeartbeat(after: now)
        nextReconnectAt = nil
    }

    mutating func markDisconnected(now: Date, policy: LANHeartbeatBackoffPolicy, jitterUnit: Double = 0.5) {
        reconnectAttempt += 1
        nextHeartbeatAt = nil
        nextReconnectAt = now.addingTimeInterval(policy.reconnectDelay(attempt: reconnectAttempt, jitterUnit: jitterUnit))
    }
}

enum LANDuplicateConnectionDirection: String, Equatable, Comparable {
    case inbound
    case outbound

    static func < (lhs: LANDuplicateConnectionDirection, rhs: LANDuplicateConnectionDirection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum LANDuplicateConnectionResolution: Equatable {
    case deferUntilVerifiedIdentity
    case keepExisting
    case replaceExisting
}

enum LANDuplicateConnectionResolver {
    static func resolveBeforeVerifiedIdentity() -> LANDuplicateConnectionResolution {
        .deferUntilVerifiedIdentity
    }

    static func resolveAfterVerifiedIdentity(existing: LANConnectionState, candidate: LANConnectionState) -> LANDuplicateConnectionResolution {
        guard existing.peerID == candidate.peerID else {
            return .keepExisting
        }

        if candidate.establishedAt < existing.establishedAt {
            return .replaceExisting
        }
        if candidate.establishedAt > existing.establishedAt {
            return .keepExisting
        }
        if candidate.direction < existing.direction {
            return .replaceExisting
        }
        return .keepExisting
    }
}

final class LANTransportRuntimeModel {
    private let config: LANTransportConfig
    private let advertiser: LANBonjourAdvertising
    private let browser: LANBonjourBrowsing
    private let server: LANWebSocketServing
    private var reconnectStates: [String: LANConnectionState] = [:]

    private(set) var status: LANTransportStatus = .stopped
    private(set) var shouldReconnect = false

    var isAdvertising: Bool { advertiser.isAdvertising }
    var isBrowsing: Bool { browser.isBrowsing }
    var isListening: Bool { server.isListening }
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)? {
        get { browser.onPeerDiscovered }
        set { browser.onPeerDiscovered = newValue }
    }

    init(
        config: LANTransportConfig,
        advertiser: LANBonjourAdvertising,
        browser: LANBonjourBrowsing,
        server: LANWebSocketServing
    ) {
        self.config = config
        self.advertiser = advertiser
        self.browser = browser
        self.server = server
    }

    func start(discoveryID: LANDiscoveryID = .ephemeral()) {
        status = .starting
        shouldReconnect = true

        do {
            try advertiser.start(config: .internalPlaintext(port: config.port, discoveryID: discoveryID))
            browser.start()
            try server.start(port: config.port)
            status = .active(port: config.port)
        } catch let error as LANTransportRuntimeError {
            stop()
            status = .failed(error)
        } catch let error as LANTransportConfigurationError {
            stop()
            if case .invalidPort(let port) = error {
                status = .failed(.portUnavailable(port: port))
            } else {
                status = .failed(.serviceFailure(String(describing: error)))
            }
        } catch {
            stop()
            status = .failed(.serviceFailure(String(describing: error)))
        }
    }

    func stop() {
        shouldReconnect = false
        reconnectStates.removeAll()
        advertiser.stop()
        browser.stop()
        server.stop()
        status = .stopped
    }

    func markDisconnected(peerID: String, direction: LANDuplicateConnectionDirection, now: Date, jitterUnit: Double = 0.5) {
        var state = reconnectStates[peerID] ?? LANConnectionState(
            peerID: peerID,
            direction: direction,
            establishedAt: now,
            reconnectAttempt: 0,
            nextHeartbeatAt: nil,
            nextReconnectAt: nil
        )
        state.markDisconnected(now: now, policy: config.heartbeatBackoffPolicy, jitterUnit: jitterUnit)
        reconnectStates[peerID] = state
        shouldReconnect = true
    }

    func reconnectState(for peerID: String) -> LANConnectionState? {
        reconnectStates[peerID]
    }
}

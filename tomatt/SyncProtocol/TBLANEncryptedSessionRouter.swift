import Foundation

enum TBLANEncryptedSessionAdmissionFailure: Equatable {
    case untrustedPeer(String)
    case removedPeer(String)
    case badFingerprint(String)
    case wrongGroup(String)
    case notReady(String)
}

struct TBLANEncryptedSessionContext: Equatable {
    let peerID: String
    let displayName: String
    let sessionKeyID: String
    let sessionNonceSeed: Data
    let peerRole: TBSyncSessionRole
    let syncGroupID: String
}

protocol TBLANEncryptedSessionAdmitting: AnyObject {
    func admitResume(hello: Tomatt_Sync_V1_Hello) -> Result<TBLANEncryptedSessionContext, TBLANEncryptedSessionAdmissionFailure>
    func sessionContext(for peerID: String) -> TBLANEncryptedSessionContext?
    func localResumeHello(for peerID: String) -> Tomatt_Sync_V1_Hello?
    func retainOutboundResumeHello(_ hello: Tomatt_Sync_V1_Hello, for peerID: String)
    func prepareOutboundResume(peerID: String) -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure>
    func prepareAnyOutboundResume() -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure>
}

extension TBLANEncryptedSessionAdmitting {
    func localResumeHello(for peerID: String) -> Tomatt_Sync_V1_Hello? { nil }
    func retainOutboundResumeHello(_ hello: Tomatt_Sync_V1_Hello, for peerID: String) {}
    func prepareOutboundResume(peerID: String) -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        .failure(.notReady("Outbound resume is unavailable"))
    }
    func prepareAnyOutboundResume() -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        .failure(.notReady("Outbound resume is unavailable"))
    }
}

protocol TBLANEncryptedSessionCoordinating: AnyObject {
    func triggerConnectionEstablishedSync(deviceID: String) -> [TBEncryptedLANMessage]
    func receive(_ message: TBEncryptedLANMessage, from deviceID: String) -> [TBEncryptedLANMessage]
}

extension TBSyncRuntimeCoordinator: TBLANEncryptedSessionCoordinating {}

protocol TBLANEncryptedSessionStatusSinking: AnyObject {
    func sessionRejected(peerID: String?, state: TBSyncPeerRuntimeState, reason: String)
    func sendFailed(peerID: String, direction: LANDuplicateConnectionDirection, error: Error)
}

enum TBLANEncryptedSessionRouterError: Error, Equatable {
    case invalidHelloMetadata(String)
    case encryptedFrameBeforeResume
    case nonResumePayloadBeforeResume
    case unboundPeer(String)
    case mapperFailure(String)
    case peerMismatch(expected: String, actual: String)
}

@MainActor
final class TBLANEncryptedSessionRouter {
    private struct BoundSession {
        let session: LANWebSocketSession
        let context: TBLANEncryptedSessionContext
        let connectionState: LANConnectionState
    }

    private let admission: TBLANEncryptedSessionAdmitting
    private let coordinator: TBLANEncryptedSessionCoordinating
    private weak var statusSink: TBLANEncryptedSessionStatusSinking?
    private let now: () -> Date

    private var anonymousSessions: [ObjectIdentifier: LANWebSocketSession] = [:]
    private var anonymousOutboundLocalHellos: [ObjectIdentifier: Tomatt_Sync_V1_Hello] = [:]
    private var pendingContexts: [String: TBLANEncryptedSessionContext] = [:]
    private var boundSessions: [String: BoundSession] = [:]
    var pairingEnvelopeHandler: ((Tomatt_Sync_V1_Envelope, LANWebSocketSession) -> Bool)?

    init(admission: TBLANEncryptedSessionAdmitting,
         coordinator: TBLANEncryptedSessionCoordinating,
         statusSink: TBLANEncryptedSessionStatusSinking? = nil,
         now: @escaping () -> Date = Date.init) {
        self.admission = admission
        self.coordinator = coordinator
        self.statusSink = statusSink
        self.now = now
    }

    func admit(session: LANWebSocketSession) {
        anonymousSessions[ObjectIdentifier(session)] = session
        session.onEnvelopeReceived = { [weak self, weak session] envelope in
            guard let self, let session else { return }
            Task { @MainActor in
                self.handleEnvelope(envelope, from: session)
            }
        }
    }

    func setSessionContext(_ context: TBLANEncryptedSessionContext) {
        pendingContexts[context.peerID] = context
    }

    @discardableResult
    func initiateOutboundResume(session: LANWebSocketSession, peerID: String) -> Bool {
        switch admission.prepareOutboundResume(peerID: peerID) {
        case .success(let hello):
            admit(session: session)
            anonymousOutboundLocalHellos[ObjectIdentifier(session)] = hello
            var envelope = Tomatt_Sync_V1_Envelope()
            envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
            envelope.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
            envelope.hello = hello
            session.send(envelope) { _ in }
            return true
        case .failure(let failure):
            reject(session: session,
                   peerID: peerID,
                   state: runtimeState(for: failure),
                   reason: String(describing: failure))
            return false
        }
    }

    @discardableResult
    func initiateOutboundResume(session: LANWebSocketSession) -> Bool {
        switch admission.prepareAnyOutboundResume() {
        case .success(let hello):
            admit(session: session)
            anonymousOutboundLocalHellos[ObjectIdentifier(session)] = hello
            var envelope = Tomatt_Sync_V1_Envelope()
            envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
            envelope.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
            envelope.hello = hello
            session.send(envelope) { _ in }
            return true
        case .failure(let failure):
            reject(session: session,
                   peerID: nil,
                   state: runtimeState(for: failure),
                   reason: String(describing: failure))
            return false
        }
    }

    func resetRuntimeState() {
        anonymousSessions.values.forEach { $0.close() }
        boundSessions.values.forEach { $0.session.close() }
        anonymousSessions.removeAll()
        anonymousOutboundLocalHellos.removeAll()
        pendingContexts.removeAll()
        boundSessions.removeAll()
    }

    func bind(session: LANWebSocketSession,
              to peerID: String,
              direction: LANDuplicateConnectionDirection,
              establishedAt: Date) {
        guard let context = pendingContexts.removeValue(forKey: peerID) ?? admission.sessionContext(for: peerID) else {
            reject(session: session,
                   peerID: peerID,
                   state: .blocked("No admitted encrypted LAN session context"),
                   reason: "No admitted encrypted LAN session context")
            return
        }
        anonymousSessions.removeValue(forKey: ObjectIdentifier(session))

        let candidateState = LANConnectionState(peerID: peerID,
                                                direction: direction,
                                                establishedAt: establishedAt,
                                                reconnectAttempt: 0,
                                                nextHeartbeatAt: nil,
                                                nextReconnectAt: nil)
        let candidate = BoundSession(session: session, context: context, connectionState: candidateState)

        if let existing = boundSessions[peerID] {
            switch LANDuplicateConnectionResolver.resolveAfterVerifiedIdentity(existing: existing.connectionState,
                                                                               candidate: candidateState) {
            case .replaceExisting:
                existing.session.close()
                boundSessions[peerID] = candidate
            case .keepExisting, .deferUntilVerifiedIdentity:
                session.close()
                return
            }
        } else {
            boundSessions[peerID] = candidate
        }

        session.onEnvelopeReceived = { [weak self, weak session] envelope in
            guard let self, let session else { return }
            Task { @MainActor in
                self.handleEnvelope(envelope, from: session)
            }
        }
    }

    func unbind(peerID: String) {
        boundSessions.removeValue(forKey: peerID)?.session.close()
        pendingContexts.removeValue(forKey: peerID)
    }

    func boundContext(for peerID: String) -> TBLANEncryptedSessionContext? {
        boundSessions[peerID]?.context
    }

    func send(messages: [TBEncryptedLANMessage], to peerID: String) {
        guard let binding = boundSessions[peerID] else {
            statusSink?.sessionRejected(peerID: peerID,
                                        state: .retryScheduled(now()),
                                        reason: "No encrypted LAN session bound for peer")
            return
        }

        for message in messages {
            send(message: message, to: peerID, binding: binding)
        }
    }

    func handleEnvelope(_ envelope: Tomatt_Sync_V1_Envelope, from session: LANWebSocketSession) {
        if let peerID = boundPeerID(for: session) {
            handleBoundEnvelope(envelope, from: session, peerID: peerID)
            return
        }

        handleAnonymousEnvelope(envelope, from: session)
    }

    private func handleAnonymousEnvelope(_ envelope: Tomatt_Sync_V1_Envelope, from session: LANWebSocketSession) {
        guard TomattSyncProtocolV1.isCompatibleEnvelope(envelope) else {
            reject(session: session,
                   peerID: nil,
                   state: .blocked("Unsupported protocol envelope version"),
                   reason: String(describing: TBLANEncryptedSessionRouterError.invalidHelloMetadata("envelope_protocol_version")))
            return
        }

        guard case .hello(let hello)? = envelope.payload else {
            if pairingEnvelopeHandler?(envelope, session) == true { return }
            if case .encryptedLanMessage? = envelope.payload {
                reject(session: session,
                       peerID: nil,
                       state: .blocked("Encrypted LAN payload received before trusted resume"),
                       reason: "Encrypted LAN payload received before trusted resume")
            } else {
                reject(session: session,
                       peerID: nil,
                       state: .blocked("Non-resume payload received before trusted resume"),
                       reason: "Non-resume payload received before trusted resume")
            }
            return
        }

        do {
            try validateResumeHello(hello)
        } catch {
            reject(session: session,
                   peerID: hello.deviceID.isEmpty ? nil : hello.deviceID,
                   state: .blocked(String(describing: error)),
                   reason: String(describing: error))
            return
        }

        if let originalLocalHello = anonymousOutboundLocalHellos[ObjectIdentifier(session)] {
            admission.retainOutboundResumeHello(originalLocalHello, for: hello.deviceID)
        }

        switch admission.admitResume(hello: hello) {
        case .success(let context):
            anonymousOutboundLocalHellos.removeValue(forKey: ObjectIdentifier(session))
            pendingContexts[context.peerID] = context
            bind(session: session, to: context.peerID, direction: .inbound, establishedAt: now())
            if let localHello = admission.localResumeHello(for: context.peerID) {
                var envelope = Tomatt_Sync_V1_Envelope()
                envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
                envelope.hello = localHello
                session.send(envelope) { _ in }
            }
            send(messages: coordinator.triggerConnectionEstablishedSync(deviceID: context.peerID), to: context.peerID)
        case .failure(let failure):
            let state = runtimeState(for: failure)
            reject(session: session,
                   peerID: hello.deviceID,
                   state: state,
                   reason: String(describing: failure))
        }
    }

    private func handleBoundEnvelope(_ envelope: Tomatt_Sync_V1_Envelope,
                                     from session: LANWebSocketSession,
                                     peerID: String) {
        do {
            let message = try TomattSyncProtoMapper.encryptedLANMessage(from: envelope)
            guard message.senderDeviceID == peerID else {
                throw TBLANEncryptedSessionRouterError.peerMismatch(expected: peerID, actual: message.senderDeviceID)
            }
            let responses = coordinator.receive(message, from: peerID)
            send(messages: responses, to: peerID)
        } catch {
            reject(session: session,
                   peerID: peerID,
                   state: .blocked("Invalid encrypted LAN payload"),
                   reason: String(describing: error))
            boundSessions.removeValue(forKey: peerID)
        }
    }

    private func send(message: TBEncryptedLANMessage, to peerID: String, binding: BoundSession) {
        do {
            let envelope = try TomattSyncProtoMapper.protoEnvelope(from: message)
            binding.session.send(envelope) { [weak self] result in
                guard case .failure(let error) = result else { return }
                Task { @MainActor in
                    self?.statusSink?.sendFailed(peerID: peerID,
                                                 direction: binding.connectionState.direction,
                                                 error: error)
                }
            }
        } catch {
            statusSink?.sendFailed(peerID: peerID, direction: binding.connectionState.direction, error: error)
        }
    }

    private func boundPeerID(for session: LANWebSocketSession) -> String? {
        boundSessions.first { ObjectIdentifier($0.value.session) == ObjectIdentifier(session) }?.key
    }

    private func reject(session: LANWebSocketSession,
                        peerID: String?,
                        state: TBSyncPeerRuntimeState,
                        reason: String) {
        session.close()
        anonymousSessions.removeValue(forKey: ObjectIdentifier(session))
        anonymousOutboundLocalHellos.removeValue(forKey: ObjectIdentifier(session))
        statusSink?.sessionRejected(peerID: peerID, state: state, reason: reason)
    }

    private func validateResumeHello(_ hello: Tomatt_Sync_V1_Hello) throws {
        guard TomattSyncProtocolV1.isCompatibleHello(hello) else {
            throw TBLANEncryptedSessionRouterError.invalidHelloMetadata("protocol_version")
        }
        guard TomattSyncProtocolV1.isCanonicalLowercaseUUIDString(hello.deviceID) else {
            throw TBLANEncryptedSessionRouterError.invalidHelloMetadata("device_id")
        }
        guard !hello.sessionKeyID.isEmpty else {
            throw TBLANEncryptedSessionRouterError.invalidHelloMetadata("session_key_id")
        }
        guard hello.sessionNonceSeed.count == 32 else {
            throw TBLANEncryptedSessionRouterError.invalidHelloMetadata("session_nonce_seed")
        }
        guard hello.sessionRole == .initiator || hello.sessionRole == .responder else {
            throw TBLANEncryptedSessionRouterError.invalidHelloMetadata("session_role")
        }
        guard !hello.syncGroupID.isEmpty else {
            throw TBLANEncryptedSessionRouterError.invalidHelloMetadata("sync_group_id")
        }
    }

    private func runtimeState(for failure: TBLANEncryptedSessionAdmissionFailure) -> TBSyncPeerRuntimeState {
        switch failure {
        case .removedPeer:
            return .removed
        case .untrustedPeer(let reason),
             .badFingerprint(let reason),
             .wrongGroup(let reason),
             .notReady(let reason):
            return .blocked(reason)
        }
    }
}

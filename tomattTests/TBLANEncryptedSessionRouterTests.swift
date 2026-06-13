import Foundation
import XCTest

@MainActor
final class TBLANEncryptedSessionRouterTests: XCTestCase {
    private let peerID = "00000000-0000-0000-0000-000000000301"
    private let localID = "00000000-0000-0000-0000-000000000302"

    func testTrustedAnonymousResumeBindsAndRoutesEncryptedPayload() throws {
        let session = FakeLANWebSocketSession()
        let response = encryptedMessage(sender: localID, recipient: peerID, counter: 2)
        let coordinator = FakeRouterCoordinator(responses: [response])
        let router = makeRouter(coordinator: coordinator)

        router.admit(session: session)
        router.handleEnvelope(helloEnvelope(), from: session)
        router.handleEnvelope(try TomattSyncProtoMapper.protoEnvelope(from: encryptedMessage()), from: session)

        XCTAssertFalse(session.isClosed)
        XCTAssertEqual(coordinator.receivedMessages.map(\.senderDeviceID), [peerID])
        XCTAssertEqual(session.sentEnvelopes.count, 1)
        XCTAssertEqual(try TomattSyncProtoMapper.encryptedLANMessage(from: session.sentEnvelopes[0]), response)
    }

    func testEncryptedFirstFrameIsRejected() throws {
        let session = FakeLANWebSocketSession()
        let status = FakeRouterStatusSink()
        let router = makeRouter(statusSink: status)

        router.admit(session: session)
        router.handleEnvelope(try TomattSyncProtoMapper.protoEnvelope(from: encryptedMessage()), from: session)

        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(status.rejections.count, 1)
        XCTAssertEqual(status.rejections[0].peerID, nil)
        XCTAssertEqual(status.rejections[0].state, .blocked("Encrypted LAN payload received before trusted resume"))
    }

    func testUntrustedAndRemovedResumeAreRejected() {
        let untrusted = FakeLANWebSocketSession(endpointDescription: "untrusted")
        let removed = FakeLANWebSocketSession(endpointDescription: "removed")
        let status = FakeRouterStatusSink()
        let admission = FakeRouterAdmission(context: context())
        admission.result = .failure(.untrustedPeer("not trusted"))
        let router = makeRouter(admission: admission, statusSink: status)

        router.admit(session: untrusted)
        router.handleEnvelope(helloEnvelope(), from: untrusted)
        admission.result = .failure(.removedPeer("removed"))
        router.admit(session: removed)
        router.handleEnvelope(helloEnvelope(), from: removed)

        XCTAssertTrue(untrusted.isClosed)
        XCTAssertTrue(removed.isClosed)
        XCTAssertEqual(status.rejections.map(\.state), [.blocked("not trusted"), .removed])
    }

    func testNonResumeAnonymousPayloadIsRejected() {
        let session = FakeLANWebSocketSession()
        let status = FakeRouterStatusSink()
        let router = makeRouter(statusSink: status)

        router.admit(session: session)
        router.handleEnvelope(LANControlEnvelopeFactory.ping(messageID: "ping", nonce: "n"), from: session)

        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(status.rejections[0].state, .blocked("Non-resume payload received before trusted resume"))
    }

    func testResumeHelloRejectsUnsupportedProtocolVersionsBeforeAdmission() {
        let session = FakeLANWebSocketSession()
        let status = FakeRouterStatusSink()
        let admission = FakeRouterAdmission(context: context())
        let router = makeRouter(admission: admission, statusSink: status)
        var envelope = helloEnvelope()
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion + 1

        router.admit(session: session)
        router.handleEnvelope(envelope, from: session)

        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(admission.admitCount, 0)
        XCTAssertEqual(status.rejections[0].state, .blocked("Unsupported protocol envelope version"))
    }

    func testOutboundResumeSendsLocalHelloAndWaitsForPeerHello() {
        let session = FakeLANWebSocketSession()
        let admission = FakeRouterAdmission(context: context())
        var outboundHello = helloEnvelope().hello
        outboundHello.deviceID = localID
        admission.outboundHello = outboundHello
        let router = makeRouter(admission: admission)

        XCTAssertTrue(router.initiateOutboundResume(session: session, peerID: peerID))

        XCTAssertFalse(session.isClosed)
        XCTAssertEqual(session.sentEnvelopes.count, 1)
        XCTAssertEqual(session.sentEnvelopes[0].hello.deviceID, localID)
    }

    func testAnonymousOutboundResumeSendsLocalHelloAndPeerIdentityIsValidatedFromPeerHello() {
        let session = FakeLANWebSocketSession()
        let admission = FakeRouterAdmission(context: context())
        var outboundHello = helloEnvelope().hello
        outboundHello.deviceID = localID
        admission.anyOutboundHello = outboundHello
        let router = makeRouter(admission: admission)

        XCTAssertTrue(router.initiateOutboundResume(session: session))
        router.handleEnvelope(helloEnvelope(), from: session)

        XCTAssertFalse(session.isClosed)
        XCTAssertEqual(session.sentEnvelopes.first?.hello.deviceID, localID)
        XCTAssertEqual(admission.admittedDeviceIDs, [peerID])
    }

    func testAnonymousOutboundResumeRetainsOriginalLocalHelloForIdentifiedPeer() {
        let session = FakeLANWebSocketSession()
        let admission = FakeRouterAdmission(context: context())
        var outboundHello = helloEnvelope().hello
        outboundHello.deviceID = localID
        outboundHello.sessionNonceSeed = Data(repeating: 7, count: 32)
        admission.anyOutboundHello = outboundHello
        let router = makeRouter(admission: admission)

        XCTAssertTrue(router.initiateOutboundResume(session: session))
        router.handleEnvelope(helloEnvelope(), from: session)

        XCTAssertEqual(admission.retainedOutboundHellos[peerID]?.sessionNonceSeed, Data(repeating: 7, count: 32))
        XCTAssertEqual(session.sentEnvelopes.first?.hello.sessionNonceSeed, Data(repeating: 7, count: 32))
    }

    func testPairingPayloadCanBeRoutedBeforeResumeWhenHandlerAcceptsIt() {
        let session = FakeLANWebSocketSession()
        let router = makeRouter()
        var routed = false
        router.pairingEnvelopeHandler = { envelope, routedSession in
            if case .pairingStart? = envelope.payload,
               ObjectIdentifier(routedSession) == ObjectIdentifier(session) {
                routed = true
            }
            return true
        }
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.pairingStart = Tomatt_Sync_V1_PairingStart.with { $0.deviceID = "peer" }

        router.admit(session: session)
        router.handleEnvelope(envelope, from: session)

        XCTAssertTrue(routed)
        XCTAssertFalse(session.isClosed)
    }

    func testSendWrapsMessagesToBoundSession() throws {
        let session = FakeLANWebSocketSession()
        let router = makeRouter()
        let outbound = encryptedMessage(sender: localID, recipient: peerID, counter: 7)

        router.admit(session: session)
        router.handleEnvelope(helloEnvelope(), from: session)
        router.send(messages: [outbound], to: peerID)

        XCTAssertEqual(session.sentEnvelopes.count, 1)
        XCTAssertEqual(try TomattSyncProtoMapper.encryptedLANMessage(from: session.sentEnvelopes[0]), outbound)
    }

    func testDuplicateBindingResolutionReplacesOlderExistingAndKeepsOlderCandidate() {
        let oldSession = FakeLANWebSocketSession(endpointDescription: "old")
        let newSession = FakeLANWebSocketSession(endpointDescription: "new")
        let keepSession = FakeLANWebSocketSession(endpointDescription: "keep")
        let admission = FakeRouterAdmission(context: context())
        let router = makeRouter(admission: admission)

        router.bind(session: oldSession, to: peerID, direction: .outbound, establishedAt: Date(timeIntervalSince1970: 200))
        router.bind(session: newSession, to: peerID, direction: .inbound, establishedAt: Date(timeIntervalSince1970: 100))
        router.bind(session: keepSession, to: peerID, direction: .inbound, establishedAt: Date(timeIntervalSince1970: 300))

        XCTAssertTrue(oldSession.isClosed)
        XCTAssertFalse(newSession.isClosed)
        XCTAssertTrue(keepSession.isClosed)
    }

    func testSendFailureUpdatesStatusSink() {
        let session = FakeLANWebSocketSession(sendError: FakeRouterError.sendFailed)
        let status = FakeRouterStatusSink()
        let router = makeRouter(statusSink: status)

        router.admit(session: session)
        router.handleEnvelope(helloEnvelope(), from: session)
        router.send(messages: [encryptedMessage(sender: localID, recipient: peerID, counter: 9)], to: peerID)

        XCTAssertEqual(status.sendFailures.count, 1)
        XCTAssertEqual(status.sendFailures[0].peerID, peerID)
        XCTAssertEqual(status.sendFailures[0].direction, .inbound)
    }

    private func makeRouter(admission: FakeRouterAdmission? = nil,
                            coordinator: FakeRouterCoordinator = FakeRouterCoordinator(),
                            statusSink: FakeRouterStatusSink = FakeRouterStatusSink()) -> TBLANEncryptedSessionRouter {
        TBLANEncryptedSessionRouter(admission: admission ?? FakeRouterAdmission(context: context()),
                                    coordinator: coordinator,
                                    statusSink: statusSink,
                                    now: { Date(timeIntervalSince1970: 100) })
    }

    private func context() -> TBLANEncryptedSessionContext {
        TBLANEncryptedSessionContext(peerID: peerID,
                                     displayName: "Peer",
                                     sessionKeyID: "session-key",
                                     sessionNonceSeed: Data(repeating: 1, count: 32),
                                     peerRole: .initiator,
                                     syncGroupID: "group")
    }

    private func helloEnvelope() -> Tomatt_Sync_V1_Envelope {
        var hello = Tomatt_Sync_V1_Hello()
        hello.deviceID = peerID
        hello.displayName = "Peer"
        hello.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        hello.sessionKeyID = "session-key"
        hello.sessionNonceSeed = Data(repeating: 1, count: 32)
        hello.sessionRole = .initiator
        hello.syncGroupID = "group"

        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.hello = hello
        return envelope
    }

    private func encryptedMessage(sender: String? = nil,
                                  recipient: String? = nil,
                                  counter: UInt64 = 1) -> TBEncryptedLANMessage {
        TBEncryptedLANMessage(protocolVersion: 1,
                              senderDeviceID: sender ?? peerID,
                              recipientDeviceID: recipient ?? localID,
                              senderSigningKeyFingerprint: String(repeating: "d", count: 64),
                              direction: .initiatorToResponder,
                              counter: counter,
                              nonce: Data([1, 2, 3]),
                              ciphertextAndTag: Data([4, 5, 6]))
    }
}

private final class FakeLANWebSocketSession: LANWebSocketSession {
    let endpointDescription: String
    var onEnvelopeReceived: ((Tomatt_Sync_V1_Envelope) -> Void)?
    private let sendError: Error?
    private(set) var sentEnvelopes: [Tomatt_Sync_V1_Envelope] = []
    private(set) var isClosed = false

    init(endpointDescription: String = "fake", sendError: Error? = nil) {
        self.endpointDescription = endpointDescription
        self.sendError = sendError
    }

    func send(_ envelope: Tomatt_Sync_V1_Envelope, completion: @escaping (Result<Void, Error>) -> Void) {
        if let sendError {
            completion(.failure(sendError))
            return
        }
        sentEnvelopes.append(envelope)
        completion(.success(()))
    }

    func close() {
        isClosed = true
    }
}

private final class FakeRouterAdmission: TBLANEncryptedSessionAdmitting {
    var result: Result<TBLANEncryptedSessionContext, TBLANEncryptedSessionAdmissionFailure>
    var outboundHello: Tomatt_Sync_V1_Hello?
    var anyOutboundHello: Tomatt_Sync_V1_Hello?
    private(set) var admitCount = 0
    private(set) var admittedDeviceIDs: [String] = []
    private(set) var retainedOutboundHellos: [String: Tomatt_Sync_V1_Hello] = [:]

    init(context: TBLANEncryptedSessionContext) {
        self.result = .success(context)
    }

    func admitResume(hello: Tomatt_Sync_V1_Hello) -> Result<TBLANEncryptedSessionContext, TBLANEncryptedSessionAdmissionFailure> {
        admitCount += 1
        admittedDeviceIDs.append(hello.deviceID)
        return result
    }

    func sessionContext(for peerID: String) -> TBLANEncryptedSessionContext? {
        try? result.get()
    }

    func prepareOutboundResume(peerID: String) -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        outboundHello.map { .success($0) } ?? .failure(.notReady("missing outbound hello"))
    }

    func prepareAnyOutboundResume() -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        anyOutboundHello.map { .success($0) } ?? .failure(.notReady("missing anonymous outbound hello"))
    }

    func retainOutboundResumeHello(_ hello: Tomatt_Sync_V1_Hello, for peerID: String) {
        retainedOutboundHellos[peerID] = hello
    }
}

private final class FakeRouterCoordinator: TBLANEncryptedSessionCoordinating {
    private let responses: [TBEncryptedLANMessage]
    private let initialMessages: [TBEncryptedLANMessage]
    private(set) var receivedMessages: [TBEncryptedLANMessage] = []
    private(set) var initialSyncPeerIDs: [String] = []

    init(responses: [TBEncryptedLANMessage] = [], initialMessages: [TBEncryptedLANMessage] = []) {
        self.responses = responses
        self.initialMessages = initialMessages
    }

    func triggerConnectionEstablishedSync(deviceID: String) -> [TBEncryptedLANMessage] {
        initialSyncPeerIDs.append(deviceID)
        return initialMessages
    }

    func receive(_ message: TBEncryptedLANMessage, from deviceID: String) -> [TBEncryptedLANMessage] {
        receivedMessages.append(message)
        return responses
    }
}

private final class FakeRouterStatusSink: TBLANEncryptedSessionStatusSinking {
    private(set) var rejections: [(peerID: String?, state: TBSyncPeerRuntimeState, reason: String)] = []
    private(set) var sendFailures: [(peerID: String, direction: LANDuplicateConnectionDirection, error: Error)] = []

    func sessionRejected(peerID: String?, state: TBSyncPeerRuntimeState, reason: String) {
        rejections.append((peerID, state, reason))
    }

    func sendFailed(peerID: String, direction: LANDuplicateConnectionDirection, error: Error) {
        sendFailures.append((peerID, direction, error))
    }
}

private enum FakeRouterError: Error {
    case sendFailed
}

import CryptoKit
import Foundation
import SwiftProtobuf

enum TBSyncSessionRole: String, Codable, Equatable {
    case initiator
    case responder
}

enum TBSyncSessionDirection: String, Codable, Equatable {
    case initiatorToResponder
    case responderToInitiator

    init(senderRole: TBSyncSessionRole) {
        switch senderRole {
        case .initiator: self = .initiatorToResponder
        case .responder: self = .responderToInitiator
        }
    }
}

struct TBAuthenticatedPeerContext: Equatable {
    let localDeviceID: String
    let localSigningKeyFingerprint: String
    let peerDeviceID: String
    let peerSigningKeyFingerprint: String
    let protocolMajor: UInt32
    let protocolMinor: UInt32
    let capabilities: [String]

    var importContext: TBAuthenticatedSyncContext {
        TBAuthenticatedSyncContext(peerDeviceID: peerDeviceID,
                                   peerSigningKeyFingerprint: peerSigningKeyFingerprint)
    }
}

enum TBAuthenticatedPeerContextBuilder {
    static func build(localIdentity: TBSyncDevicePublicIdentity,
                      peerDeviceID: String,
                      peerStore: TBTrustedPeerStoring,
                      protocolMajor: UInt32 = TomattSyncProtocolV1.supportedMajorVersion,
                      protocolMinor: UInt32 = 0,
                      capabilities: [String] = []) throws -> TBAuthenticatedPeerContext {
        guard let peer = try peerStore.trustedPeer(deviceID: peerDeviceID) else {
            throw TBSyncSessionError.unpairedPeer(peerDeviceID)
        }
        guard !peer.isRemoved else { throw TBSyncSessionError.removedPeer(peerDeviceID) }

        return TBAuthenticatedPeerContext(localDeviceID: localIdentity.deviceID,
                                          localSigningKeyFingerprint: localIdentity.signingKeyFingerprint,
                                          peerDeviceID: peer.deviceID,
                                          peerSigningKeyFingerprint: peer.signingKeyFingerprint,
                                          protocolMajor: protocolMajor,
                                          protocolMinor: protocolMinor,
                                          capabilities: capabilities.sorted())
    }
}

struct TBSessionKeyMaterial {
    let keyID: String
    let symmetricKey: SymmetricKey

    var rawKeyData: Data { symmetricKey.withUnsafeBytes { Data($0) } }

    init(keyID: String, symmetricKey: SymmetricKey) {
        self.keyID = keyID
        self.symmetricKey = symmetricKey
    }

    static func fixedTestKey(_ data: Data, keyID: String = "fixed-test") throws -> TBSessionKeyMaterial {
        guard data.count == 32 else { throw TBSyncSessionError.unsupportedKeyMaterial }
        return TBSessionKeyMaterial(keyID: keyID, symmetricKey: SymmetricKey(data: data))
    }
}

enum TBReconnectSessionHydrationError: Error, Equatable {
    case pairingRequired(String)
    case resetRequired(String)
    case unpairedPeer(String)
    case removedPeer(String)
    case wrongGroup(String)
    case missingSyncGroupKey(String)
    case retiredSyncGroupKey(String)
    case invalidHello(String)
}

struct TBReconnectSessionHydrationResult {
    let context: TBAuthenticatedPeerContext
    let keyMaterial: TBSessionKeyMaterial
    let localRole: TBSyncSessionRole
    let localNonceSeed: Data
    let peerNonceSeed: Data

    func makeCryptoBox() -> TBSyncSessionCryptoBox {
        TBSyncSessionCryptoBox(context: context,
                               keyMaterial: keyMaterial,
                               localRole: localRole,
                               localNonceSeed: localNonceSeed,
                               peerNonceSeed: peerNonceSeed)
    }
}

enum TBReconnectSessionHydrator {
    static func hydrate(localIdentity: TBSyncDevicePublicIdentity,
                        localHello: Tomatt_Sync_V1_Hello,
                        peerHello: Tomatt_Sync_V1_Hello,
                        peerStore: TBTrustedPeerStoring,
                        metadataStore: TBSyncGroupMetadataStoring,
                        groupKeyStore: TBSyncGroupKeyStoring,
                        protocolMajor: UInt32 = TomattSyncProtocolV1.supportedMajorVersion,
                        protocolMinor: UInt32 = 0,
                        capabilities: [String] = []) throws -> TBReconnectSessionHydrationResult {
        guard localHello.deviceID == localIdentity.deviceID else { throw TBReconnectSessionHydrationError.invalidHello("local.device_id") }
        try validateHello(localHello, fieldPrefix: "local")
        try validateHello(peerHello, fieldPrefix: "peer")
        guard localHello.sessionRole != peerHello.sessionRole else {
            throw TBReconnectSessionHydrationError.invalidHello("duplicate session_role")
        }
        guard localHello.sessionKeyID == peerHello.sessionKeyID else {
            throw TBReconnectSessionHydrationError.invalidHello("session_key_id mismatch")
        }
        guard localHello.syncGroupID == peerHello.syncGroupID else {
            throw TBReconnectSessionHydrationError.wrongGroup("hello sync_group_id mismatch")
        }

        let activeGroups = try metadataStore.loadActiveSyncGroupMetadata()
        guard !activeGroups.isEmpty else { throw TBReconnectSessionHydrationError.pairingRequired("missing active sync group") }
        guard activeGroups.count == 1 else { throw TBReconnectSessionHydrationError.resetRequired("multiple active sync groups") }
        let metadata = activeGroups[0]
        guard metadata.groupID == localHello.syncGroupID else {
            throw TBReconnectSessionHydrationError.wrongGroup("hello sync_group_id is not the active sync group")
        }
        guard let syncGroupKey = try groupKeyStore.loadSyncGroupKey(groupID: metadata.groupID),
              syncGroupKey.keyID == metadata.keyID else {
            throw TBReconnectSessionHydrationError.missingSyncGroupKey(metadata.groupID)
        }
        guard syncGroupKey.isUsableForLANSync else {
            throw TBReconnectSessionHydrationError.retiredSyncGroupKey(syncGroupKey.keyID)
        }
        guard let peer = try peerStore.trustedPeer(deviceID: peerHello.deviceID) else {
            throw TBReconnectSessionHydrationError.unpairedPeer(peerHello.deviceID)
        }
        guard !peer.isRemoved else { throw TBReconnectSessionHydrationError.removedPeer(peerHello.deviceID) }

        let context = TBAuthenticatedPeerContext(localDeviceID: localIdentity.deviceID,
                                                 localSigningKeyFingerprint: localIdentity.signingKeyFingerprint,
                                                 peerDeviceID: peer.deviceID,
                                                 peerSigningKeyFingerprint: peer.signingKeyFingerprint,
                                                 protocolMajor: protocolMajor,
                                                 protocolMinor: protocolMinor,
                                                 capabilities: capabilities.sorted())
        let keyMaterial = deriveKeyMaterial(localDeviceID: localIdentity.deviceID,
                                            peerDeviceID: peer.deviceID,
                                            localHello: localHello,
                                            peerHello: peerHello,
                                            syncGroupKey: syncGroupKey)
        return TBReconnectSessionHydrationResult(context: context,
                                                 keyMaterial: keyMaterial,
                                                 localRole: syncRole(from: localHello.sessionRole)!,
                                                 localNonceSeed: localHello.sessionNonceSeed,
                                                 peerNonceSeed: peerHello.sessionNonceSeed)
    }

    private static func validateHello(_ hello: Tomatt_Sync_V1_Hello, fieldPrefix: String) throws {
        guard TomattSyncProtocolV1.isCompatibleHello(hello) else {
            throw TBReconnectSessionHydrationError.invalidHello("\(fieldPrefix).protocol_version")
        }
        guard TomattSyncProtocolV1.isCanonicalLowercaseUUIDString(hello.deviceID) else {
            throw TBReconnectSessionHydrationError.invalidHello("\(fieldPrefix).device_id")
        }
        guard !hello.sessionKeyID.isEmpty else { throw TBReconnectSessionHydrationError.invalidHello("\(fieldPrefix).session_key_id") }
        guard hello.sessionNonceSeed.count == 32 else { throw TBReconnectSessionHydrationError.invalidHello("\(fieldPrefix).session_nonce_seed") }
        guard syncRole(from: hello.sessionRole) != nil else { throw TBReconnectSessionHydrationError.invalidHello("\(fieldPrefix).session_role") }
        guard !hello.syncGroupID.isEmpty else { throw TBReconnectSessionHydrationError.invalidHello("\(fieldPrefix).sync_group_id") }
    }

    private static func deriveKeyMaterial(localDeviceID: String,
                                          peerDeviceID: String,
                                          localHello: Tomatt_Sync_V1_Hello,
                                          peerHello: Tomatt_Sync_V1_Hello,
                                          syncGroupKey: TBSyncGroupKeyRecord) -> TBSessionKeyMaterial {
        let orderedIDs = [localDeviceID, peerDeviceID].sorted()
        let initiatorNonce = localHello.sessionRole == .initiator ? localHello.sessionNonceSeed : peerHello.sessionNonceSeed
        let responderNonce = localHello.sessionRole == .responder ? localHello.sessionNonceSeed : peerHello.sessionNonceSeed
        let salt = Data("tomatt.lan.session.v1.salt".utf8)
            + Data(syncGroupKey.groupID.utf8)
            + Data(orderedIDs[0].utf8)
            + Data(orderedIDs[1].utf8)
            + initiatorNonce
            + responderNonce
        let info = Data("tomatt.lan.session.v1.key".utf8)
            + Data(syncGroupKey.keyID.utf8)
            + Data(localHello.sessionKeyID.utf8)
        let derivedKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: syncGroupKey.secret),
                                                salt: salt,
                                                info: info,
                                                outputByteCount: 32)
        let keyIDMaterial = Data("tomatt.lan.session.v1.keyid".utf8)
            + Data(syncGroupKey.groupID.utf8)
            + Data(syncGroupKey.keyID.utf8)
            + Data(localHello.sessionKeyID.utf8)
            + Data(orderedIDs[0].utf8)
            + Data(orderedIDs[1].utf8)
            + initiatorNonce
            + responderNonce
        return TBSessionKeyMaterial(keyID: Data(SHA256.hash(data: keyIDMaterial)).tbSessionHexString,
                                    symmetricKey: derivedKey)
    }

    private static func syncRole(from protoRole: Tomatt_Sync_V1_Hello.SessionRole) -> TBSyncSessionRole? {
        switch protoRole {
        case .initiator: return .initiator
        case .responder: return .responder
        default: return nil
        }
    }
}

struct TBSessionTranscript: Equatable {
    static let version = 1

    let localDeviceID: String
    let peerDeviceID: String
    let localSigningKeyFingerprint: String
    let peerSigningKeyFingerprint: String
    let localRole: TBSyncSessionRole
    let protocolMajor: UInt32
    let protocolMinor: UInt32
    let capabilities: [String]
    let localNonceSeed: Data
    let peerNonceSeed: Data
    let keyID: String

    var bytes: Data {
        let seedA = localRole == .initiator ? localNonceSeed : peerNonceSeed
        let seedB = localRole == .initiator ? peerNonceSeed : localNonceSeed
        let object: [String: Any] = [
            "capabilities": capabilities.sorted(),
            "initiatorDeviceID": localRole == .initiator ? localDeviceID : peerDeviceID,
            "initiatorNonceSeed": seedA.base64EncodedString(),
            "initiatorSigningKeyFingerprint": localRole == .initiator ? localSigningKeyFingerprint : peerSigningKeyFingerprint,
            "keyID": keyID,
            "protocolMajor": protocolMajor,
            "protocolMinor": protocolMinor,
            "responderDeviceID": localRole == .initiator ? peerDeviceID : localDeviceID,
            "responderNonceSeed": seedB.base64EncodedString(),
            "responderSigningKeyFingerprint": localRole == .initiator ? peerSigningKeyFingerprint : localSigningKeyFingerprint,
            "sessionTranscriptVersion": Self.version,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    var hash: Data { Data(SHA256.hash(data: bytes)) }
}

struct TBEncryptedLANMessage: Codable, Equatable {
    let protocolVersion: UInt32
    let senderDeviceID: String
    let recipientDeviceID: String
    let senderSigningKeyFingerprint: String
    let direction: TBSyncSessionDirection
    let counter: UInt64
    let nonce: Data
    let ciphertextAndTag: Data
}

enum TBSyncSessionError: Error, Equatable {
    case unauthenticatedSession
    case unsupportedKeyMaterial
    case unsupportedProtocolVersion(UInt32)
    case unpairedPeer(String)
    case removedPeer(String)
    case wrongPeer(expected: String, actual: String)
    case wrongRecipient(expected: String, actual: String)
    case peerKeyMismatch
    case tamperedOrUnauthentic
    case replayOrLowerCounter(counter: UInt64, highestSeen: UInt64)
    case invalidEncryptedMessage
    case plaintextSyncEventExchangeUnavailable
    case unsupportedSyncPayload
}

final class TBSyncSessionCryptoBox {
    let context: TBAuthenticatedPeerContext
    let transcript: TBSessionTranscript
    private let keyMaterial: TBSessionKeyMaterial
    private let localRole: TBSyncSessionRole
    private var nextSendCounter: UInt64
    private var highestReceivedCounters: [TBSyncSessionDirection: UInt64]

    /// Memory-only authenticated encryption box for one already-authenticated
    /// peer session. G006 supplies real AEAD, transcript binding, and replay
    /// protection over injected symmetric key material; pairing-time key
    /// agreement can replace the `TBSessionKeyMaterial` source later without
    /// changing the event exchange gate. AES-GCM is used because it is available
    /// through CryptoKit on the repository's macOS deployment target.
    init(context: TBAuthenticatedPeerContext,
         keyMaterial: TBSessionKeyMaterial,
         localRole: TBSyncSessionRole,
         localNonceSeed: Data,
         peerNonceSeed: Data,
         initialSendCounter: UInt64 = 0) {
        self.context = context
        self.keyMaterial = keyMaterial
        self.localRole = localRole
        nextSendCounter = initialSendCounter
        highestReceivedCounters = [:]
        transcript = TBSessionTranscript(localDeviceID: context.localDeviceID,
                                         peerDeviceID: context.peerDeviceID,
                                         localSigningKeyFingerprint: context.localSigningKeyFingerprint,
                                         peerSigningKeyFingerprint: context.peerSigningKeyFingerprint,
                                         localRole: localRole,
                                         protocolMajor: context.protocolMajor,
                                         protocolMinor: context.protocolMinor,
                                         capabilities: context.capabilities,
                                         localNonceSeed: localNonceSeed,
                                         peerNonceSeed: peerNonceSeed,
                                         keyID: keyMaterial.keyID)
    }

    func seal(envelope: Tomatt_Sync_V1_Envelope) throws -> TBEncryptedLANMessage {
        let plaintext = try envelope.serializedData()
        let counter = nextSendCounter + 1
        let direction = TBSyncSessionDirection(senderRole: localRole)
        let nonceData = nonce(direction: direction, counter: counter)
        let sealed = try AES.GCM.seal(plaintext,
                                      using: keyMaterial.symmetricKey,
                                      nonce: AES.GCM.Nonce(data: nonceData),
                                      authenticating: additionalData(direction: direction,
                                                                    senderDeviceID: context.localDeviceID,
                                                                    recipientDeviceID: context.peerDeviceID,
                                                                    senderFingerprint: context.localSigningKeyFingerprint,
                                                                    counter: counter,
                                                                    nonce: nonceData))
        guard let combined = sealed.combined else { throw TBSyncSessionError.invalidEncryptedMessage }
        nextSendCounter = counter
        return TBEncryptedLANMessage(protocolVersion: UInt32(TBSessionTranscript.version),
                                     senderDeviceID: context.localDeviceID,
                                     recipientDeviceID: context.peerDeviceID,
                                     senderSigningKeyFingerprint: context.localSigningKeyFingerprint,
                                     direction: direction,
                                     counter: counter,
                                     nonce: nonceData,
                                     ciphertextAndTag: combined)
    }

    func open(_ message: TBEncryptedLANMessage) throws -> Tomatt_Sync_V1_Envelope {
        guard message.protocolVersion == UInt32(TBSessionTranscript.version) else {
            throw TBSyncSessionError.unsupportedProtocolVersion(message.protocolVersion)
        }
        guard message.senderDeviceID == context.peerDeviceID else {
            throw TBSyncSessionError.wrongPeer(expected: context.peerDeviceID, actual: message.senderDeviceID)
        }
        guard message.recipientDeviceID == context.localDeviceID else {
            throw TBSyncSessionError.wrongRecipient(expected: context.localDeviceID, actual: message.recipientDeviceID)
        }
        guard message.senderSigningKeyFingerprint == context.peerSigningKeyFingerprint else {
            throw TBSyncSessionError.peerKeyMismatch
        }
        let expectedDirection: TBSyncSessionDirection = localRole == .initiator ? .responderToInitiator : .initiatorToResponder
        guard message.direction == expectedDirection else {
            throw TBSyncSessionError.wrongPeer(expected: expectedDirection.rawValue, actual: message.direction.rawValue)
        }
        let highestSeen = highestReceivedCounters[message.direction] ?? 0
        guard message.counter > highestSeen else {
            throw TBSyncSessionError.replayOrLowerCounter(counter: message.counter, highestSeen: highestSeen)
        }
        guard message.nonce == nonce(direction: message.direction, counter: message.counter) else {
            throw TBSyncSessionError.tamperedOrUnauthentic
        }

        do {
            let sealed = try AES.GCM.SealedBox(combined: message.ciphertextAndTag)
            let plaintext = try AES.GCM.open(sealed,
                                             using: keyMaterial.symmetricKey,
                                             authenticating: additionalData(direction: message.direction,
                                                                           senderDeviceID: message.senderDeviceID,
                                                                           recipientDeviceID: message.recipientDeviceID,
                                                                           senderFingerprint: message.senderSigningKeyFingerprint,
                                                                           counter: message.counter,
                                                                           nonce: message.nonce))
            let envelope = try Tomatt_Sync_V1_Envelope(serializedBytes: plaintext)
            highestReceivedCounters[message.direction] = message.counter
            return envelope
        } catch let error as TBSyncSessionError {
            throw error
        } catch {
            throw TBSyncSessionError.tamperedOrUnauthentic
        }
    }

    private func nonce(direction: TBSyncSessionDirection, counter: UInt64) -> Data {
        var data = transcript.hash
        data.append(Data(direction.rawValue.utf8))
        data.append(Self.bigEndian(counter))
        return Data(SHA256.hash(data: data)).prefixData(12)
    }

    private func additionalData(direction: TBSyncSessionDirection,
                                senderDeviceID: String,
                                recipientDeviceID: String,
                                senderFingerprint: String,
                                counter: UInt64,
                                nonce: Data) throws -> Data {
        let object: [String: Any] = [
            "counter": counter,
            "direction": direction.rawValue,
            "nonce": nonce.base64EncodedString(),
            "recipientDeviceID": recipientDeviceID,
            "senderDeviceID": senderDeviceID,
            "senderSigningKeyFingerprint": senderFingerprint,
            "sessionTranscriptSHA256": transcript.hash.tbSessionHexString,
            "sessionTranscriptVersion": TBSessionTranscript.version,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
    }
}

private struct TBLANSignedEventBatchPayload: Codable {
    let signedEvents: [TBSignedSyncEvent]
}

final class TBAuthenticatedLANSyncGate {
    private let session: TBSyncSessionCryptoBox?
    private let importer: TBSignedSyncEventTrustedImporter

    init(session: TBSyncSessionCryptoBox?, importer: TBSignedSyncEventTrustedImporter) {
        self.session = session
        self.importer = importer
    }

    func sealSignedEventBatch(_ signedEvents: [TBSignedSyncEvent], messageID: String) throws -> TBEncryptedLANMessage {
        guard let session = session else { throw TBSyncSessionError.unauthenticatedSession }
        var batch = Tomatt_Sync_V1_EventBatch()
        batch.deviceID = session.context.localDeviceID
        batch.events = try signedEvents.map { signedEvent in
            var event = Tomatt_Sync_V1_SyncEvent()
            event.eventID = signedEvent.envelope.eventID.uuidString.lowercased()
            event.originDeviceID = signedEvent.envelope.originDeviceID ?? ""
            event.sequence = UInt64(max(0, signedEvent.envelope.deviceSequence ?? 0))
            event.canonicalJson = try JSONEncoder().encode(signedEvent)
            return event
        }

        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = messageID
        envelope.protocolMajor = session.context.protocolMajor
        envelope.protocolMinor = session.context.protocolMinor
        envelope.payload = .eventBatch(batch)
        return try session.seal(envelope: envelope)
    }

    func rejectPlaintextSyncEventEnvelope(_ envelope: Tomatt_Sync_V1_Envelope) throws {
        switch envelope.payload {
        case .eventBatch, .eventSummary, .missingEventRequest, .eventBatchAck, .newEventsAvailable:
            throw TBSyncSessionError.plaintextSyncEventExchangeUnavailable
        default:
            return
        }
    }

    func openAndImportSignedEventBatch(_ message: TBEncryptedLANMessage) throws -> TBSyncImportOutcome {
        guard let session = session else { throw TBSyncSessionError.unauthenticatedSession }
        let envelope = try session.open(message)
        guard case .eventBatch(let batch)? = envelope.payload else {
            throw TBSyncSessionError.unsupportedSyncPayload
        }
        let signedEvents = try batch.events.map { event -> TBSignedSyncEvent in
            guard !event.canonicalJson.isEmpty else { throw TBSyncSessionError.unsupportedSyncPayload }
            return try JSONDecoder().decode(TBSignedSyncEvent.self, from: event.canonicalJson)
        }
        return try importer.importSignedEvents(signedEvents, context: session.context.importContext)
    }
}

private extension Data {
    func prefixData(_ count: Int) -> Data { Data(prefix(count)) }

    var tbSessionHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

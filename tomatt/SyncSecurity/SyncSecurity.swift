import CryptoKit
import Foundation

/// Local UI/device identity remains display-oriented (`TBDeviceIdentity`).
/// This file models sync cryptographic identity separately: long-lived device
/// signing keys, trusted peer records, sync-group secrets, and signed event
/// import gates. It intentionally has no UI, transport, pairing flow, or LAN
/// session encryption dependency.

struct TBSyncDevicePublicIdentity: Codable, Equatable {
    let deviceID: String
    var displayName: String
    var platform: String?
    let signingPublicKey: Data
    let signingKeyFingerprint: String

    init(deviceID: String,
         displayName: String,
         platform: String?,
         signingPublicKey: Data) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.signingPublicKey = signingPublicKey
        signingKeyFingerprint = TBSyncKeyFingerprint.fingerprint(signingPublicKey)
    }
}

enum TBSyncSignatureAlgorithm: String, Codable, Equatable {
    case ed25519 = "ed25519"
    /// Test-only deterministic signer. Never use for production trust.
    case deterministicTest = "deterministic-test"
}

struct TBTrustedPeerRecord: Codable, Equatable {
    let deviceID: String
    var displayName: String
    var platform: String?
    var signingPublicKey: Data
    var signingKeyFingerprint: String
    var isRemoved: Bool
    var lastSeenAt: Date?

    init(deviceID: String,
         displayName: String,
         platform: String?,
         signingPublicKey: Data,
         isRemoved: Bool = false,
         lastSeenAt: Date? = nil) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.signingPublicKey = signingPublicKey
        signingKeyFingerprint = TBSyncKeyFingerprint.fingerprint(signingPublicKey)
        self.isRemoved = isRemoved
        self.lastSeenAt = lastSeenAt
    }
}

enum TBSyncGroupKeyState: String, Codable, Equatable {
    case active
    case imported
    case retired
}

struct TBSyncGroupKeyRecord: Codable, Equatable {
    let groupID: String
    var keyID: String
    var secret: Data
    var createdAt: Date
    var state: TBSyncGroupKeyState

    static func createNew(groupID: String = UUID().uuidString.lowercased(),
                          keyID: String = UUID().uuidString.lowercased(),
                          createdAt: Date = Date()) -> TBSyncGroupKeyRecord {
        TBSyncGroupKeyRecord(groupID: groupID,
                             keyID: keyID,
                             secret: Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }),
                             createdAt: createdAt,
                             state: .active)
    }

    static func importExisting(groupID: String,
                               keyID: String,
                               secret: Data,
                               createdAt: Date = Date()) throws -> TBSyncGroupKeyRecord {
        guard secret.count == 32 else { throw TBSyncSecurityError.invalidSyncGroupKey }
        return TBSyncGroupKeyRecord(groupID: groupID,
                                    keyID: keyID,
                                    secret: secret,
                                    createdAt: createdAt,
                                    state: .imported)
    }
}

protocol TBDeviceSigningKeyStoring {
    func loadSigningPrivateKey() throws -> Data?
    func saveSigningPrivateKey(_ rawRepresentation: Data) throws
}

protocol TBSyncGroupKeyStoring {
    func loadSyncGroupKey(groupID: String) throws -> TBSyncGroupKeyRecord?
    func saveSyncGroupKey(_ record: TBSyncGroupKeyRecord) throws
}

protocol TBTrustedPeerStoring {
    func trustedPeer(deviceID: String) throws -> TBTrustedPeerRecord?
    func saveTrustedPeer(_ record: TBTrustedPeerRecord) throws
}

/// Minimal Apple Keychain adapter boundary for production storage. The concrete
/// SecItem calls are intentionally deferred until G003 consumers are wired; unit
/// tests use in-memory stores below and do not rely on user keychains.
final class TBAppleKeychainDeviceSigningKeyStore: TBDeviceSigningKeyStoring {
    private let service: String
    private let account: String

    init(service: String = "tomatt.sync.device-signing", account: String) {
        self.service = service
        self.account = account
    }

    func loadSigningPrivateKey() throws -> Data? {
        throw TBSyncSecurityError.keychainAdapterNotImplemented(service: service, account: account)
    }

    func saveSigningPrivateKey(_ rawRepresentation: Data) throws {
        _ = rawRepresentation
        throw TBSyncSecurityError.keychainAdapterNotImplemented(service: service, account: account)
    }
}

final class TBInMemoryDeviceSigningKeyStore: TBDeviceSigningKeyStoring {
    private var rawKey: Data?

    func loadSigningPrivateKey() throws -> Data? { rawKey }
    func saveSigningPrivateKey(_ rawRepresentation: Data) throws { rawKey = rawRepresentation }
}

final class TBInMemorySyncGroupKeyStore: TBSyncGroupKeyStoring {
    private var records: [String: TBSyncGroupKeyRecord] = [:]

    func loadSyncGroupKey(groupID: String) throws -> TBSyncGroupKeyRecord? { records[groupID] }
    func saveSyncGroupKey(_ record: TBSyncGroupKeyRecord) throws { records[record.groupID] = record }
}

final class TBInMemoryTrustedPeerStore: TBTrustedPeerStoring {
    private var records: [String: TBTrustedPeerRecord] = [:]

    init(records: [TBTrustedPeerRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.deviceID, $0) })
    }

    func trustedPeer(deviceID: String) throws -> TBTrustedPeerRecord? { records[deviceID] }
    func saveTrustedPeer(_ record: TBTrustedPeerRecord) throws { records[record.deviceID] = record }
}

enum TBSyncKeyFingerprint {
    static func fingerprint(_ publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey)).tbSyncHexString
    }
}

protocol TBSyncEventSigning {
    var algorithm: TBSyncSignatureAlgorithm { get }
    var publicKey: Data { get }
    func sign(_ bytes: Data) throws -> Data
}

protocol TBSyncEventSignatureVerifying {
    func verify(signature: Data,
                canonicalBytes: Data,
                publicKey: Data,
                algorithm: TBSyncSignatureAlgorithm) -> Bool
}

struct TBEd25519DeviceSigner: TBSyncEventSigning {
    let privateKey: Curve25519.Signing.PrivateKey
    var algorithm: TBSyncSignatureAlgorithm { .ed25519 }
    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    init(store: TBDeviceSigningKeyStoring) throws {
        if let raw = try store.loadSigningPrivateKey() {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        } else {
            let created = Curve25519.Signing.PrivateKey()
            try store.saveSigningPrivateKey(created.rawRepresentation)
            privateKey = created
        }
    }

    func sign(_ bytes: Data) throws -> Data {
        try privateKey.signature(for: bytes)
    }
}

struct TBEd25519SignatureVerifier: TBSyncEventSignatureVerifying {
    func verify(signature: Data,
                canonicalBytes: Data,
                publicKey: Data,
                algorithm: TBSyncSignatureAlgorithm) -> Bool {
        guard algorithm == .ed25519,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: canonicalBytes)
    }
}

struct TBDeterministicTestSigner: TBSyncEventSigning, TBSyncEventSignatureVerifying {
    let secret: Data
    let publicKey: Data
    var algorithm: TBSyncSignatureAlgorithm { .deterministicTest }

    init(secret: Data) {
        self.secret = secret
        publicKey = Data(SHA256.hash(data: secret))
    }

    func sign(_ bytes: Data) throws -> Data {
        Data(SHA256.hash(data: publicKey + bytes))
    }

    func verify(signature: Data,
                canonicalBytes: Data,
                publicKey: Data,
                algorithm: TBSyncSignatureAlgorithm) -> Bool {
        guard algorithm == .deterministicTest else { return false }
        return signature == Data(SHA256.hash(data: publicKey + canonicalBytes))
    }
}

/// Signed wrapper over the existing raw event-log envelope. It does not mutate
/// `TBEventEnvelope`; trust metadata remains outside the raw event log schema.
struct TBSignedSyncEvent: Codable, Equatable {
    var envelope: TBEventEnvelope
    var signerDeviceID: String
    var signingPublicKey: Data
    var signingKeyFingerprint: String
    var signatureAlgorithm: TBSyncSignatureAlgorithm
    var signature: Data

    static func sign(envelope: TBEventEnvelope,
                     signerDeviceID: String,
                     signer: TBSyncEventSigning) throws -> TBSignedSyncEvent {
        let bytes = try TBSyncCanonicalEventBytes.encode(envelope)
        let publicKey = signer.publicKey
        return TBSignedSyncEvent(envelope: envelope,
                                 signerDeviceID: signerDeviceID,
                                 signingPublicKey: publicKey,
                                 signingKeyFingerprint: TBSyncKeyFingerprint.fingerprint(publicKey),
                                 signatureAlgorithm: signer.algorithm,
                                 signature: try signer.sign(bytes))
    }
}

struct TBAuthenticatedSyncContext: Equatable {
    let peerDeviceID: String
    let peerSigningKeyFingerprint: String
    let authenticatedAt: Date

    init(peerDeviceID: String,
         peerSigningKeyFingerprint: String,
         authenticatedAt: Date = Date()) {
        self.peerDeviceID = peerDeviceID
        self.peerSigningKeyFingerprint = peerSigningKeyFingerprint
        self.authenticatedAt = authenticatedAt
    }
}

enum TBSyncCanonicalEventBytes {
    /// Interim v1 canonicalization pending final protobuf event payload modeling.
    /// The signed bytes are deterministic sorted-key JSON containing creator
    /// device id, device sequence, schema version, event id, event type, recorded
    /// timestamp, and SHA-256 of the domain event payload. Transport/session
    /// metadata is excluded by construction.
    static let version = 1

    static func encode(_ envelope: TBEventEnvelope) throws -> Data {
        guard let creatorDeviceID = envelope.originDeviceID,
              let deviceSequence = envelope.deviceSequence else {
            throw TBSyncSecurityError.invalidEventStructure
        }

        let payloadBytes = try canonicalJSON(envelope.event)
        let eventType = try eventTypeName(envelope.event)
        let canonical = CanonicalEnvelope(canonicalVersion: version,
                                          creatorDeviceID: creatorDeviceID,
                                          deviceSequence: deviceSequence,
                                          schemaVersion: envelope.schemaVersion,
                                          eventID: envelope.eventID.uuidString.lowercased(),
                                          eventType: eventType,
                                          recordedAt: iso8601(envelope.recordedAt),
                                          domainPayloadSHA256: Data(SHA256.hash(data: payloadBytes)).tbSyncHexString)
        return try canonicalJSON(canonical)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func eventTypeName(_ event: TBEvent) throws -> String {
        let data = try canonicalJSON(event)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw TBSyncSecurityError.invalidEventStructure
        }
        return type
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct CanonicalEnvelope: Encodable {
        let canonicalVersion: Int
        let creatorDeviceID: String
        let deviceSequence: Int64
        let schemaVersion: Int
        let eventID: String
        let eventType: String
        let recordedAt: String
        let domainPayloadSHA256: String
    }
}

protocol TBSignedSyncEventImportSink {
    func importAlreadyVerifiedEvents(_ events: [TBEventEnvelope]) -> TBSyncImportOutcome
}

extension TBSyncEventLogFacade: TBSignedSyncEventImportSink {
    func importAlreadyVerifiedEvents(_ events: [TBEventEnvelope]) -> TBSyncImportOutcome {
        importAlreadyVerifiedEvents(TBSyncEventBatch(events: events))
    }
}

final class TBSignedSyncEventTrustedImporter {
    private let peerStore: TBTrustedPeerStoring
    private let verifier: TBSyncEventSignatureVerifying
    private let sink: TBSignedSyncEventImportSink

    init(peerStore: TBTrustedPeerStoring,
         verifier: TBSyncEventSignatureVerifying,
         sink: TBSignedSyncEventImportSink) {
        self.peerStore = peerStore
        self.verifier = verifier
        self.sink = sink
    }

    func importSignedEvents(_ signedEvents: [TBSignedSyncEvent],
                            context: TBAuthenticatedSyncContext) throws -> TBSyncImportOutcome {
        guard let peer = try peerStore.trustedPeer(deviceID: context.peerDeviceID) else {
            throw TBSyncSecurityError.untrustedPeer(context.peerDeviceID)
        }
        guard !peer.isRemoved else { throw TBSyncSecurityError.removedPeer(context.peerDeviceID) }
        guard peer.signingKeyFingerprint == context.peerSigningKeyFingerprint else {
            throw TBSyncSecurityError.peerKeyMismatch
        }

        let envelopes = try signedEvents.map { signedEvent -> TBEventEnvelope in
            try verify(signedEvent, peer: peer, context: context)
            return signedEvent.envelope
        }
        return sink.importAlreadyVerifiedEvents(envelopes)
    }

    private func verify(_ signedEvent: TBSignedSyncEvent,
                        peer: TBTrustedPeerRecord,
                        context: TBAuthenticatedSyncContext) throws {
        guard signedEvent.signerDeviceID == context.peerDeviceID,
              signedEvent.signerDeviceID == signedEvent.envelope.originDeviceID else {
            throw TBSyncSecurityError.signerMismatch
        }
        guard signedEvent.signingPublicKey == peer.signingPublicKey,
              signedEvent.signingKeyFingerprint == peer.signingKeyFingerprint,
              signedEvent.signingKeyFingerprint == TBSyncKeyFingerprint.fingerprint(signedEvent.signingPublicKey) else {
            throw TBSyncSecurityError.peerKeyMismatch
        }
        guard isStructurallyImportable(signedEvent.envelope) else {
            throw TBSyncSecurityError.invalidEventStructure
        }
        let canonicalBytes = try TBSyncCanonicalEventBytes.encode(signedEvent.envelope)
        guard verifier.verify(signature: signedEvent.signature,
                              canonicalBytes: canonicalBytes,
                              publicKey: signedEvent.signingPublicKey,
                              algorithm: signedEvent.signatureAlgorithm) else {
            throw TBSyncSecurityError.invalidSignature
        }
    }

    private func isStructurallyImportable(_ event: TBEventEnvelope) -> Bool {
        guard event.schemaVersion == TBEventSchemaVersion,
              event.event.isSyncable,
              let originDeviceID = event.originDeviceID,
              let deviceSequence = event.deviceSequence,
              deviceSequence > 0 else {
            return false
        }
        return event.eventID == TBSyncEventID.derive(originDeviceID: originDeviceID,
                                                    deviceSequence: deviceSequence)
    }
}

enum TBSyncSecurityError: Error, Equatable {
    case invalidSyncGroupKey
    case keychainAdapterNotImplemented(service: String, account: String)
    case untrustedPeer(String)
    case removedPeer(String)
    case peerKeyMismatch
    case signerMismatch
    case invalidEventStructure
    case invalidSignature
}

private extension Data {
    var tbSyncHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
import Foundation
import Security

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

    var isUsableForLANSync: Bool {
        state == .active || state == .imported
    }
}

protocol TBDeviceSigningKeyStoring {
    func loadSigningPrivateKey() throws -> Data?
    func saveSigningPrivateKey(_ rawRepresentation: Data) throws
}

protocol TBSyncGroupKeyStoring {
    func loadSyncGroupKey(groupID: String) throws -> TBSyncGroupKeyRecord?
    func saveSyncGroupKey(_ record: TBSyncGroupKeyRecord) throws
    func deleteSyncGroupKey(groupID: String) throws
}

protocol TBTrustedPeerStoring {
    func trustedPeer(deviceID: String) throws -> TBTrustedPeerRecord?
    func saveTrustedPeer(_ record: TBTrustedPeerRecord) throws
    func deleteTrustedPeer(deviceID: String) throws
}

protocol TBSyncResettableStore {
    func resetSyncStorage() throws
}

final class TBAppleKeychainDeviceSigningKeyStore: TBDeviceSigningKeyStoring {
    private let service: String
    private let account: String

    init(service: String = "tomatt.sync.device-signing", account: String) {
        self.service = service
        self.account = account
    }

    func loadSigningPrivateKey() throws -> Data? {
        try TBAppleKeychainDataStore(service: service, account: account).load()
    }

    func saveSigningPrivateKey(_ rawRepresentation: Data) throws {
        try TBAppleKeychainDataStore(service: service, account: account).save(rawRepresentation)
    }
}

extension TBAppleKeychainDeviceSigningKeyStore: TBSyncResettableStore {
    func resetSyncStorage() throws {
        try TBAppleKeychainDataStore(service: service, account: account).delete()
    }
}

class TBAppleKeychainSyncGroupKeyStore: TBSyncGroupKeyStoring {
    private let service: String

    init(service: String = "tomatt.sync.group-key") {
        self.service = service
    }

    func loadSyncGroupKey(groupID: String) throws -> TBSyncGroupKeyRecord? {
        guard let data = try TBAppleKeychainDataStore(service: service, account: groupID).load() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TBSyncGroupKeyRecord.self, from: data)
    }

    func saveSyncGroupKey(_ record: TBSyncGroupKeyRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try TBAppleKeychainDataStore(service: service, account: record.groupID).save(encoder.encode(record))
    }

    func deleteSyncGroupKey(groupID: String) throws {
        try TBAppleKeychainDataStore(service: service, account: groupID).delete()
    }
}

final class TBAppleKeychainSyncGroupKeyResetStore: TBSyncResettableStore {
    private let keyStore: TBAppleKeychainSyncGroupKeyStore
    private let groupID: String

    init(keyStore: TBAppleKeychainSyncGroupKeyStore = TBAppleKeychainSyncGroupKeyStore(), groupID: String) {
        self.keyStore = keyStore
        self.groupID = groupID
    }

    func resetSyncStorage() throws {
        try keyStore.deleteSyncGroupKey(groupID: groupID)
    }
}

final class TBFreshDeviceSigningKeyResetStore: TBSyncResettableStore {
    private let resettableStore: TBSyncResettableStore
    private let signingStore: TBDeviceSigningKeyStoring

    init(resettableStore: TBSyncResettableStore, signingStore: TBDeviceSigningKeyStoring) {
        self.resettableStore = resettableStore
        self.signingStore = signingStore
    }

    func resetSyncStorage() throws {
        try resettableStore.resetSyncStorage()
        _ = try TBEd25519DeviceSigner(store: signingStore)
    }
}

final class TBMetadataBackedSyncGroupKeyResetStore: TBSyncResettableStore {
    private let keyStore: TBAppleKeychainSyncGroupKeyStore
    private let metadataStore: TBSyncGroupMetadataStoring

    init(keyStore: TBAppleKeychainSyncGroupKeyStore = TBAppleKeychainSyncGroupKeyStore(),
         metadataStore: TBSyncGroupMetadataStoring) {
        self.keyStore = keyStore
        self.metadataStore = metadataStore
    }

    func resetSyncStorage() throws {
        for metadata in try metadataStore.loadAllSyncGroupMetadata() {
            try keyStore.deleteSyncGroupKey(groupID: metadata.groupID)
        }
    }
}

private struct TBAppleKeychainDataStore {
    let service: String
    let account: String

    func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TBSyncSecurityError.keychainOperationFailed(status) }
        guard let data = item as? Data else { throw TBSyncSecurityError.keychainUnexpectedData }
        return data
    }

    func save(_ data: Data) throws {
        var query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw TBSyncSecurityError.keychainOperationFailed(updateStatus) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TBSyncSecurityError.keychainOperationFailed(addStatus) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TBSyncSecurityError.keychainOperationFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

final class TBInMemoryDeviceSigningKeyStore: TBDeviceSigningKeyStoring {
    private var rawKey: Data?

    func loadSigningPrivateKey() throws -> Data? { rawKey }
    func saveSigningPrivateKey(_ rawRepresentation: Data) throws { rawKey = rawRepresentation }
}

extension TBInMemoryDeviceSigningKeyStore: TBSyncResettableStore {
    func resetSyncStorage() throws { rawKey = nil }
}

final class TBInMemorySyncGroupKeyStore: TBSyncGroupKeyStoring {
    private var records: [String: TBSyncGroupKeyRecord] = [:]

    func loadSyncGroupKey(groupID: String) throws -> TBSyncGroupKeyRecord? { records[groupID] }
    func saveSyncGroupKey(_ record: TBSyncGroupKeyRecord) throws { records[record.groupID] = record }
    func deleteSyncGroupKey(groupID: String) throws { records.removeValue(forKey: groupID) }
}

extension TBInMemorySyncGroupKeyStore: TBSyncResettableStore {
    func resetSyncStorage() throws { records.removeAll() }
}

final class TBInMemoryTrustedPeerStore: TBTrustedPeerStoring {
    private var records: [String: TBTrustedPeerRecord] = [:]

    init(records: [TBTrustedPeerRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.deviceID, $0) })
    }

    func trustedPeer(deviceID: String) throws -> TBTrustedPeerRecord? { records[deviceID] }
    func saveTrustedPeer(_ record: TBTrustedPeerRecord) throws { records[record.deviceID] = record }
    func deleteTrustedPeer(deviceID: String) throws { records.removeValue(forKey: deviceID) }
}

extension TBInMemoryTrustedPeerStore: TBSyncResettableStore {
    func resetSyncStorage() throws { records.removeAll() }
}

struct TBSyncGroupMetadataRecord: Codable, Equatable {
    let groupID: String
    var keyID: String
    var createdAt: Date
    var state: TBSyncGroupKeyState
}

protocol TBSyncGroupMetadataStoring {
    func loadSyncGroupMetadata(groupID: String) throws -> TBSyncGroupMetadataRecord?
    func loadAllSyncGroupMetadata() throws -> [TBSyncGroupMetadataRecord]
    func saveSyncGroupMetadata(_ record: TBSyncGroupMetadataRecord) throws
    func deleteSyncGroupMetadata(groupID: String) throws
}

extension TBSyncGroupMetadataStoring {
    func loadActiveSyncGroupMetadata() throws -> [TBSyncGroupMetadataRecord] {
        try loadAllSyncGroupMetadata().filter { $0.state == .active }
    }
}

final class TBInMemorySyncGroupMetadataStore: TBSyncGroupMetadataStoring, TBSyncResettableStore {
    private var records: [String: TBSyncGroupMetadataRecord] = [:]

    func loadSyncGroupMetadata(groupID: String) throws -> TBSyncGroupMetadataRecord? { records[groupID] }

    func loadAllSyncGroupMetadata() throws -> [TBSyncGroupMetadataRecord] {
        records.values.sorted { $0.groupID < $1.groupID }
    }

    func saveSyncGroupMetadata(_ record: TBSyncGroupMetadataRecord) throws { records[record.groupID] = record }

    func deleteSyncGroupMetadata(groupID: String) throws { records.removeValue(forKey: groupID) }

    func resetSyncStorage() throws { records.removeAll() }
}

final class TBFileTrustedPeerStore: TBTrustedPeerStoring, TBSyncResettableStore {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL = TBFileTrustedPeerStore.defaultFileURL()) {
        self.fileURL = fileURL
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func trustedPeer(deviceID: String) throws -> TBTrustedPeerRecord? {
        try loadAll()[deviceID]
    }

    func saveTrustedPeer(_ record: TBTrustedPeerRecord) throws {
        var records = try loadAll()
        records[record.deviceID] = record
        try write(records)
    }

    func deleteTrustedPeer(deviceID: String) throws {
        var records = try loadAll()
        records.removeValue(forKey: deviceID)
        try write(records)
    }

    func resetSyncStorage() throws {
        try FileManager.default.removeItemIfExists(at: fileURL)
    }

    private func loadAll() throws -> [String: TBTrustedPeerRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: try decoder.decode([TBTrustedPeerRecord].self,
                                                                    from: Data(contentsOf: fileURL)).map { ($0.deviceID, $0) })
    }

    private func write(_ records: [String: TBTrustedPeerRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ordered = records.values.sorted { $0.deviceID < $1.deviceID }
        try encoder.encode(ordered).write(to: fileURL, options: [.atomic])
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tomatt", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
        return baseURL.appendingPathComponent("trusted-peers.json")
    }
}

final class TBFileSyncGroupMetadataStore: TBSyncGroupMetadataStoring, TBSyncResettableStore {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL = TBFileSyncGroupMetadataStore.defaultFileURL()) {
        self.fileURL = fileURL
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func loadSyncGroupMetadata(groupID: String) throws -> TBSyncGroupMetadataRecord? {
        try loadAll()[groupID]
    }

    func loadAllSyncGroupMetadata() throws -> [TBSyncGroupMetadataRecord] {
        try loadAll().values.sorted { $0.groupID < $1.groupID }
    }

    func saveSyncGroupMetadata(_ record: TBSyncGroupMetadataRecord) throws {
        var records = try loadAll()
        records[record.groupID] = record
        try write(records)
    }

    func deleteSyncGroupMetadata(groupID: String) throws {
        var records = try loadAll()
        records.removeValue(forKey: groupID)
        try write(records)
    }

    func resetSyncStorage() throws {
        try FileManager.default.removeItemIfExists(at: fileURL)
    }

    private func loadAll() throws -> [String: TBSyncGroupMetadataRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: try decoder.decode([TBSyncGroupMetadataRecord].self,
                                                                    from: Data(contentsOf: fileURL)).map { ($0.groupID, $0) })
    }

    private func write(_ records: [String: TBSyncGroupMetadataRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ordered = records.values.sorted { $0.groupID < $1.groupID }
        try encoder.encode(ordered).write(to: fileURL, options: [.atomic])
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tomatt", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
        return baseURL.appendingPathComponent("group-metadata.json")
    }
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

protocol TBSignedSyncEventStoring {
    func saveSignedSyncEvent(_ event: TBSignedSyncEvent) throws
    func signedSyncEvent(eventID: UUID) throws -> TBSignedSyncEvent?
    func signedSyncEvent(originDeviceID: String, deviceSequence: Int64) throws -> TBSignedSyncEvent?
    func signedSyncEvents(originDeviceID: String, sequenceRange: ClosedRange<Int64>) throws -> [TBSignedSyncEvent]
    func hasSignedMetadata(for envelope: TBEventEnvelope) throws -> Bool
    func exportSignedSyncEvents() throws -> [TBSignedSyncEvent]
}

final class TBJSONLSignedSyncEventStore: TBSignedSyncEventStoring, TBSyncResettableStore {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL = TBJSONLSignedSyncEventStore.defaultFileURL()) {
        self.fileURL = fileURL
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func saveSignedSyncEvent(_ event: TBSignedSyncEvent) throws {
        if try signedSyncEvent(eventID: event.envelope.eventID) != nil { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let data = try encoder.encode(event) + Data([0x0A])
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func signedSyncEvent(eventID: UUID) throws -> TBSignedSyncEvent? {
        try exportSignedSyncEvents().first { $0.envelope.eventID == eventID }
    }

    func signedSyncEvent(originDeviceID: String, deviceSequence: Int64) throws -> TBSignedSyncEvent? {
        try signedSyncEvents(originDeviceID: originDeviceID, sequenceRange: deviceSequence...deviceSequence).first
    }

    func signedSyncEvents(originDeviceID: String, sequenceRange: ClosedRange<Int64>) throws -> [TBSignedSyncEvent] {
        try exportSignedSyncEvents().filter { event in
            event.envelope.originDeviceID == originDeviceID
                && event.envelope.deviceSequence.map { sequenceRange.contains($0) } == true
        }.sorted { ($0.envelope.deviceSequence ?? 0) < ($1.envelope.deviceSequence ?? 0) }
    }

    func hasSignedMetadata(for envelope: TBEventEnvelope) throws -> Bool {
        try signedSyncEvent(eventID: envelope.eventID) != nil
    }

    func exportSignedSyncEvents() throws -> [TBSignedSyncEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var byEventID: [UUID: TBSignedSyncEvent] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? decoder.decode(TBSignedSyncEvent.self, from: lineData) else { continue }
            byEventID[event.envelope.eventID] = event
        }
        return byEventID.values.sorted {
            if ($0.envelope.originDeviceID ?? "") == ($1.envelope.originDeviceID ?? "") {
                return ($0.envelope.deviceSequence ?? 0) < ($1.envelope.deviceSequence ?? 0)
            }
            return ($0.envelope.originDeviceID ?? "") < ($1.envelope.originDeviceID ?? "")
        }
    }

    func resetSyncStorage() throws {
        try FileManager.default.removeItemIfExists(at: fileURL)
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tomatt", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
        return baseURL.appendingPathComponent("signed-events.jsonl")
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

protocol TBSyncMembershipValidating {
    func validateMembership(for signedEvent: TBSignedSyncEvent, signer: TBTrustedPeerRecord) throws
}

struct TBTrustedPeerMembershipValidator: TBSyncMembershipValidating {
    func validateMembership(for _: TBSignedSyncEvent, signer: TBTrustedPeerRecord) throws {
        guard !signer.isRemoved else { throw TBSyncSecurityError.removedPeer(signer.deviceID) }
    }
}

struct TBSequenceCutoffMembershipValidator: TBSyncMembershipValidating {
    var activeThroughSequenceByDeviceID: [String: Int64]

    func validateMembership(for signedEvent: TBSignedSyncEvent, signer: TBTrustedPeerRecord) throws {
        guard !signer.isRemoved else { throw TBSyncSecurityError.removedPeer(signer.deviceID) }
        guard let deviceSequence = signedEvent.envelope.deviceSequence else {
            throw TBSyncSecurityError.invalidEventStructure
        }
        if let activeThroughSequence = activeThroughSequenceByDeviceID[signedEvent.signerDeviceID],
           deviceSequence > activeThroughSequence {
            throw TBSyncSecurityError.eventOutsideMembershipInterval(signedEvent.signerDeviceID)
        }
    }
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
    private let signedEventStore: TBSignedSyncEventStoring?
    private let membershipValidator: TBSyncMembershipValidating

    init(peerStore: TBTrustedPeerStoring,
         verifier: TBSyncEventSignatureVerifying,
         sink: TBSignedSyncEventImportSink,
         signedEventStore: TBSignedSyncEventStoring? = nil,
         membershipValidator: TBSyncMembershipValidating = TBTrustedPeerMembershipValidator()) {
        self.peerStore = peerStore
        self.verifier = verifier
        self.sink = sink
        self.signedEventStore = signedEventStore
        self.membershipValidator = membershipValidator
    }

    func importSignedEvents(_ signedEvents: [TBSignedSyncEvent],
                            context: TBAuthenticatedSyncContext) throws -> TBSyncImportOutcome {
        guard let transportPeer = try peerStore.trustedPeer(deviceID: context.peerDeviceID) else {
            throw TBSyncSecurityError.untrustedPeer(context.peerDeviceID)
        }
        guard !transportPeer.isRemoved else { throw TBSyncSecurityError.removedPeer(context.peerDeviceID) }
        guard transportPeer.signingKeyFingerprint == context.peerSigningKeyFingerprint else {
            throw TBSyncSecurityError.peerKeyMismatch
        }

        let envelopes = try signedEvents.map { signedEvent -> TBEventEnvelope in
            try verify(signedEvent)
            return signedEvent.envelope
        }
        do {
            try signedEvents.forEach { try signedEventStore?.saveSignedSyncEvent($0) }
        } catch {
            throw TBSyncSecurityError.signedMetadataPersistenceFailed
        }
        return sink.importAlreadyVerifiedEvents(envelopes)
    }

    private func verify(_ signedEvent: TBSignedSyncEvent) throws {
        guard signedEvent.signerDeviceID == signedEvent.envelope.originDeviceID else {
            throw TBSyncSecurityError.signerMismatch
        }
        guard let signer = try peerStore.trustedPeer(deviceID: signedEvent.signerDeviceID) else {
            throw TBSyncSecurityError.untrustedPeer(signedEvent.signerDeviceID)
        }
        try membershipValidator.validateMembership(for: signedEvent, signer: signer)
        guard signedEvent.signingPublicKey == signer.signingPublicKey,
              signedEvent.signingKeyFingerprint == signer.signingKeyFingerprint,
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

enum TBSyncStorageHealthStatus: Equatable {
    case ready
    case lanSyncDisabledRequiresPairing(String)
    case lanSyncDisabledRequiresReset(String)
}

struct TBSyncStorageHealth: Equatable {
    let status: TBSyncStorageHealthStatus

    var isReady: Bool { status == .ready }
    var isLANSyncEnabled: Bool { status == .ready }
    var isPairingSetupEligible: Bool { status == .ready }
}

final class TBSyncStorageHealthService {
    private let signingKeyStore: TBDeviceSigningKeyStoring
    private let groupKeyStore: TBSyncGroupKeyStoring
    private let metadataStore: TBSyncGroupMetadataStoring

    init(signingKeyStore: TBDeviceSigningKeyStoring,
          groupKeyStore: TBSyncGroupKeyStoring,
          metadataStore: TBSyncGroupMetadataStoring) {
        self.signingKeyStore = signingKeyStore
        self.groupKeyStore = groupKeyStore
        self.metadataStore = metadataStore
    }

    func health() -> TBSyncStorageHealth {
        lanSyncHealth()
    }

    func pairingSetupHealth() -> TBSyncStorageHealth {
        do {
            return try signingKeyHealth()
        } catch {
            return TBSyncStorageHealth(status: .lanSyncDisabledRequiresReset("sync storage error"))
        }
    }

    func lanSyncHealth() -> TBSyncStorageHealth {
        do {
            let signingHealth = try signingKeyHealth()
            guard signingHealth.isReady else { return signingHealth }

            let activeMetadata = try metadataStore.loadActiveSyncGroupMetadata()
            guard activeMetadata.count <= 1 else {
                return TBSyncStorageHealth(status: .lanSyncDisabledRequiresReset("multiple active sync groups"))
            }
            guard let metadata = activeMetadata.first else {
                return TBSyncStorageHealth(status: .lanSyncDisabledRequiresPairing("missing active sync group"))
            }
            guard let groupKey = try groupKeyStore.loadSyncGroupKey(groupID: metadata.groupID) else {
                return TBSyncStorageHealth(status: .lanSyncDisabledRequiresPairing("missing sync group key"))
            }
            guard groupKey.keyID == metadata.keyID, groupKey.isUsableForLANSync else {
                return TBSyncStorageHealth(status: .lanSyncDisabledRequiresPairing("unusable sync group key"))
            }
            return TBSyncStorageHealth(status: .ready)
        } catch {
            return TBSyncStorageHealth(status: .lanSyncDisabledRequiresReset("sync storage error"))
        }
    }

    private func signingKeyHealth() throws -> TBSyncStorageHealth {
        guard let rawKey = try signingKeyStore.loadSigningPrivateKey() else {
            return TBSyncStorageHealth(status: .lanSyncDisabledRequiresPairing("missing device signing key"))
        }
        guard (try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)) != nil else {
            return TBSyncStorageHealth(status: .lanSyncDisabledRequiresReset("corrupt device signing key"))
        }
        return TBSyncStorageHealth(status: .ready)
    }
}

final class TBSyncStorageResetService {
    private let stores: [TBSyncResettableStore]

    init(stores: [TBSyncResettableStore]) {
        self.stores = stores
    }

    func resetSync(preservingRawEventsAt rawEventLogURL: URL? = nil) throws {
        let rawEventsExisted = rawEventLogURL.map { FileManager.default.fileExists(atPath: $0.path) }
        for store in stores { try store.resetSyncStorage() }
        if let rawEventLogURL, rawEventsExisted == true,
           !FileManager.default.fileExists(atPath: rawEventLogURL.path) {
            throw TBSyncSecurityError.resetDeletedRawEventLog
        }
    }
}

enum TBSyncSecurityError: Error, Equatable {
    case invalidSyncGroupKey
    case keychainOperationFailed(OSStatus)
    case keychainUnexpectedData
    case untrustedPeer(String)
    case removedPeer(String)
    case peerKeyMismatch
    case signerMismatch
    case invalidEventStructure
    case invalidSignature
    case resetDeletedRawEventLog
    case eventOutsideMembershipInterval(String)
    case signedMetadataPersistenceFailed
}

private extension Data {
    var tbSyncHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        do {
            try removeItem(at: url)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == CocoaError.fileNoSuchFile.rawValue {
                return
            }
            throw error
        }
    }
}

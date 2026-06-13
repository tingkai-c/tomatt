import CryptoKit
import Foundation

/// Core model for verified LAN pairing. This file is UI- and transport-server
/// independent: discovery/connection code supplies transcript facts, UI later
/// displays the derived code and preview, and persistence occurs only through
/// `TBPairingCommitApplying` after both user gates have passed.

enum TBPairingRole: String, Codable, Equatable {
    case addDevice = "add-device"
    case joinSyncGroup = "join-sync-group"
}

enum TBPairDeviceUserAction: String, Codable, Equatable {
    case pairDevice = "pair-device"

    var title: String { "Pair Device" }
}

struct TBPairDeviceFlowModel: Equatable {
    let primaryAction: TBPairDeviceUserAction = .pairDevice
    let internalRole: TBPairingRole

    var primaryActionTitle: String { primaryAction.title }

    /// G005 intentionally exposes one user-facing Pair Device flow. The
    /// deterministic add/join split remains internal transcript state only.
    var exposesTopLevelAddOrJoinActions: Bool { false }
}

struct TBPairingRuntimeFlowID: RawRepresentable, Hashable, Codable, Equatable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func random() -> TBPairingRuntimeFlowID {
        TBPairingRuntimeFlowID(rawValue: UUID().uuidString.lowercased())
    }
}

enum TBPairingGroupState: Codable, Equatable {
    case standalone
    case grouped(groupID: String)
}

enum TBPairingGroupCompatibility: Equatable {
    case createNewSyncGroup
    case joinExistingGroup(groupID: String)
    case sameGroup(groupID: String)
}

enum TBPairingGroupCompatibilityError: Error, Equatable {
    case differentGroups(localGroupID: String, remoteGroupID: String, guidance: String)
}

enum TBPairingGroupCompatibilityRules {
    static let resetGuidance = "Reset sync on one device before pairing devices that already belong to different Sync Groups."

    static func evaluate(local: TBPairingGroupState, remote: TBPairingGroupState) throws -> TBPairingGroupCompatibility {
        switch (local, remote) {
        case (.standalone, .standalone):
            return .createNewSyncGroup
        case (.grouped(let groupID), .standalone), (.standalone, .grouped(let groupID)):
            return .joinExistingGroup(groupID: groupID)
        case (.grouped(let localGroupID), .grouped(let remoteGroupID)) where localGroupID == remoteGroupID:
            return .sameGroup(groupID: localGroupID)
        case (.grouped(let localGroupID), .grouped(let remoteGroupID)):
            throw TBPairingGroupCompatibilityError.differentGroups(localGroupID: localGroupID,
                                                                   remoteGroupID: remoteGroupID,
                                                                   guidance: resetGuidance)
        }
    }
}

struct TBPairingIdleDeclaration: Codable, Equatable {
    var isIdle: Bool
    var declaredAt: Date
    var reason: String?

    static func idle(at date: Date) -> TBPairingIdleDeclaration {
        TBPairingIdleDeclaration(isIdle: true, declaredAt: date, reason: nil)
    }

    static func busy(at date: Date, reason: String) -> TBPairingIdleDeclaration {
        TBPairingIdleDeclaration(isIdle: false, declaredAt: date, reason: reason)
    }
}

enum TBPairingGateError: Error, Equatable {
    case localNotIdle
    case remoteNotIdle
    case expired
    case cancelled
    case codeMismatch
    case codeNotConfirmed
    case previewNotApproved
    case settingsSourceRequired
    case invalidState
}

enum TBPairingSessionState: Equatable {
    case initialized
    case awaitingCodeConfirmation(code: String)
    case codeConfirmed
    case previewApproved
    case committed
    case cancelled
    case expired
}

struct TBPairingEndpointMetadata: Codable, Equatable {
    var host: String
    var port: Int
    var transport: String
    var path: String
    var metadata: [String: String]
}

struct TBPairingTranscriptParticipant: Codable, Equatable {
    var deviceID: String
    var displayName: String
    var platform: String
    var ephemeralPairingPublicKey: Data
    var signingPublicKey: Data
    var ephemeralDiscoveryID: String
    var endpoint: TBPairingEndpointMetadata
    var idle: TBPairingIdleDeclaration
    var capabilities: [String]
    var groupState: TBPairingGroupState
}

struct TBPairingTranscript: Codable, Equatable {
    static let canonicalVersion = 1

    var protocolVersion: Int
    var role: TBPairingRole
    var local: TBPairingTranscriptParticipant
    var remote: TBPairingTranscriptParticipant
    var timestamp: Date
    var sessionNonce: Data
    var capabilities: [String]

    /// v1 deterministic transcript encoding: sorted-key JSON, ISO-8601 dates,
    /// base64 Data values, and sorted capability/metadata collections. This is a
    /// stable G005 model contract, not the final encrypted-session transcript.
    func canonicalBytes() throws -> Data {
        let canonical = CanonicalTranscript(
            canonicalVersion: Self.canonicalVersion,
            protocolVersion: protocolVersion,
            addDeviceParticipant: CanonicalParticipant(addDeviceParticipant),
            joinSyncGroupParticipant: CanonicalParticipant(joinSyncGroupParticipant),
            timestamp: Self.iso8601(timestamp),
            sessionNonceBase64: sessionNonce.base64EncodedString(),
            capabilities: capabilities.sorted(),
            groupCompatibility: try Self.canonicalGroupCompatibility(local: local.groupState, remote: remote.groupState)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(canonical)
    }

    func verificationCode() throws -> String {
        try TBPairingVerificationCode.derive(fromCanonicalTranscriptBytes: canonicalBytes())
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func canonicalGroupCompatibility(local: TBPairingGroupState, remote: TBPairingGroupState) throws -> String {
        switch try TBPairingGroupCompatibilityRules.evaluate(local: local, remote: remote) {
        case .createNewSyncGroup:
            return "create-new-sync-group"
        case .joinExistingGroup(let groupID):
            return "join-existing-group:\(groupID)"
        case .sameGroup(let groupID):
            return "same-group:\(groupID)"
        }
    }

    private var addDeviceParticipant: TBPairingTranscriptParticipant {
        role == .addDevice ? local : remote
    }

    private var joinSyncGroupParticipant: TBPairingTranscriptParticipant {
        role == .addDevice ? remote : local
    }

    var localSessionRole: TBSyncSessionRole {
        role == .addDevice ? .initiator : .responder
    }

    var addDevicePublicKeyForKeyID: Data { addDeviceParticipant.ephemeralPairingPublicKey }

    var joinSyncGroupPublicKeyForKeyID: Data { joinSyncGroupParticipant.ephemeralPairingPublicKey }

    private struct CanonicalTranscript: Encodable {
        let canonicalVersion: Int
        let protocolVersion: Int
        let addDeviceParticipant: CanonicalParticipant
        let joinSyncGroupParticipant: CanonicalParticipant
        let timestamp: String
        let sessionNonceBase64: String
        let capabilities: [String]
        let groupCompatibility: String
    }

    private struct CanonicalParticipant: Encodable {
        let deviceID: String
        let displayName: String
        let platform: String
        let ephemeralPairingPublicKeyBase64: String
        let signingPublicKeyBase64: String
        let ephemeralDiscoveryID: String
        let endpoint: CanonicalEndpoint
        let idle: CanonicalIdle
        let capabilities: [String]
        let groupState: CanonicalGroupState

        init(_ participant: TBPairingTranscriptParticipant) {
            deviceID = participant.deviceID
            displayName = participant.displayName
            platform = participant.platform
            ephemeralPairingPublicKeyBase64 = participant.ephemeralPairingPublicKey.base64EncodedString()
            signingPublicKeyBase64 = participant.signingPublicKey.base64EncodedString()
            ephemeralDiscoveryID = participant.ephemeralDiscoveryID
            endpoint = CanonicalEndpoint(participant.endpoint)
            idle = CanonicalIdle(participant.idle)
            capabilities = participant.capabilities.sorted()
            groupState = CanonicalGroupState(participant.groupState)
        }
    }

    private struct CanonicalGroupState: Encodable {
        let kind: String
        let groupID: String?

        init(_ state: TBPairingGroupState) {
            switch state {
            case .standalone:
                kind = "standalone"
                groupID = nil
            case .grouped(let groupID):
                kind = "grouped"
                self.groupID = groupID
            }
        }
    }

    private struct CanonicalEndpoint: Encodable {
        let host: String
        let port: Int
        let transport: String
        let path: String
        let metadata: [String: String]

        init(_ endpoint: TBPairingEndpointMetadata) {
            host = endpoint.host
            port = endpoint.port
            transport = endpoint.transport
            path = endpoint.path
            metadata = endpoint.metadata
        }
    }

    private struct CanonicalIdle: Encodable {
        let isIdle: Bool
        let declaredAt: String
        let reason: String?

        init(_ idle: TBPairingIdleDeclaration) {
            isIdle = idle.isIdle
            declaredAt = TBPairingTranscript.iso8601(idle.declaredAt)
            reason = idle.reason
        }
    }
}

enum TBPairingVerificationCode {
    static func derive(fromCanonicalTranscriptBytes bytes: Data) -> String {
        let digest = Array(SHA256.hash(data: bytes))
        let first31Bits = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) & 0x7fff_ffff
        return String(format: "%06u", first31Bits % 1_000_000)
    }
}

struct TBPairingEphemeralKeyPair {
    private let privateKey: P256.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    init() {
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    init(rawPrivateKeyRepresentation: Data) throws {
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKeyRepresentation)
    }

    func deriveSessionEstablishment(localTranscript: TBPairingTranscript) throws -> TBPairingSessionEstablishment {
        guard publicKey == localTranscript.local.ephemeralPairingPublicKey else {
            throw TBPairingKeyAgreementError.localPublicKeyMismatch
        }
        _ = try TBPairingGroupCompatibilityRules.evaluate(local: localTranscript.local.groupState,
                                                          remote: localTranscript.remote.groupState)
        let remotePublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: localTranscript.remote.ephemeralPairingPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        let canonicalTranscript = try localTranscript.canonicalBytes()
        let salt = SHA256.hash(data: canonicalTranscript)
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                              salt: Data(salt),
                                                              sharedInfo: Data("tomatt-pairing-session-key-v1".utf8),
                                                              outputByteCount: 32)
        let initiatorNonceSeed = sharedSecret.hkdfDerivedData(salt: Data(salt),
                                                              sharedInfo: Data("tomatt-pairing-initiator-nonce-v1".utf8),
                                                              outputByteCount: 32)
        let responderNonceSeed = sharedSecret.hkdfDerivedData(salt: Data(salt),
                                                              sharedInfo: Data("tomatt-pairing-responder-nonce-v1".utf8),
                                                              outputByteCount: 32)
        let localNonceSeed = localTranscript.localSessionRole == .initiator ? initiatorNonceSeed : responderNonceSeed
        let peerNonceSeed = localTranscript.localSessionRole == .initiator ? responderNonceSeed : initiatorNonceSeed
        let keyIDMaterial = canonicalTranscript
            + localTranscript.addDevicePublicKeyForKeyID
            + localTranscript.joinSyncGroupPublicKeyForKeyID
            + Data("tomatt-pairing-key-id-v1".utf8)
        let keyID = "pairing-v1-" + Data(SHA256.hash(data: keyIDMaterial)).tbPairingHexString.prefixString(16)

        return TBPairingSessionEstablishment(keyMaterial: TBSessionKeyMaterial(keyID: keyID, symmetricKey: sessionKey),
                                             localRole: localTranscript.localSessionRole,
                                             localNonceSeed: localNonceSeed,
                                             peerNonceSeed: peerNonceSeed)
    }
}

struct TBPairingSessionEstablishment {
    let keyMaterial: TBSessionKeyMaterial
    let localRole: TBSyncSessionRole
    let localNonceSeed: Data
    let peerNonceSeed: Data

    func makeCryptoBox(context: TBAuthenticatedPeerContext) -> TBSyncSessionCryptoBox {
        TBSyncSessionCryptoBox(context: context,
                               keyMaterial: keyMaterial,
                               localRole: localRole,
                               localNonceSeed: localNonceSeed,
                               peerNonceSeed: peerNonceSeed)
    }
}

enum TBPairingKeyAgreementError: Error, Equatable {
    case localPublicKeyMismatch
}

enum TBPairingSettingsSourceChoice: String, Codable, Equatable {
    case keepLocal = "keep-local"
    case useRemote = "use-remote"
}

struct TBPairingHistorySummary: Codable, Equatable {
    var eventCount: Int
    var dateRangeStart: Date?
    var dateRangeEnd: Date?
}

struct TBPairingPreMergePreview: Codable, Equatable {
    var localDevice: TBDeviceIdentity
    var remoteDevice: TBDeviceIdentity
    var bothIdle: Bool
    var settingsDiffer: Bool
    var localPresetCount: Int
    var remotePresetCount: Int
    var localHistory: TBPairingHistorySummary
    var remoteHistory: TBPairingHistorySummary
    var settingsSourceChoice: TBPairingSettingsSourceChoice?
}

enum TBPairingMembershipAction: Codable, Equatable {
    case devicePaired(deviceID: String, displayName: String)
    case deviceJoinedGroup(deviceID: String, groupID: String)
}

struct TBPairingStagedCommit: Equatable {
    var trustedPeer: TBTrustedPeerRecord
    var syncGroupKey: TBSyncGroupKeyRecord
    var membershipActions: [TBPairingMembershipAction]
    var importedEvents: [TBEventEnvelope]
    var settingsSourceChoice: TBPairingSettingsSourceChoice
}

protocol TBPairingCommitApplying {
    /// Applies the already staged pairing result as one durable transaction.
    /// Implementations must write nothing if any action cannot be persisted.
    func applyPairingCommit(_ commit: TBPairingStagedCommit) throws
}

final class TBInMemoryPairingCommitApplier: TBPairingCommitApplying {
    private(set) var appliedCommits: [TBPairingStagedCommit] = []
    private(set) var trustedPeers: [TBTrustedPeerRecord] = []
    private(set) var syncGroupKeys: [TBSyncGroupKeyRecord] = []
    private(set) var membershipActions: [TBPairingMembershipAction] = []
    private(set) var importedEvents: [TBEventEnvelope] = []
    var failure: Error?

    func applyPairingCommit(_ commit: TBPairingStagedCommit) throws {
        if let failure = failure { throw failure }
        var nextTrustedPeers = trustedPeers
        var nextSyncGroupKeys = syncGroupKeys
        var nextMembershipActions = membershipActions
        var nextImportedEvents = importedEvents
        var nextAppliedCommits = appliedCommits
        nextTrustedPeers.append(commit.trustedPeer)
        nextSyncGroupKeys.append(commit.syncGroupKey)
        nextMembershipActions.append(contentsOf: commit.membershipActions)
        nextImportedEvents.append(contentsOf: commit.importedEvents)
        nextAppliedCommits.append(commit)
        trustedPeers = nextTrustedPeers
        syncGroupKeys = nextSyncGroupKeys
        membershipActions = nextMembershipActions
        importedEvents = nextImportedEvents
        appliedCommits = nextAppliedCommits
    }
}

final class TBPairingSession {
    private(set) var state: TBPairingSessionState = .initialized
    private(set) var transcript: TBPairingTranscript
    let expiresAt: Date
    private var stagedCommit: TBPairingStagedCommit
    private var approvedPreview: TBPairingPreMergePreview?

    init(transcript: TBPairingTranscript,
         stagedCommit: TBPairingStagedCommit,
         expiresAt: Date) {
        self.transcript = transcript
        self.stagedCommit = stagedCommit
        self.expiresAt = expiresAt
    }

    func updateIdleDeclarations(local: TBPairingIdleDeclaration, remote: TBPairingIdleDeclaration) {
        transcript.local.idle = local
        transcript.remote.idle = remote
    }

    func start(now: Date) throws -> String {
        try ensureActive(now: now)
        try ensureIdle(transcript.local.idle, transcript.remote.idle)
        let code = try transcript.verificationCode()
        state = .awaitingCodeConfirmation(code: code)
        return code
    }

    func confirmCode(_ code: String, now: Date) throws {
        try ensureActive(now: now)
        guard case .awaitingCodeConfirmation(let expected) = state else {
            throw TBPairingGateError.invalidState
        }
        guard code == expected else { throw TBPairingGateError.codeMismatch }
        state = .codeConfirmed
    }

    func approvePreview(_ preview: TBPairingPreMergePreview, now: Date) throws {
        try ensureActive(now: now)
        guard state == .codeConfirmed else { throw TBPairingGateError.codeNotConfirmed }
        guard preview.bothIdle else { throw TBPairingGateError.remoteNotIdle }
        guard let settingsSourceChoice = preview.settingsSourceChoice else {
            throw TBPairingGateError.settingsSourceRequired
        }
        stagedCommit.settingsSourceChoice = settingsSourceChoice
        approvedPreview = preview
        state = .previewApproved
    }

    func commit(using applier: TBPairingCommitApplying, now: Date) throws {
        try ensureActive(now: now)
        guard state == .previewApproved else { throw TBPairingGateError.previewNotApproved }
        guard let approvedPreview = approvedPreview else { throw TBPairingGateError.previewNotApproved }
        try ensureIdle(transcript.local.idle, transcript.remote.idle)
        guard approvedPreview.bothIdle else { throw TBPairingGateError.remoteNotIdle }
        try applier.applyPairingCommit(stagedCommit)
        state = .committed
    }

    func cancel() {
        state = .cancelled
        approvedPreview = nil
    }

    var stagedSyncGroupID: String {
        stagedCommit.syncGroupKey.groupID
    }

    func retry(expiresAt: Date) -> TBPairingSession {
        TBPairingSession(transcript: transcript, stagedCommit: stagedCommit, expiresAt: expiresAt)
    }

    private func ensureActive(now: Date) throws {
        if state == .cancelled { throw TBPairingGateError.cancelled }
        if state == .expired || now >= expiresAt {
            state = .expired
            throw TBPairingGateError.expired
        }
        if state == .committed { throw TBPairingGateError.invalidState }
    }

    private func ensureIdle(_ local: TBPairingIdleDeclaration, _ remote: TBPairingIdleDeclaration) throws {
        guard local.isIdle else { throw TBPairingGateError.localNotIdle }
        guard remote.isIdle else { throw TBPairingGateError.remoteNotIdle }
    }
}

private extension SharedSecret {
    func hkdfDerivedData(salt: Data, sharedInfo: Data, outputByteCount: Int) -> Data {
        let key = hkdfDerivedSymmetricKey(using: SHA256.self,
                                          salt: salt,
                                          sharedInfo: sharedInfo,
                                          outputByteCount: outputByteCount)
        return key.withUnsafeBytes { Data($0) }
    }
}

private extension Data {
    var tbPairingHexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    func prefixString(_ count: Int) -> String { String(prefix(count)) }
}

import Combine
import CryptoKit
import Foundation
import SwiftProtobuf

enum TBSyncServiceRuntimeMode: Equatable {
    case syncOff
    case pairingSetup
    case lanSync
}

enum TBSyncServiceActionResult: Equatable {
    case started(String)
    case stopped(String)
    case blocked(String)
    case reset(String)
}

struct TBPairingFlowPresentation: Identifiable, Equatable {
    let id: TBPairingRuntimeFlowID
    let remoteDisplayName: String
    let verificationCode: String?
    let preview: TBPairingPreMergePreview?

    var isAwaitingVerificationConfirmation: Bool { verificationCode != nil }
    var isAwaitingPreviewApproval: Bool { preview != nil }
}

struct TBSyncServiceSnapshot: Equatable {
    var selectedMode: TBSyncMode
    var runtimeMode: TBSyncServiceRuntimeMode
    var pairedDevices: [TBPairedSyncDevice]
    var capabilityGates: TBSyncCapabilityGates
    var deviceName: String
    var deviceIdentity: String
    var lastSync: Date?
    var retryStatus: String?
    var listenerPort: Int
    var storageHealthStatus: TBSyncStorageHealthStatus
    var correctionNotice: String?
    var statusMessage: String?
    var actionMessage: String?
    var resetAvailable: Bool
    var activePairingFlows: [TBPairingFlowPresentation]

    static func preview(capabilityGates: TBSyncCapabilityGates = .currentProductizedSurface) -> TBSyncServiceSnapshot {
        TBSyncServiceSnapshot(selectedMode: .off,
                              runtimeMode: .syncOff,
                              pairedDevices: [],
                              capabilityGates: capabilityGates,
                              deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                              deviceIdentity: "Local preview identity",
                              lastSync: nil,
                              retryStatus: nil,
                              listenerPort: LANTransportInternalPlaintext.defaultPort,
                              storageHealthStatus: .ready,
                              correctionNotice: nil,
                              statusMessage: nil,
                              actionMessage: nil,
                              resetAvailable: false,
                              activePairingFlows: [])
    }
}

@MainActor
protocol TBSyncServiceProviding: AnyObject {
    var snapshot: TBSyncServiceSnapshot { get }
    @discardableResult func selectMode(_ mode: TBSyncMode) -> TBSyncServiceActionResult
    @discardableResult func startPairDevice() -> TBSyncServiceActionResult
    @discardableResult func pairByAddress(host: String, port: Int) -> TBSyncServiceActionResult
    @discardableResult func confirmVerificationCode(flowID: TBPairingRuntimeFlowID) -> TBSyncServiceActionResult
    @discardableResult func approvePreview(flowID: TBPairingRuntimeFlowID, settingsSource: TBPairingSettingsSourceChoice) -> TBSyncServiceActionResult
    @discardableResult func resetSync() -> TBSyncServiceActionResult
    @discardableResult func removeDevice(id: UUID) -> TBSyncServiceActionResult
}

protocol TBSyncRuntimeHealthChecking {
    func pairingSetupHealth() -> TBSyncStorageHealth
    func lanSyncHealth() -> TBSyncStorageHealth
}

extension TBSyncStorageHealthService: TBSyncRuntimeHealthChecking {}

protocol TBSyncStorageResetting {
    func resetSync(preservingRawEventsAt rawEventLogURL: URL?) throws
}

extension TBSyncStorageResetService: TBSyncStorageResetting {}

protocol TBSyncRuntimeCoordinating: AnyObject {
    var peers: [String: TBSyncRuntimePeer] { get }
    var remoteImportHandler: ((String, String) -> Void)? { get set }
    @discardableResult func setMode(_ newMode: TBSyncRuntimeMode, discoveryID: LANDiscoveryID) -> Bool
    func registerEngine(_ engine: TBSyncPeerEngine, for deviceID: String, displayName: String?)
    func markDiscovered(deviceID: String, displayName: String, lastSeenAt: Date?)
    @discardableResult func beginConnection(to deviceID: String) -> Bool
    func beginPairing(deviceID: String)
    func triggerConnectionEstablishedSync(deviceID: String) -> [TBEncryptedLANMessage]
    func triggerLocalSyncableEventAppended() -> [TBEncryptedLANMessage]
    func markRemoved(deviceID: String, displayName: String?)
    func resetRuntimeState()
}

extension TBSyncRuntimeCoordinator: TBSyncRuntimeCoordinating {}

protocol TBPairingCommitPersisting {
    var peerStoreForContext: TBTrustedPeerStoring { get }
    func activePairingGroupState() throws -> TBPairingGroupState
    func persistPairingCommit(_ commit: TBPairingStagedCommit) throws
}

extension TBPairingCommitPersisting {
    func activePairingGroupState() throws -> TBPairingGroupState { .standalone }

    func applyPairingCommit(_ commit: TBPairingStagedCommit) throws {
        try persistPairingCommit(commit)
    }
}

extension TBPairingCommitPersisting where Self: TBPairingCommitApplying {}

protocol TBSyncPeerEngineMaking {
    func makeEngine(session: TBSyncSessionCryptoBox) throws -> TBSyncPeerEngine
}

@MainActor
protocol TBTimerSyncRefreshing: AnyObject {
    func reloadFromEventLogAfterSync(trustedDeviceName: String)
}

struct TBPairingRuntimeFlow {
    let id: TBPairingRuntimeFlowID
    let session: TBPairingSession
    let establishment: TBPairingSessionEstablishment
    let lanSession: LANWebSocketSession?
}

private struct TBLocalPairingWireArtifacts {
    let role: TBPairingRole
    let keyPair: TBPairingEphemeralKeyPair
    let participant: TBPairingTranscriptParticipant
    let sessionNonce: Data
    let startEnvelope: Tomatt_Sync_V1_Envelope
    let challengeEnvelope: Tomatt_Sync_V1_Envelope
}

private enum TBPairingWireTranscriptError: Error, Equatable {
    case invalidParticipant(String)
}

final class TBPairingRuntimeCoordinator {
    private var flows: [TBPairingRuntimeFlowID: TBPairingRuntimeFlow] = [:]
    private(set) var activeSessions: [ObjectIdentifier: LANWebSocketSession] = [:]

    func retain(_ flow: TBPairingRuntimeFlow) {
        flows[flow.id] = flow
    }

    func flow(id: TBPairingRuntimeFlowID) -> TBPairingRuntimeFlow? {
        flows[id]
    }

    var retainedFlows: [TBPairingRuntimeFlow] {
        flows.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func remove(id: TBPairingRuntimeFlowID) {
        flows.removeValue(forKey: id)
    }

    func markPairingSessionActive(_ session: LANWebSocketSession) {
        activeSessions[ObjectIdentifier(session)] = session
    }

    func hasActivePairingSession(_ session: LANWebSocketSession) -> Bool {
        activeSessions[ObjectIdentifier(session)] != nil
    }

    func reset() {
        flows.removeAll()
        activeSessions.values.forEach { $0.close() }
        activeSessions.removeAll()
    }
}

@MainActor
final class TBSyncService: ObservableObject, TBSyncServiceProviding {
    struct Dependencies {
        var lanRuntime: TBSyncLANRuntimeControlling
        var coordinator: TBSyncRuntimeCoordinating
        var router: TBLANEncryptedSessionRouter?
        var healthChecker: TBSyncRuntimeHealthChecking
        var resetService: TBSyncStorageResetting?
        var manualConnector: LANWebSocketConnecting?
        var pairingRuntime: TBPairingRuntimeCoordinator
        var pairingCommitPersister: TBPairingCommitPersisting?
        var localIdentity: TBSyncDevicePublicIdentity?
        var engineMaker: TBSyncPeerEngineMaking?
        var eventLog: TBLocalEventLog?
        var timerSyncRefresher: TBTimerSyncRefreshing?
        var capabilityGates: TBSyncCapabilityGates
        var deviceName: String
        var deviceIdentity: String
        var listenerPort: Int
    }

    @Published private(set) var snapshot: TBSyncServiceSnapshot

    private let lanRuntime: TBSyncLANRuntimeControlling
    private let coordinator: TBSyncRuntimeCoordinating
    private let router: TBLANEncryptedSessionRouter?
    private let healthChecker: TBSyncRuntimeHealthChecking
    private let resetService: TBSyncStorageResetting?
    private let manualConnector: LANWebSocketConnecting?
    private let pairingRuntime: TBPairingRuntimeCoordinator
    private let pairingCommitPersister: TBPairingCommitPersisting?
    private let localIdentity: TBSyncDevicePublicIdentity?
    private let engineMaker: TBSyncPeerEngineMaking?
    private weak var timerSyncRefresher: TBTimerSyncRefreshing?
    private var retainedManualPairingSessions: [LANWebSocketSession] = []
    private var pairingArtifacts: [ObjectIdentifier: TBLocalPairingWireArtifacts] = [:]

    init(dependencies: Dependencies? = nil) {
        let dependencies = dependencies ?? TBSyncService.defaultDependencies()
        self.lanRuntime = dependencies.lanRuntime
        self.coordinator = dependencies.coordinator
        self.router = dependencies.router
        self.healthChecker = dependencies.healthChecker
        self.resetService = dependencies.resetService
        self.manualConnector = dependencies.manualConnector
        self.pairingRuntime = dependencies.pairingRuntime
        self.pairingCommitPersister = dependencies.pairingCommitPersister
        self.localIdentity = dependencies.localIdentity
        self.engineMaker = dependencies.engineMaker
        self.timerSyncRefresher = dependencies.timerSyncRefresher
        self.snapshot = TBSyncServiceSnapshot(selectedMode: .off,
                                              runtimeMode: .syncOff,
                                              pairedDevices: [],
                                              capabilityGates: dependencies.capabilityGates,
                                              deviceName: dependencies.deviceName,
                                              deviceIdentity: dependencies.deviceIdentity,
                                              lastSync: nil,
                                              retryStatus: nil,
                                              listenerPort: dependencies.listenerPort,
                                               storageHealthStatus: dependencies.healthChecker.lanSyncHealth().status,
                                               correctionNotice: nil,
                                               statusMessage: nil,
                                               actionMessage: nil,
                                               resetAvailable: dependencies.resetService != nil,
                                               activePairingFlows: [])
        dependencies.eventLog?.onLocalSyncableEventAppended = { [weak self] in
            Task { @MainActor in self?.syncLocalEventAppendToActiveSessions() }
        }
        self.coordinator.remoteImportHandler = { [weak self] _, displayName in
            Task { @MainActor in self?.handleRemoteImport(from: displayName) }
        }
        self.lanRuntime.onPeerDiscovered = { [weak self] peer in
            TBSyncService.performOnMainActor { self?.handleDiscoveredPeer(peer) }
        }
        self.router?.pairingEnvelopeHandler = { [weak self] envelope, session in
            guard let self else { return false }
            return self.handlePairingEnvelope(envelope, from: session)
        }
        refreshDeviceRows()
    }

    func syncLocalEventAppendToActiveSessions() {
        let messages = coordinator.triggerLocalSyncableEventAppended()
        let grouped = Dictionary(grouping: messages, by: \.recipientDeviceID)
        for (peerID, peerMessages) in grouped {
            router?.send(messages: peerMessages, to: peerID)
        }
    }

    private func handleRemoteImport(from trustedDeviceName: String) {
        snapshot.lastSync = Date()
        snapshot.statusMessage = "Synced with \(trustedDeviceName)."
        timerSyncRefresher?.reloadFromEventLogAfterSync(trustedDeviceName: trustedDeviceName)
        refreshDeviceRows()
    }

    @discardableResult
    func selectMode(_ mode: TBSyncMode) -> TBSyncServiceActionResult {
        switch mode {
        case .off:
            stopLAN(message: "Sync is off.")
            return .stopped("Sync is off.")
        case .lanOnly:
            return startLanSync()
        case .lanAndCloudRelay:
            let message = "Cloud Relay is planned for a future release and is unavailable in this build."
            snapshot.actionMessage = message
            return .blocked(message)
        }
    }

    @discardableResult
    func startPairDevice() -> TBSyncServiceActionResult {
        startPairingSetup(message: "Pairing setup is active. Waiting for a nearby device to enter the pairing runtime flow.")
    }

    @discardableResult
    func pairByAddress(host: String, port: Int) -> TBSyncServiceActionResult {
        let setupResult = startPairingSetup(message: "Pairing setup is active. Manual pairing connection is entering the pairing/runtime flow.")
        guard case .started = setupResult else { return setupResult }
        guard let manualConnector else {
            let message = "Manual pairing is unavailable because LAN connector infrastructure is not available."
            snapshot.actionMessage = message
            return .blocked(message)
        }

        do {
            let endpoint = try LANManualEndpoint(host: host, port: port)
            manualConnector.connect(to: endpoint) { [weak self] result in
                TBSyncService.performOnMainActor {
                    guard let self else { return }
                    switch result {
                    case .success(let session):
                        self.retainedManualPairingSessions.append(session)
                        if let peerID = self.peerIDForManualEndpoint(endpoint), self.initiateOutboundResume(session: session, peerID: peerID) {
                            self.snapshot.actionMessage = "Connected to paired peer \(peerID). Resume handshake started."
                        } else {
                            self.startPairingWireFlow(session: session, endpoint: endpoint)
                            self.snapshot.actionMessage = "Connected to \(endpoint.host):\(endpoint.port). Pairing runtime flow is active and awaiting peer verification data."
                        }
                    case .failure(let error):
                        self.snapshot.actionMessage = "Manual pairing connection failed: \(error.localizedDescription)"
                    }
                }
            }
            return .started("Manual pairing connection started for \(endpoint.host):\(endpoint.port).")
        } catch {
            let message = "The pairing address is invalid."
            snapshot.actionMessage = message
            return .blocked(message)
        }
    }

    func retainPairingRuntimeFlow(_ flow: TBPairingRuntimeFlow) {
        pairingRuntime.retain(flow)
        refreshPairingFlowPresentations()
        snapshot.actionMessage = "Pairing verification is ready for \(flow.session.transcript.remote.displayName)."
    }

    @discardableResult
    func commitPairingRuntimeFlow(id: TBPairingRuntimeFlowID, now: Date = Date()) -> TBSyncServiceActionResult {
        guard let flow = pairingRuntime.flow(id: id) else {
            let message = "Pairing flow is no longer available."
            snapshot.actionMessage = message
            return .blocked(message)
        }
        guard let pairingCommitPersister, let localIdentity, let engineMaker else {
            let message = "Pairing commit is unavailable because sync runtime dependencies are not ready."
            snapshot.actionMessage = message
            return .blocked(message)
        }

        do {
            try flow.session.commit(using: TBPairingCommitPersisterAdapter(persister: pairingCommitPersister), now: now)
            let peerID = flow.session.transcript.remote.deviceID
            let committedGroupID = flow.session.stagedSyncGroupID
            let context = try TBAuthenticatedPeerContextBuilder.build(localIdentity: localIdentity,
                                                                       peerDeviceID: peerID,
                                                                       peerStore: pairingCommitPersister.peerStoreForContext)
            let cryptoBox = flow.establishment.makeCryptoBox(context: context)
            let engine = try engineMaker.makeEngine(session: cryptoBox)
            coordinator.registerEngine(engine, for: peerID, displayName: flow.session.transcript.remote.displayName)
            if let lanSession = flow.lanSession, let router {
                router.setSessionContext(TBLANEncryptedSessionContext(peerID: peerID,
                                                                      displayName: flow.session.transcript.remote.displayName,
                                                                       sessionKeyID: cryptoBox.transcript.keyID,
                                                                       sessionNonceSeed: flow.establishment.localNonceSeed,
                                                                       peerRole: flow.establishment.localRole == .initiator ? .responder : .initiator,
                                                                       syncGroupID: committedGroupID))
                router.bind(session: lanSession, to: peerID, direction: .outbound, establishedAt: now)
                router.send(messages: coordinator.triggerConnectionEstablishedSync(deviceID: peerID), to: peerID)
            }
            pairingRuntime.remove(id: id)
            refreshPairingFlowPresentations()
            refreshDeviceRows()
            snapshot.actionMessage = "Paired \(flow.session.transcript.remote.displayName)."
            return .started(snapshot.actionMessage ?? "Pairing committed.")
        } catch {
            if let persistenceError = error as? TBPairingCommitPersistenceError, persistenceError.requiresReset {
                snapshot.storageHealthStatus = .lanSyncDisabledRequiresReset(persistenceError.resetReason)
            }
            let message = "Pairing commit failed: \(error)"
            snapshot.actionMessage = message
            return .blocked(message)
        }
    }

    @discardableResult
    func confirmPairingRuntimeFlow(id: TBPairingRuntimeFlowID, code: String, now: Date = Date()) -> TBSyncServiceActionResult {
        guard let flow = pairingRuntime.flow(id: id) else {
            let message = "Pairing flow is no longer available."
            snapshot.actionMessage = message
            return .blocked(message)
        }
        do {
            try flow.session.confirmCode(code, now: now)
            refreshPairingFlowPresentations()
            snapshot.actionMessage = "Pairing verification code confirmed for \(flow.session.transcript.remote.displayName)."
            return .started(snapshot.actionMessage ?? "Pairing code confirmed.")
        } catch {
            let message = "Pairing verification failed: \(error)"
            snapshot.actionMessage = message
            return .blocked(message)
        }
    }

    @discardableResult
    func confirmVerificationCode(flowID: TBPairingRuntimeFlowID) -> TBSyncServiceActionResult {
        guard let flow = pairingRuntime.flow(id: flowID), case .awaitingCodeConfirmation(let code) = flow.session.state else {
            let message = "Pairing flow is not waiting for verification confirmation."
            snapshot.actionMessage = message
            return .blocked(message)
        }
        return confirmPairingRuntimeFlow(id: flowID, code: code)
    }

    @discardableResult
    func approvePairingRuntimeFlow(id: TBPairingRuntimeFlowID,
                                   settingsSource: TBPairingSettingsSourceChoice = .keepLocal,
                                   now: Date = Date()) -> TBSyncServiceActionResult {
        guard let flow = pairingRuntime.flow(id: id) else {
            let message = "Pairing flow is no longer available."
            snapshot.actionMessage = message
            return .blocked(message)
        }
        do {
            var preview = Self.preview(for: flow.session.transcript)
            preview.settingsSourceChoice = settingsSource
            try flow.session.approvePreview(preview, now: now)
            refreshPairingFlowPresentations()
            return commitPairingRuntimeFlow(id: id, now: now)
        } catch {
            let message = "Pairing preview approval failed: \(error)"
            snapshot.actionMessage = message
            return .blocked(message)
        }
    }

    @discardableResult
    func approvePreview(flowID: TBPairingRuntimeFlowID, settingsSource: TBPairingSettingsSourceChoice) -> TBSyncServiceActionResult {
        approvePairingRuntimeFlow(id: flowID, settingsSource: settingsSource)
    }

    @discardableResult
    func resetSync() -> TBSyncServiceActionResult {
        guard let resetService else {
            let message = "Reset Sync is unavailable because reset storage wiring is not available."
            snapshot.actionMessage = message
            return .blocked(message)
        }

        do {
            stopLAN(message: "Sync reset in progress.")
            try resetService.resetSync(preservingRawEventsAt: nil)
            pairingRuntime.reset()
            refreshPairingFlowPresentations()
            router?.resetRuntimeState()
            coordinator.resetRuntimeState()
            coordinator.remoteImportHandler = { [weak self] _, displayName in
                Task { @MainActor in self?.handleRemoteImport(from: displayName) }
            }
            snapshot.storageHealthStatus = healthChecker.lanSyncHealth().status
            snapshot.actionMessage = "Sync identity, trusted peers, and sync metadata were reset."
            snapshot.pairedDevices = []
            return .reset(snapshot.actionMessage ?? "Sync reset complete.")
        } catch {
            let message = "Reset Sync failed: \(error.localizedDescription)"
            snapshot.actionMessage = message
            return .blocked(message)
        }
    }

    @discardableResult
    func removeDevice(id: UUID) -> TBSyncServiceActionResult {
        guard let device = snapshot.pairedDevices.first(where: { $0.id == id }) else {
            let message = "Device is no longer paired."
            snapshot.actionMessage = message
            return .blocked(message)
        }
        let deviceID = id.uuidString.lowercased()
        if let peerStore = pairingCommitPersister?.peerStoreForContext {
            do {
                if var peer = try peerStore.trustedPeer(deviceID: deviceID) {
                    peer.isRemoved = true
                    try peerStore.saveTrustedPeer(peer)
                }
            } catch {
                let message = "Remove Device failed: \(error)"
                snapshot.actionMessage = message
                return .blocked(message)
            }
        }
        coordinator.markRemoved(deviceID: deviceID, displayName: device.name)
        snapshot.pairedDevices.removeAll { $0.id == id }
        snapshot.actionMessage = "Removed \(device.name) from future sync attempts."
        return .started(snapshot.actionMessage ?? "Device removed.")
    }

    private func startPairingSetup(message: String) -> TBSyncServiceActionResult {
        guard snapshot.capabilityGates.userFacingLANSyncAvailable else {
            let message = "Pairing setup is unavailable because LAN runtime infrastructure is not available."
            snapshot.actionMessage = message
            return .blocked(message)
        }

        let health = healthChecker.pairingSetupHealth()
        snapshot.storageHealthStatus = health.status
        guard health.isPairingSetupEligible else {
            let blocked = "Pairing setup is blocked: \(storageHealthSummary(health.status))."
            snapshot.actionMessage = blocked
            return .blocked(blocked)
        }

        lanRuntime.start(discoveryID: .ephemeral())
        guard case .active = lanRuntime.status else {
            let blocked = "Pairing setup could not start LAN runtime."
            snapshot.actionMessage = blocked
            return .blocked(blocked)
        }

        snapshot.runtimeMode = .pairingSetup
        snapshot.selectedMode = .off
        snapshot.statusMessage = message
        snapshot.actionMessage = message
        return .started(message)
    }

    private func startLanSync() -> TBSyncServiceActionResult {
        guard snapshot.capabilityGates.userFacingLANSyncAvailable else {
            let message = "LAN sync is unavailable because LAN runtime infrastructure is not available."
            snapshot.actionMessage = message
            return .blocked(message)
        }

        let health = healthChecker.lanSyncHealth()
        snapshot.storageHealthStatus = health.status
        guard health.isLANSyncEnabled else {
            stopLAN(message: "LAN sync is blocked: \(storageHealthSummary(health.status)).")
            return .blocked(snapshot.actionMessage ?? "LAN sync is blocked.")
        }

        guard coordinator.setMode(.lanOnly, discoveryID: .ephemeral()) else {
            snapshot.actionMessage = "LAN sync could not start."
            return .blocked(snapshot.actionMessage ?? "LAN sync could not start.")
        }

        snapshot.selectedMode = .lanOnly
        snapshot.runtimeMode = .lanSync
        snapshot.statusMessage = "LAN sync is active on this local network."
        snapshot.actionMessage = "LAN sync started."
        refreshDeviceRows()
        return .started("LAN sync started.")
    }

    private func handleDiscoveredPeer(_ peer: LANDiscoveredPeer) {
        guard snapshot.runtimeMode == .lanSync else { return }
        guard let manualConnector else { return }
        do {
            let endpoint = try LANManualEndpoint(host: peer.host, port: peer.port)
            manualConnector.connect(to: endpoint) { [weak self] result in
                TBSyncService.performOnMainActor {
                    guard let self else { return }
                    switch result {
                    case .success(let session):
                        self.retainedManualPairingSessions.append(session)
                        _ = self.initiateOutboundResume(session: session)
                    case .failure(let error):
                        self.snapshot.actionMessage = "LAN resume connection failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            snapshot.actionMessage = "Discovered LAN peer endpoint is invalid."
        }
    }

    private func peerIDForManualEndpoint(_ endpoint: LANManualEndpoint) -> String? {
        if TomattSyncProtocolV1.isCanonicalLowercaseUUIDString(endpoint.host) { return endpoint.host }
        let paired = snapshot.pairedDevices.map { $0.id.uuidString.lowercased() }
        return paired.count == 1 ? paired[0] : nil
    }

    private func initiateOutboundResume(session: LANWebSocketSession, peerID: String) -> Bool {
        guard let router else { return false }
        let started = router.initiateOutboundResume(session: session, peerID: peerID)
        if started {
            snapshot.runtimeMode = .lanSync
            snapshot.selectedMode = .lanOnly
            snapshot.statusMessage = "Resume handshake started with paired peer."
        }
        return started
    }

    private func initiateOutboundResume(session: LANWebSocketSession) -> Bool {
        guard let router else { return false }
        let started = router.initiateOutboundResume(session: session)
        if started {
            snapshot.runtimeMode = .lanSync
            snapshot.selectedMode = .lanOnly
            snapshot.statusMessage = "Resume handshake started with discovered peer."
        }
        return started
    }

    private func startPairingWireFlow(session: LANWebSocketSession, endpoint: LANManualEndpoint) {
        pairingRuntime.markPairingSessionActive(session)
        router?.admit(session: session)
        guard let artifacts = makeLocalPairingArtifacts(session: session,
                                                        endpoint: endpoint,
                                                        role: .addDevice,
                                                        sessionNonce: Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })) else {
            snapshot.actionMessage = "Pairing cannot start because local sync identity is unavailable."
            return
        }
        pairingArtifacts[ObjectIdentifier(session)] = artifacts
        session.send(artifacts.startEnvelope) { _ in }
        coordinator.beginPairing(deviceID: endpoint.host)
    }

    private func handlePairingEnvelope(_ envelope: Tomatt_Sync_V1_Envelope, from session: LANWebSocketSession) -> Bool {
        guard snapshot.runtimeMode == .pairingSetup || pairingRuntime.hasActivePairingSession(session) else { return false }
        switch envelope.payload {
        case .pairingStart(let start):
            pairingRuntime.markPairingSessionActive(session)
            coordinator.beginPairing(deviceID: start.deviceID.isEmpty ? session.endpointDescription : start.deviceID)
            guard start.hasParticipant,
                  let remoteParticipant = try? Self.participant(from: start.participant) else {
                snapshot.actionMessage = "Pairing start was missing transcript data."
                return true
            }
            let endpoint = (try? LANManualEndpoint(host: session.endpointDescription, port: snapshot.listenerPort))
                ?? (try! LANManualEndpoint(host: "127.0.0.1", port: snapshot.listenerPort))
            guard let artifacts = makeLocalPairingArtifacts(session: session,
                                                            endpoint: endpoint,
                                                            role: .joinSyncGroup,
                                                            sessionNonce: start.participant.sessionNonce) else {
                snapshot.actionMessage = "Pairing cannot continue because local sync identity is unavailable."
                return true
            }
            pairingArtifacts[ObjectIdentifier(session)] = artifacts
            session.send(artifacts.challengeEnvelope) { _ in }
            retainFlowIfPossible(localArtifacts: artifacts, remoteParticipant: remoteParticipant, lanSession: session)
            return true
        case .pairingChallenge(let challenge):
            pairingRuntime.markPairingSessionActive(session)
            guard challenge.hasParticipant,
                  let artifacts = pairingArtifacts[ObjectIdentifier(session)],
                  let remoteParticipant = try? Self.participant(from: challenge.participant) else {
                snapshot.actionMessage = "Pairing challenge was missing transcript data."
                return true
            }
            retainFlowIfPossible(localArtifacts: artifacts, remoteParticipant: remoteParticipant, lanSession: session)
            snapshot.actionMessage = "Pairing verification data received. Confirm the verification code to finish pairing."
            return true
        case .pairingResponse, .pairingComplete:
            pairingRuntime.markPairingSessionActive(session)
            return true
        default:
            return false
        }
    }

    private func makeLocalPairingArtifacts(session: LANWebSocketSession,
                                           endpoint: LANManualEndpoint,
                                           role: TBPairingRole,
                                           sessionNonce: Data) -> TBLocalPairingWireArtifacts? {
        guard let localIdentity else { return nil }
        let keyPair = TBPairingEphemeralKeyPair()
        let groupState: TBPairingGroupState
        do {
            groupState = try pairingCommitPersister?.activePairingGroupState() ?? .standalone
        } catch {
            snapshot.actionMessage = "Pairing cannot start because local sync group state is unavailable: \(error)"
            return nil
        }
        let participant = TBPairingTranscriptParticipant(deviceID: localIdentity.deviceID,
                                                          displayName: localIdentity.displayName,
                                                         platform: localIdentity.platform ?? "macOS",
                                                         ephemeralPairingPublicKey: keyPair.publicKey,
                                                         signingPublicKey: localIdentity.signingPublicKey,
                                                         ephemeralDiscoveryID: session.endpointDescription,
                                                         endpoint: TBPairingEndpointMetadata(host: endpoint.host,
                                                                                             port: endpoint.port,
                                                                                             transport: "websocket",
                                                                                             path: endpoint.path,
                                                                                             metadata: ["subprotocol": endpoint.websocketSubprotocol]),
                                                          idle: .idle(at: Date()),
                                                          capabilities: ["pairing-v1", "encrypted-lan-v1"],
                                                          groupState: groupState)
        let proto = Self.protoParticipant(from: participant, sessionNonce: sessionNonce)
        var start = Tomatt_Sync_V1_Envelope()
        start.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        start.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
        start.pairingStart = Tomatt_Sync_V1_PairingStart.with {
            $0.deviceID = localIdentity.deviceID
            $0.displayName = localIdentity.displayName
            $0.participant = proto
        }
        var challenge = Tomatt_Sync_V1_Envelope()
        challenge.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        challenge.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
        challenge.pairingChallenge = Tomatt_Sync_V1_PairingChallenge.with {
            $0.challengeID = UUID().uuidString.lowercased()
            $0.challenge = Data(SHA256.hash(data: sessionNonce + keyPair.publicKey))
            $0.participant = proto
        }
        return TBLocalPairingWireArtifacts(role: role,
                                           keyPair: keyPair,
                                           participant: participant,
                                           sessionNonce: sessionNonce,
                                           startEnvelope: start,
                                           challengeEnvelope: challenge)
    }

    private func retainFlowIfPossible(localArtifacts: TBLocalPairingWireArtifacts,
                                      remoteParticipant: TBPairingTranscriptParticipant,
                                      lanSession: LANWebSocketSession) {
        do {
            let transcript = TBPairingTranscript(protocolVersion: TBPairingTranscript.canonicalVersion,
                                                 role: localArtifacts.role,
                                                 local: localArtifacts.participant,
                                                 remote: remoteParticipant,
                                                 timestamp: Date(timeIntervalSince1970: 0),
                                                 sessionNonce: localArtifacts.sessionNonce,
                                                 capabilities: Array(Set(localArtifacts.participant.capabilities + remoteParticipant.capabilities)).sorted())
            let establishment = try localArtifacts.keyPair.deriveSessionEstablishment(localTranscript: transcript)
            let commit = try Self.stagedCommit(from: transcript, establishment: establishment, now: Date())
            let pairingSession = TBPairingSession(transcript: transcript,
                                                  stagedCommit: commit,
                                                  expiresAt: Date().addingTimeInterval(10 * 60))
            let code = try pairingSession.start(now: Date())
            let flow = TBPairingRuntimeFlow(id: .random(),
                                            session: pairingSession,
                                            establishment: establishment,
                                            lanSession: lanSession)
            pairingRuntime.retain(flow)
            refreshPairingFlowPresentations()
            snapshot.actionMessage = "Pairing verification code \(code) is ready for \(remoteParticipant.displayName). Review the preview before approving."
        } catch {
            snapshot.actionMessage = "Pairing transcript could not be established: \(error)"
        }
    }

    private static func stagedCommit(from transcript: TBPairingTranscript,
                                     establishment: TBPairingSessionEstablishment,
                                     now: Date) throws -> TBPairingStagedCommit {
        let compatibility = try TBPairingGroupCompatibilityRules.evaluate(local: transcript.local.groupState,
                                                                          remote: transcript.remote.groupState)
        let groupID: String
        switch compatibility {
        case .createNewSyncGroup:
            groupID = deterministicUUIDHex(from: try transcript.canonicalBytes() + Data("group".utf8))
        case .joinExistingGroup(let existing), .sameGroup(let existing):
            groupID = existing
        }
        let key = try TBSyncGroupKeyRecord.importExisting(groupID: groupID,
                                                          keyID: establishment.keyMaterial.keyID,
                                                          secret: establishment.keyMaterial.rawKeyData,
                                                          createdAt: now)
        return TBPairingStagedCommit(trustedPeer: TBTrustedPeerRecord(deviceID: transcript.remote.deviceID,
                                                                      displayName: transcript.remote.displayName,
                                                                      platform: transcript.remote.platform,
                                                                      signingPublicKey: transcript.remote.signingPublicKey),
                                     syncGroupKey: key,
                                     membershipActions: [],
                                     importedEvents: [],
                                     settingsSourceChoice: .keepLocal)
    }

    private static func preview(for transcript: TBPairingTranscript) -> TBPairingPreMergePreview {
        TBPairingPreMergePreview(localDevice: TBDeviceIdentity(deviceID: transcript.local.deviceID,
                                                               displayName: transcript.local.displayName,
                                                               platform: transcript.local.platform),
                                 remoteDevice: TBDeviceIdentity(deviceID: transcript.remote.deviceID,
                                                                displayName: transcript.remote.displayName,
                                                                platform: transcript.remote.platform),
                                 bothIdle: transcript.local.idle.isIdle && transcript.remote.idle.isIdle,
                                 settingsDiffer: false,
                                 localPresetCount: 0,
                                 remotePresetCount: 0,
                                 localHistory: TBPairingHistorySummary(eventCount: 0, dateRangeStart: nil, dateRangeEnd: nil),
                                 remoteHistory: TBPairingHistorySummary(eventCount: 0, dateRangeStart: nil, dateRangeEnd: nil),
                                 settingsSourceChoice: .keepLocal)
    }

    private static func protoParticipant(from participant: TBPairingTranscriptParticipant,
                                         sessionNonce: Data) -> Tomatt_Sync_V1_PairingTranscriptParticipant {
        Tomatt_Sync_V1_PairingTranscriptParticipant.with {
            $0.deviceID = participant.deviceID
            $0.displayName = participant.displayName
            $0.platform = participant.platform
            $0.syncSigningPublicKey = participant.signingPublicKey
            $0.syncSigningKeyFingerprint = TBSyncKeyFingerprint.fingerprint(participant.signingPublicKey)
            $0.ephemeralPairingPublicKey = participant.ephemeralPairingPublicKey
            $0.ephemeralDiscoveryID = participant.ephemeralDiscoveryID
            $0.endpoint = Tomatt_Sync_V1_PairingEndpointMetadata.with {
                $0.host = participant.endpoint.host
                $0.port = UInt32(max(0, participant.endpoint.port))
                $0.transport = participant.endpoint.transport
                $0.path = participant.endpoint.path
                $0.metadata = participant.endpoint.metadata
            }
            $0.idle = Tomatt_Sync_V1_PairingIdleDeclaration.with {
                $0.isIdle = participant.idle.isIdle
                $0.declaredAt = timestamp(from: participant.idle.declaredAt)
                $0.reason = participant.idle.reason ?? ""
            }
            $0.capabilities = participant.capabilities.sorted()
            $0.groupState = Tomatt_Sync_V1_PairingGroupState.with {
                switch participant.groupState {
                case .standalone:
                    $0.kind = .standalone
                case .grouped(let groupID):
                    $0.kind = .grouped
                    $0.groupID = groupID
                }
            }
            $0.sessionNonce = sessionNonce
            $0.transcriptProtocolVersion = UInt32(TBPairingTranscript.canonicalVersion)
        }
    }

    private static func participant(from proto: Tomatt_Sync_V1_PairingTranscriptParticipant) throws -> TBPairingTranscriptParticipant {
        guard proto.transcriptProtocolVersion == UInt32(TBPairingTranscript.canonicalVersion) else {
            throw TBPairingWireTranscriptError.invalidParticipant("transcript_protocol_version")
        }
        guard TomattSyncProtocolV1.isCanonicalLowercaseUUIDString(proto.deviceID) else {
            throw TBPairingWireTranscriptError.invalidParticipant("device_id")
        }
        guard TBSyncKeyFingerprint.fingerprint(proto.syncSigningPublicKey) == proto.syncSigningKeyFingerprint else {
            throw TBPairingWireTranscriptError.invalidParticipant("sync_signing_key_fingerprint")
        }
        guard !proto.ephemeralPairingPublicKey.isEmpty else {
            throw TBPairingWireTranscriptError.invalidParticipant("ephemeral_pairing_public_key")
        }
        guard proto.sessionNonce.count == 32 else {
            throw TBPairingWireTranscriptError.invalidParticipant("session_nonce")
        }
        let groupState: TBPairingGroupState
        switch proto.groupState.kind {
        case .standalone:
            groupState = .standalone
        case .grouped:
            guard !proto.groupState.groupID.isEmpty else { throw TBPairingWireTranscriptError.invalidParticipant("group_id") }
            groupState = .grouped(groupID: proto.groupState.groupID)
        case .unspecified, .UNRECOGNIZED:
            throw TBPairingWireTranscriptError.invalidParticipant("group_state")
        }
        return TBPairingTranscriptParticipant(deviceID: proto.deviceID,
                                             displayName: proto.displayName,
                                             platform: proto.platform.isEmpty ? "macOS" : proto.platform,
                                             ephemeralPairingPublicKey: proto.ephemeralPairingPublicKey,
                                             signingPublicKey: proto.syncSigningPublicKey,
                                             ephemeralDiscoveryID: proto.ephemeralDiscoveryID,
                                             endpoint: TBPairingEndpointMetadata(host: proto.endpoint.host,
                                                                                 port: Int(proto.endpoint.port),
                                                                                 transport: proto.endpoint.transport,
                                                                                 path: proto.endpoint.path,
                                                                                 metadata: proto.endpoint.metadata),
                                             idle: TBPairingIdleDeclaration(isIdle: proto.idle.isIdle,
                                                                            declaredAt: date(from: proto.idle.declaredAt),
                                                                            reason: proto.idle.reason.isEmpty ? nil : proto.idle.reason),
                                             capabilities: proto.capabilities.sorted(),
                                             groupState: groupState)
    }

    private static func timestamp(from date: Date) -> Google_Protobuf_Timestamp {
        let interval = date.timeIntervalSince1970
        var timestamp = Google_Protobuf_Timestamp()
        timestamp.seconds = Int64(interval)
        timestamp.nanos = Int32((interval - Double(timestamp.seconds)) * 1_000_000_000)
        return timestamp
    }

    private static func date(from timestamp: Google_Protobuf_Timestamp) -> Date {
        Date(timeIntervalSince1970: Double(timestamp.seconds) + Double(timestamp.nanos) / 1_000_000_000)
    }

    private static func deterministicUUIDHex(from data: Data) -> String {
        let hex = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }

    private func stopLAN(message: String) {
        retainedManualPairingSessions.forEach { $0.close() }
        retainedManualPairingSessions.removeAll()
        coordinator.setMode(.off, discoveryID: .ephemeral())
        lanRuntime.stop()
        snapshot.selectedMode = .off
        snapshot.runtimeMode = .syncOff
        snapshot.storageHealthStatus = healthChecker.lanSyncHealth().status
        snapshot.statusMessage = message
        snapshot.actionMessage = message
    }

    private func refreshDeviceRows() {
        snapshot.pairedDevices = coordinator.peers.values.sorted { $0.deviceID < $1.deviceID }.map { peer in
            TBPairedSyncDevice(id: UUID(uuidString: peer.deviceID) ?? UUID(),
                               name: peer.displayName,
                               platform: "Paired device",
                               lastSeen: peer.lastSeenAt,
                               status: TBSyncDeviceConnectionStatus(peerState: peer.state))
        }
    }

    private func refreshPairingFlowPresentations() {
        snapshot.activePairingFlows = pairingRuntime.retainedFlows.map { flow in
            let code: String?
            let preview: TBPairingPreMergePreview?
            switch flow.session.state {
            case .awaitingCodeConfirmation(let value):
                code = value
                preview = nil
            case .codeConfirmed:
                code = nil
                preview = Self.preview(for: flow.session.transcript)
            default:
                code = nil
                preview = nil
            }
            return TBPairingFlowPresentation(id: flow.id,
                                             remoteDisplayName: flow.session.transcript.remote.displayName,
                                             verificationCode: code,
                                             preview: preview)
        }.filter { $0.isAwaitingVerificationConfirmation || $0.isAwaitingPreviewApproval }
    }

    private func storageHealthSummary(_ status: TBSyncStorageHealthStatus) -> String {
        switch status {
        case .ready:
            return "Ready"
        case .lanSyncDisabledRequiresPairing(let reason):
            return "Pairing required (\(reason))"
        case .lanSyncDisabledRequiresReset(let reason):
            return "Reset required (\(reason))"
        }
    }

    private static func performOnMainActor(_ operation: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { operation() }
        } else {
            Task { @MainActor in operation() }
        }
    }

    static func defaultDependencies(eventLog sharedEventLog: TBLocalEventLog = TBLocalEventLog(),
                                    timerSyncRefresher: TBTimerSyncRefreshing? = nil) -> Dependencies {
        let config = (try? LANTransportConfig()) ?? (try! LANTransportConfig(port: LANTransportInternalPlaintext.defaultPort))
        let advertiser = NetServiceLANBonjourAdvertiser()
        let browser = NetServiceLANBonjourBrowser()
        let server = LANWebSocketServerBoundary()
        let lanRuntime = LANTransportRuntimeModel(config: config,
                                                  advertiser: advertiser,
                                                  browser: browser,
                                                  server: server)

        let deviceAccount = ProcessInfo.processInfo.hostName
        let signingStore = TBAppleKeychainDeviceSigningKeyStore(account: deviceAccount)
        let groupKeyStore = TBAppleKeychainSyncGroupKeyStore()
        let metadataStore = TBFileSyncGroupMetadataStore()
        let trustedPeerStore = TBFileTrustedPeerStore()
        let identityStore = TBFileDeviceIdentityStore()
        let deviceIdentity = (try? TBDeviceIdentityProvider.loadOrCreate(store: identityStore))
            ?? TBDeviceIdentity(deviceID: deviceAccount, displayName: Host.current().localizedName ?? deviceAccount, platform: "macOS")
        let signer = (try? TBEd25519DeviceSigner(store: signingStore))
        let publicIdentity = signer.map { TBSyncDevicePublicIdentity(deviceID: deviceIdentity.deviceID,
                                                                     displayName: deviceIdentity.displayName,
                                                                     platform: deviceIdentity.platform,
                                                                     signingPublicKey: $0.publicKey) }
        let signedEventStore = TBJSONLSignedSyncEventStore()
        let eventLogFacade = TBSyncEventLogFacade(eventLog: sharedEventLog)
        let healthChecker = TBSyncStorageHealthService(signingKeyStore: signingStore,
                                                       groupKeyStore: groupKeyStore,
                                                       metadataStore: metadataStore)
        let coordinator = TBSyncRuntimeCoordinator(healthChecker: healthChecker, lanRuntime: lanRuntime)
        let resetService = TBSyncStorageResetService(stores: [TBFreshDeviceSigningKeyResetStore(resettableStore: signingStore,
                                                                                               signingStore: signingStore),
                                                              TBMetadataBackedSyncGroupKeyResetStore(keyStore: groupKeyStore,
                                                                                                      metadataStore: metadataStore),
                                                              metadataStore,
                                                              trustedPeerStore,
                                                              signedEventStore])
        let engineMaker: TBSyncPeerEngineMaking? = signer.map { signer in
            TBDefaultSyncPeerEngineMaker(eventLog: eventLogFacade,
                                         signerDeviceID: deviceIdentity.deviceID,
                                         signer: signer,
                                         peerStore: trustedPeerStore,
                                         verifier: TBEd25519SignatureVerifier(),
                                         signedEventStore: signedEventStore)
        }
        let admission = TBLANReconnectSessionAdmission(localIdentity: publicIdentity,
                                                       peerStore: trustedPeerStore,
                                                       metadataStore: metadataStore,
                                                       groupKeyStore: groupKeyStore,
                                                       coordinator: coordinator,
                                                       engineMaker: engineMaker)
        let router = TBLANEncryptedSessionRouter(admission: admission,
                                                  coordinator: coordinator)
        server.onSessionAccepted = { [weak router] session in
            Task { @MainActor in router?.admit(session: session) }
        }

        return Dependencies(lanRuntime: lanRuntime,
                            coordinator: coordinator,
                            router: router,
                             healthChecker: healthChecker,
                             resetService: resetService,
                             manualConnector: URLSessionLANWebSocketClient(),
                             pairingRuntime: TBPairingRuntimeCoordinator(),
                             pairingCommitPersister: TBDefaultPairingCommitPersister(peerStore: trustedPeerStore,
                                                                                     metadataStore: metadataStore,
                                                                                      groupKeyStore: groupKeyStore),
                             localIdentity: publicIdentity,
                              engineMaker: engineMaker,
                              eventLog: sharedEventLog,
                              timerSyncRefresher: timerSyncRefresher,
                              capabilityGates: .currentProductizedSurface,
                            deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                            deviceIdentity: deviceAccount,
                            listenerPort: config.port)
    }
}

private struct TBPairingCommitPersisterAdapter: TBPairingCommitApplying {
    let persister: TBPairingCommitPersisting

    func applyPairingCommit(_ commit: TBPairingStagedCommit) throws {
        try persister.persistPairingCommit(commit)
    }
}

final class TBDefaultPairingCommitPersister: TBPairingCommitPersisting {
    let peerStoreForContext: TBTrustedPeerStoring
    private let metadataStore: TBSyncGroupMetadataStoring
    private let groupKeyStore: TBSyncGroupKeyStoring

    init(peerStore: TBTrustedPeerStoring,
         metadataStore: TBSyncGroupMetadataStoring,
          groupKeyStore: TBSyncGroupKeyStoring) {
        peerStoreForContext = peerStore
        self.metadataStore = metadataStore
        self.groupKeyStore = groupKeyStore
    }

    func persistPairingCommit(_ commit: TBPairingStagedCommit) throws {
        guard commit.membershipActions.isEmpty else { throw TBPairingCommitPersistenceError.unsupportedMembershipActions }
        guard commit.settingsSourceChoice == .keepLocal else { throw TBPairingCommitPersistenceError.unsupportedSettingsSource(commit.settingsSourceChoice) }
        guard commit.importedEvents.isEmpty else { throw TBPairingCommitPersistenceError.unsupportedImportedEvents }

        let existingKey = try groupKeyStore.loadSyncGroupKey(groupID: commit.syncGroupKey.groupID)
        let existingMetadata = try metadataStore.loadSyncGroupMetadata(groupID: commit.syncGroupKey.groupID)
        let existingPeer = try peerStoreForContext.trustedPeer(deviceID: commit.trustedPeer.deviceID)
        do {
            try groupKeyStore.saveSyncGroupKey(commit.syncGroupKey)
            try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: commit.syncGroupKey.groupID,
                                                                              keyID: commit.syncGroupKey.keyID,
                                                                              createdAt: commit.syncGroupKey.createdAt,
                                                                              state: .active))
            try peerStoreForContext.saveTrustedPeer(commit.trustedPeer)
        } catch {
            let writeErrorDescription = String(describing: error)
            do {
                try rollback(commit: commit,
                             existingKey: existingKey,
                             existingMetadata: existingMetadata,
                             existingPeer: existingPeer)
            } catch let rollbackError as TBPairingCommitPersistenceError {
                throw TBPairingCommitPersistenceError.rollbackFailed(writeError: writeErrorDescription,
                                                                     rollbackErrors: rollbackError.rollbackErrors)
            } catch {
                throw TBPairingCommitPersistenceError.rollbackFailed(writeError: writeErrorDescription,
                                                                     rollbackErrors: [String(describing: error)])
            }
            throw TBPairingCommitPersistenceError.writeFailed(writeErrorDescription)
        }
    }

    private func rollback(commit: TBPairingStagedCommit,
                          existingKey: TBSyncGroupKeyRecord?,
                           existingMetadata: TBSyncGroupMetadataRecord?,
                           existingPeer: TBTrustedPeerRecord?) throws {
        var rollbackErrors: [String] = []
        if let existingPeer {
            do { try peerStoreForContext.saveTrustedPeer(existingPeer) } catch { rollbackErrors.append("restore peer: \(error)") }
        } else {
            do { try peerStoreForContext.deleteTrustedPeer(deviceID: commit.trustedPeer.deviceID) } catch { rollbackErrors.append("delete peer: \(error)") }
        }
        if let existingMetadata {
            do { try metadataStore.saveSyncGroupMetadata(existingMetadata) } catch { rollbackErrors.append("restore metadata: \(error)") }
        } else {
            do { try metadataStore.deleteSyncGroupMetadata(groupID: commit.syncGroupKey.groupID) } catch { rollbackErrors.append("delete metadata: \(error)") }
        }
        if let existingKey {
            do { try groupKeyStore.saveSyncGroupKey(existingKey) } catch { rollbackErrors.append("restore key: \(error)") }
        } else {
            do { try groupKeyStore.deleteSyncGroupKey(groupID: commit.syncGroupKey.groupID) } catch { rollbackErrors.append("delete key: \(error)") }
        }
        if !rollbackErrors.isEmpty {
            throw TBPairingCommitPersistenceError.rollbackFailed(writeError: "rollback", rollbackErrors: rollbackErrors)
        }
    }

    func activePairingGroupState() throws -> TBPairingGroupState {
        let activeMetadata = try metadataStore.loadActiveSyncGroupMetadata()
        guard let metadata = activeMetadata.first else { return .standalone }
        guard activeMetadata.count == 1 else { throw TBPairingCommitPersistenceError.invalidActiveGroupState("multiple active sync groups") }
        guard let key = try groupKeyStore.loadSyncGroupKey(groupID: metadata.groupID),
              key.keyID == metadata.keyID,
              key.isUsableForLANSync else {
            throw TBPairingCommitPersistenceError.invalidActiveGroupState("missing usable sync group key")
        }
        return .grouped(groupID: metadata.groupID)
    }
}

enum TBPairingCommitPersistenceError: Error, Equatable {
    case unsupportedMembershipActions
    case unsupportedSettingsSource(TBPairingSettingsSourceChoice)
    case unsupportedImportedEvents
    case writeFailed(String)
    case rollbackFailed(writeError: String, rollbackErrors: [String])
    case invalidActiveGroupState(String)

    var requiresReset: Bool {
        if case .rollbackFailed = self { return true }
        return false
    }

    var resetReason: String {
        switch self {
        case .rollbackFailed:
            return "pairing commit rollback failed"
        default:
            return "pairing commit failed"
        }
    }

    var rollbackErrors: [String] {
        if case .rollbackFailed(_, let errors) = self { return errors }
        return [String(describing: self)]
    }
}

final class TBDefaultSyncPeerEngineMaker: TBSyncPeerEngineMaking {
    private let eventLog: TBSyncEventLogExporting & TBSignedSyncEventImportSink
    private let signerDeviceID: String
    private let signer: TBSyncEventSigning
    private let peerStore: TBTrustedPeerStoring
    private let verifier: TBSyncEventSignatureVerifying
    private let signedEventStore: TBSignedSyncEventStoring

    init(eventLog: TBSyncEventLogExporting & TBSignedSyncEventImportSink,
         signerDeviceID: String,
         signer: TBSyncEventSigning,
         peerStore: TBTrustedPeerStoring,
         verifier: TBSyncEventSignatureVerifying,
         signedEventStore: TBSignedSyncEventStoring) {
        self.eventLog = eventLog
        self.signerDeviceID = signerDeviceID
        self.signer = signer
        self.peerStore = peerStore
        self.verifier = verifier
        self.signedEventStore = signedEventStore
    }

    func makeEngine(session: TBSyncSessionCryptoBox) throws -> TBSyncPeerEngine {
        let importer = TBSignedSyncEventTrustedImporter(peerStore: peerStore,
                                                        verifier: verifier,
                                                        sink: eventLog,
                                                        signedEventStore: signedEventStore)
        return TBAntiEntropySyncEngine(session: session,
                                       eventLog: eventLog,
                                       signerDeviceID: signerDeviceID,
                                       signer: signer,
                                       trustedImporter: importer,
                                       signedEventStore: signedEventStore)
    }
}

final class TBLANReconnectSessionAdmission: TBLANEncryptedSessionAdmitting {
    private let localIdentity: TBSyncDevicePublicIdentity?
    private let peerStore: TBTrustedPeerStoring
    private let metadataStore: TBSyncGroupMetadataStoring
    private let groupKeyStore: TBSyncGroupKeyStoring
    private let coordinator: TBSyncRuntimeCoordinating
    private let engineMaker: TBSyncPeerEngineMaking?
    private var contexts: [String: TBLANEncryptedSessionContext] = [:]
    private var localHellos: [String: Tomatt_Sync_V1_Hello] = [:]

    init(localIdentity: TBSyncDevicePublicIdentity?,
         peerStore: TBTrustedPeerStoring,
         metadataStore: TBSyncGroupMetadataStoring,
         groupKeyStore: TBSyncGroupKeyStoring,
         coordinator: TBSyncRuntimeCoordinating,
         engineMaker: TBSyncPeerEngineMaking?) {
        self.localIdentity = localIdentity
        self.peerStore = peerStore
        self.metadataStore = metadataStore
        self.groupKeyStore = groupKeyStore
        self.coordinator = coordinator
        self.engineMaker = engineMaker
    }

    func admitResume(hello: Tomatt_Sync_V1_Hello) -> Result<TBLANEncryptedSessionContext, TBLANEncryptedSessionAdmissionFailure> {
        guard let localIdentity, let engineMaker else { return .failure(.notReady("Encrypted session runtime is not ready")) }
        let localHello: Tomatt_Sync_V1_Hello
        if let prepared = localHellos[hello.deviceID] {
            localHello = prepared
        } else {
            localHello = Self.makeResumeHello(localIdentity: localIdentity,
                                              sessionKeyID: hello.sessionKeyID,
                                              sessionRole: hello.sessionRole == .initiator ? .responder : .initiator,
                                              syncGroupID: hello.syncGroupID)
        }
        do {
            let hydrated = try TBReconnectSessionHydrator.hydrate(localIdentity: localIdentity,
                                                                  localHello: localHello,
                                                                  peerHello: hello,
                                                                  peerStore: peerStore,
                                                                  metadataStore: metadataStore,
                                                                  groupKeyStore: groupKeyStore)
            let engine = try engineMaker.makeEngine(session: hydrated.makeCryptoBox())
            coordinator.registerEngine(engine, for: hydrated.context.peerDeviceID, displayName: hello.displayName)
            let context = TBLANEncryptedSessionContext(peerID: hydrated.context.peerDeviceID,
                                                       displayName: hello.displayName,
                                                       sessionKeyID: hello.sessionKeyID,
                                                       sessionNonceSeed: hello.sessionNonceSeed,
                                                       peerRole: hydrated.localRole == .initiator ? .responder : .initiator,
                                                       syncGroupID: hello.syncGroupID)
            contexts[context.peerID] = context
            localHellos[context.peerID] = localHello
            return .success(context)
        } catch let error as TBReconnectSessionHydrationError {
            return .failure(Self.failure(from: error))
        } catch {
            return .failure(.notReady(String(describing: error)))
        }
    }

    func sessionContext(for peerID: String) -> TBLANEncryptedSessionContext? { contexts[peerID] }

    func localResumeHello(for peerID: String) -> Tomatt_Sync_V1_Hello? { localHellos[peerID] }

    func retainOutboundResumeHello(_ hello: Tomatt_Sync_V1_Hello, for peerID: String) {
        localHellos[peerID] = hello
    }

    func prepareOutboundResume(peerID: String) -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        guard let localIdentity else { return .failure(.notReady("Local sync identity is unavailable")) }
        do {
            guard let peer = try peerStore.trustedPeer(deviceID: peerID) else { return .failure(.untrustedPeer(peerID)) }
            guard !peer.isRemoved else { return .failure(.removedPeer(peerID)) }
            let activeGroups = try metadataStore.loadActiveSyncGroupMetadata()
            guard activeGroups.count == 1 else { return .failure(.notReady(activeGroups.isEmpty ? "missing active sync group" : "multiple active sync groups")) }
            guard let groupKey = try groupKeyStore.loadSyncGroupKey(groupID: activeGroups[0].groupID),
                  groupKey.keyID == activeGroups[0].keyID,
                  groupKey.isUsableForLANSync else { return .failure(.notReady("missing usable sync group key")) }
            let hello = Self.makeResumeHello(localIdentity: localIdentity,
                                             sessionKeyID: UUID().uuidString.lowercased(),
                                             sessionRole: .initiator,
                                             syncGroupID: activeGroups[0].groupID)
            localHellos[peerID] = hello
            return .success(hello)
        } catch {
            return .failure(.notReady(String(describing: error)))
        }
    }

    func prepareAnyOutboundResume() -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        guard let localIdentity else { return .failure(.notReady("Local sync identity is unavailable")) }
        do {
            let activeGroups = try metadataStore.loadActiveSyncGroupMetadata()
            guard activeGroups.count == 1 else { return .failure(.notReady(activeGroups.isEmpty ? "missing active sync group" : "multiple active sync groups")) }
            guard let groupKey = try groupKeyStore.loadSyncGroupKey(groupID: activeGroups[0].groupID),
                  groupKey.keyID == activeGroups[0].keyID,
                  groupKey.isUsableForLANSync else { return .failure(.notReady("missing usable sync group key")) }
            let hello = Self.makeResumeHello(localIdentity: localIdentity,
                                             sessionKeyID: UUID().uuidString.lowercased(),
                                             sessionRole: .initiator,
                                             syncGroupID: activeGroups[0].groupID)
            localHellos[""] = hello
            return .success(hello)
        } catch {
            return .failure(.notReady(String(describing: error)))
        }
    }

    private static func failure(from error: TBReconnectSessionHydrationError) -> TBLANEncryptedSessionAdmissionFailure {
        switch error {
        case .unpairedPeer(let peer): return .untrustedPeer(peer)
        case .removedPeer(let peer): return .removedPeer(peer)
        case .wrongGroup(let reason): return .wrongGroup(reason)
        case .pairingRequired(let reason), .missingSyncGroupKey(let reason), .retiredSyncGroupKey(let reason): return .notReady(reason)
        case .resetRequired(let reason), .invalidHello(let reason): return .notReady(reason)
        }
    }

    private static func makeResumeHello(localIdentity: TBSyncDevicePublicIdentity,
                                        sessionKeyID: String,
                                        sessionRole: Tomatt_Sync_V1_Hello.SessionRole,
                                        syncGroupID: String) -> Tomatt_Sync_V1_Hello {
        var hello = Tomatt_Sync_V1_Hello()
        hello.deviceID = localIdentity.deviceID
        hello.displayName = localIdentity.displayName
        hello.platform = localIdentity.platform ?? "macOS"
        hello.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        hello.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
        hello.sessionKeyID = sessionKeyID
        hello.sessionNonceSeed = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        hello.sessionRole = sessionRole
        hello.syncGroupID = syncGroupID
        return hello
    }
}

private extension TBPairingGroupState {
    var groupIDForRuntime: String {
        if case .grouped(let groupID) = self { return groupID }
        return ""
    }
}

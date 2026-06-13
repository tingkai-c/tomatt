import Foundation

enum TBSyncRuntimeMode: Equatable {
    case off
    case lanOnly
    case lanAndCloudRelay
}

enum TBSyncPeerRuntimeState: Equatable {
    case offline
    case discovered
    case connecting
    case pairing
    case verifying
    case syncing
    case upToDate
    case retryScheduled(Date)
    case blocked(String)
    case resetRequired(String)
    case removed
}

struct TBSyncRuntimePeer: Equatable {
    let deviceID: String
    var displayName: String
    var state: TBSyncPeerRuntimeState
    var lastSeenAt: Date?
}

enum TBSyncRuntimeStatusEvent: Equatable {
    case modeChanged(TBSyncRuntimeMode)
    case storageBlocked(TBSyncStorageHealthStatus)
    case lanStarted(port: Int)
    case lanStopped
    case cloudRelayUnavailable
    case peerStateChanged(deviceID: String, state: TBSyncPeerRuntimeState)
    case syncTriggered(deviceID: String, reason: TBSyncRuntimeSyncReason)
    case syncStatus(deviceID: String, TBAntiEntropySyncStatus)
}

enum TBSyncRuntimeSyncReason: Equatable {
    case connectionEstablished
    case localSyncableEventAppended
    case peerNotificationReceived
    case reconnect
}

protocol TBSyncStorageHealthChecking {
    func health() -> TBSyncStorageHealth
}

extension TBSyncStorageHealthService: TBSyncStorageHealthChecking {}

protocol TBSyncLANRuntimeControlling: AnyObject {
    var status: LANTransportStatus { get }
    var shouldReconnect: Bool { get }
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)? { get set }
    func start(discoveryID: LANDiscoveryID)
    func stop()
    func markDisconnected(peerID: String, direction: LANDuplicateConnectionDirection, now: Date, jitterUnit: Double)
}

extension LANTransportRuntimeModel: TBSyncLANRuntimeControlling {}

protocol TBSyncPeerEngine: AnyObject {
    func beginSync() -> TBAntiEntropySyncStepResult
    func notifyNewLocalEventsAvailable() -> TBAntiEntropySyncStepResult
    func receive(_ message: TBEncryptedLANMessage) -> TBAntiEntropySyncStepResult
}

extension TBAntiEntropySyncEngine: TBSyncPeerEngine {}

final class TBSyncRuntimeCoordinator {
    private let healthChecker: TBSyncStorageHealthChecking
    private let lanRuntime: TBSyncLANRuntimeControlling
    private let now: () -> Date
    private var peerEngines: [String: TBSyncPeerEngine] = [:]
    private var removedPeerIDs: Set<String> = []
    var remoteImportHandler: ((String, String) -> Void)?

    private(set) var mode: TBSyncRuntimeMode = .off
    private(set) var peers: [String: TBSyncRuntimePeer] = [:]
    private(set) var statusEvents: [TBSyncRuntimeStatusEvent] = []

    init(healthChecker: TBSyncStorageHealthChecking,
         lanRuntime: TBSyncLANRuntimeControlling,
         now: @escaping () -> Date = Date.init) {
        self.healthChecker = healthChecker
        self.lanRuntime = lanRuntime
        self.now = now
    }

    @discardableResult
    func setMode(_ newMode: TBSyncRuntimeMode, discoveryID: LANDiscoveryID = .ephemeral()) -> Bool {
        mode = newMode
        appendStatus(.modeChanged(newMode))

        if newMode == .off {
            stopLAN()
            return true
        }

        if newMode == .lanAndCloudRelay {
            appendStatus(.cloudRelayUnavailable)
        }

        let storageHealth = healthChecker.health()
        guard storageHealth.isLANSyncEnabled else {
            stopLAN()
            appendStatus(.storageBlocked(storageHealth.status))
            markAllPeersStorageBlocked(storageHealth.status)
            return false
        }

        lanRuntime.start(discoveryID: discoveryID)
        if case .active(let port) = lanRuntime.status {
            appendStatus(.lanStarted(port: port))
            return true
        }

        appendStatus(.storageBlocked(.lanSyncDisabledRequiresReset("LAN runtime failed to start")))
        return false
    }

    func registerEngine(_ engine: TBSyncPeerEngine, for deviceID: String, displayName: String? = nil) {
        peerEngines[deviceID] = engine
        ensurePeer(deviceID: deviceID, displayName: displayName ?? deviceID)
    }

    func markDiscovered(deviceID: String, displayName: String, lastSeenAt: Date? = nil) {
        guard !removedPeerIDs.contains(deviceID) else {
            updatePeer(deviceID: deviceID, displayName: displayName, state: .removed, lastSeenAt: lastSeenAt)
            return
        }
        updatePeer(deviceID: deviceID, displayName: displayName, state: .discovered, lastSeenAt: lastSeenAt ?? now())
    }

    @discardableResult
    func beginConnection(to deviceID: String) -> Bool {
        guard !removedPeerIDs.contains(deviceID) else {
            updatePeer(deviceID: deviceID, state: .removed)
            return false
        }
        updatePeer(deviceID: deviceID, state: .connecting)
        return true
    }

    func beginPairing(deviceID: String) {
        guard !removedPeerIDs.contains(deviceID) else { return updatePeer(deviceID: deviceID, state: .removed) }
        updatePeer(deviceID: deviceID, state: .pairing)
    }

    func beginVerification(deviceID: String) {
        guard !removedPeerIDs.contains(deviceID) else { return updatePeer(deviceID: deviceID, state: .removed) }
        updatePeer(deviceID: deviceID, state: .verifying)
    }

    func markRemoved(deviceID: String, displayName: String? = nil) {
        removedPeerIDs.insert(deviceID)
        peerEngines[deviceID] = nil
        updatePeer(deviceID: deviceID, displayName: displayName, state: .removed)
    }

    func resetRuntimeState() {
        peerEngines.removeAll()
        removedPeerIDs.removeAll()
        peers.removeAll()
        statusEvents.removeAll()
        remoteImportHandler = nil
        lanRuntime.stop()
        mode = .off
    }

    func scheduleRetry(deviceID: String,
                       direction: LANDuplicateConnectionDirection,
                       jitterUnit: Double = 0.5) {
        let timestamp = now()
        lanRuntime.markDisconnected(peerID: deviceID, direction: direction, now: timestamp, jitterUnit: jitterUnit)
        updatePeer(deviceID: deviceID, state: .retryScheduled(timestamp))
    }

    func triggerConnectionEstablishedSync(deviceID: String) -> [TBEncryptedLANMessage] {
        triggerSync(for: deviceID, reason: .connectionEstablished) { $0.beginSync() }
    }

    func triggerLocalSyncableEventAppended() -> [TBEncryptedLANMessage] {
        peerEngines.keys.sorted().flatMap { deviceID in
            triggerSync(for: deviceID, reason: .localSyncableEventAppended) { $0.notifyNewLocalEventsAvailable() }
        }
    }

    func receive(_ message: TBEncryptedLANMessage, from deviceID: String) -> [TBEncryptedLANMessage] {
        triggerSync(for: deviceID, reason: .peerNotificationReceived) { $0.receive(message) }
    }

    private func triggerSync(for deviceID: String,
                             reason: TBSyncRuntimeSyncReason,
                             step: (TBSyncPeerEngine) -> TBAntiEntropySyncStepResult) -> [TBEncryptedLANMessage] {
        guard !removedPeerIDs.contains(deviceID) else {
            updatePeer(deviceID: deviceID, state: .removed)
            return []
        }
        guard let engine = peerEngines[deviceID] else {
            updatePeer(deviceID: deviceID, state: .blocked("No sync engine for peer"))
            return []
        }

        updatePeer(deviceID: deviceID, state: .syncing)
        appendStatus(.syncTriggered(deviceID: deviceID, reason: reason))
        let result = step(engine)
        result.statuses.forEach { appendStatus(.syncStatus(deviceID: deviceID, $0)) }
        notifyRemoteImportIfNeeded(deviceID: deviceID, statuses: result.statuses)
        updatePeer(deviceID: deviceID, state: state(after: result.statuses))
        return result.outgoingMessages
    }

    private func state(after statuses: [TBAntiEntropySyncStatus]) -> TBSyncPeerRuntimeState {
        guard let error = statuses.compactMap({ status -> TBAntiEntropySyncError? in
            if case .error(let error) = status { return error }
            return nil
        }).first else { return .upToDate }

        switch error {
        case .importSecurity(.removedPeer(let peerID)), .session(.removedPeer(let peerID)):
            return .blocked("Removed peer: \(peerID)")
        case .importSecurity(.untrustedPeer(let peerID)), .session(.unpairedPeer(let peerID)):
            return .blocked("Pairing required: \(peerID)")
        case .importSecurity(.peerKeyMismatch), .session(.peerKeyMismatch), .session(.tamperedOrUnauthentic):
            return .resetRequired("Peer authentication failed")
        case .session(.unsupportedProtocolVersion(let version)):
            return .blocked("Unsupported session protocol version \(version)")
        case .importSecurity(.signedMetadataPersistenceFailed), .importSecurity(.resetDeletedRawEventLog):
            return .resetRequired("Sync storage error")
        case .importFailed:
            return .blocked("Remote events could not be imported")
        case .session, .protocolViolation, .signing, .importSecurity, .decoding, .signedMetadataMissing:
            return .retryScheduled(now())
        }
    }

    private func notifyRemoteImportIfNeeded(deviceID: String, statuses: [TBAntiEntropySyncStatus]) {
        let importedRemoteEvents = statuses.contains { status in
            if case .eventBatchImported(_, let outcome) = status {
                return outcome.imported > 0
            }
            return false
        }
        guard importedRemoteEvents else { return }
        remoteImportHandler?(deviceID, peers[deviceID]?.displayName ?? deviceID)
    }

    private func stopLAN() {
        lanRuntime.stop()
        appendStatus(.lanStopped)
    }

    private func markAllPeersStorageBlocked(_ status: TBSyncStorageHealthStatus) {
        let state: TBSyncPeerRuntimeState
        switch status {
        case .ready:
            state = .upToDate
        case .lanSyncDisabledRequiresPairing(let reason):
            state = .blocked(reason)
        case .lanSyncDisabledRequiresReset(let reason):
            state = .resetRequired(reason)
        }
        for deviceID in peers.keys { updatePeer(deviceID: deviceID, state: state) }
    }

    private func ensurePeer(deviceID: String, displayName: String) {
        guard peers[deviceID] == nil else { return }
        peers[deviceID] = TBSyncRuntimePeer(deviceID: deviceID,
                                            displayName: displayName,
                                            state: .offline,
                                            lastSeenAt: nil)
    }

    private func updatePeer(deviceID: String,
                            displayName: String? = nil,
                            state: TBSyncPeerRuntimeState,
                            lastSeenAt: Date? = nil) {
        var peer = peers[deviceID] ?? TBSyncRuntimePeer(deviceID: deviceID,
                                                        displayName: displayName ?? deviceID,
                                                        state: .offline,
                                                        lastSeenAt: nil)
        if let displayName { peer.displayName = displayName }
        peer.state = state
        if let lastSeenAt { peer.lastSeenAt = lastSeenAt }
        peers[deviceID] = peer
        appendStatus(.peerStateChanged(deviceID: deviceID, state: state))
    }

    private func appendStatus(_ event: TBSyncRuntimeStatusEvent) {
        statusEvents.append(event)
        let diagnostic = syncDiagnostic(for: event)
        logger.appendSyncDiagnostic(component: "TBSyncRuntimeCoordinator",
                                    event: diagnostic.event,
                                    peerID: diagnostic.peerID,
                                    reason: diagnostic.reason,
                                    counts: diagnostic.counts,
                                    details: diagnostic.details)
    }

    private func syncDiagnostic(for event: TBSyncRuntimeStatusEvent) -> (event: String, peerID: String?, reason: String?, counts: [String: Int]?, details: [String: String]?) {
        switch event {
        case .modeChanged(let mode):
            return ("status_mode_changed", nil, nil, nil, ["mode": String(describing: mode)])
        case .storageBlocked(let status):
            return ("status_storage_blocked", nil, String(describing: status), nil, nil)
        case .lanStarted(let port):
            return ("status_lan_started", nil, nil, ["port": port], nil)
        case .lanStopped:
            return ("status_lan_stopped", nil, nil, nil, nil)
        case .cloudRelayUnavailable:
            return ("status_cloud_relay_unavailable", nil, nil, nil, nil)
        case .peerStateChanged(let deviceID, let state):
            return ("status_peer_state_changed", deviceID, nil, nil, ["state": String(describing: state)])
        case .syncTriggered(let deviceID, let reason):
            return ("status_sync_triggered", deviceID, nil, nil, ["reason": String(describing: reason)])
        case .syncStatus(let deviceID, let status):
            return syncStatusDiagnostic(deviceID: deviceID, status: status)
        }
    }

    private func syncStatusDiagnostic(deviceID: String, status: TBAntiEntropySyncStatus) -> (event: String, peerID: String?, reason: String?, counts: [String: Int]?, details: [String: String]?) {
        switch status {
        case .summaryReceived(_, let eventCount):
            return ("status_summary_received", deviceID, nil, ["eventCount": Int(eventCount)], nil)
        case .missingEventsRequested(_, let afterSequence):
            return ("status_missing_events_requested", deviceID, nil, ["afterSequence": Int(afterSequence)], nil)
        case .eventBatchSent(_, let eventIDs):
            return ("status_event_batch_sent", deviceID, nil, ["eventCount": eventIDs.count], nil)
        case .eventBatchImported(_, let outcome):
            return ("status_event_batch_imported", deviceID, nil, ["imported": outcome.imported, "rejected": outcome.rejected], nil)
        case .eventBatchAcked(let ack):
            return ("status_event_batch_acked", deviceID, nil, ["accepted": ack.acceptedEventIDs.count, "rejected": ack.rejectedEventIDs.count], nil)
        case .newEventsAvailable(_, let eventCount):
            return ("status_new_events_available", deviceID, nil, ["eventCount": Int(eventCount)], nil)
        case .error(let error):
            return ("status_sync_error", deviceID, String(describing: error), nil, nil)
        }
    }
}

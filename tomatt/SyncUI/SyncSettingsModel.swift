import Foundation
import Combine

enum TBSyncMode: String, CaseIterable, Equatable {
    case off
    case lanOnly
    case lanAndCloudRelay

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .lanOnly:
            return "LAN only"
        case .lanAndCloudRelay:
            return "LAN + Cloud Relay"
        }
    }
}

enum TBSyncDeviceConnectionStatus: String, Equatable {
    case offline
    case discovered
    case connecting
    case pairing
    case verifying
    case syncing
    case upToDate
    case retryScheduled
    case blocked
    case resetRequired
    case removed

    var displayName: String {
        switch self {
        case .offline:
            return "Offline"
        case .discovered:
            return "Discovered"
        case .connecting:
            return "Connecting"
        case .pairing:
            return "Pairing"
        case .verifying:
            return "Verifying"
        case .syncing:
            return "Syncing"
        case .upToDate:
            return "Up to date"
        case .retryScheduled:
            return "Retry scheduled"
        case .blocked:
            return "Blocked"
        case .resetRequired:
            return "Reset required"
        case .removed:
            return "Removed"
        }
    }
}

struct TBPairedSyncDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var platform: String
    var lastSeen: Date?
    var status: TBSyncDeviceConnectionStatus

    init(id: UUID = UUID(),
         name: String,
         platform: String,
         lastSeen: Date? = nil,
         status: TBSyncDeviceConnectionStatus = .offline) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
        self.status = status
    }
}

enum TBSyncSettingsValidationError: Error, Equatable {
    case message(String)
}

struct TBSyncCapabilityGates: Equatable {
    var authenticatedEncryptionReady: Bool
    var signedTrustedImportReady: Bool
    var pairingReady: Bool
    var timerConflictTestsReady: Bool
    var realLANTransportAvailable: Bool
    var cloudRelayAvailable: Bool

    static let currentProductizedSurface = TBSyncCapabilityGates(
        authenticatedEncryptionReady: true,
        signedTrustedImportReady: true,
        pairingReady: true,
        timerConflictTestsReady: true,
        realLANTransportAvailable: true,
        cloudRelayAvailable: false
    )

    var securityModelReady: Bool {
        authenticatedEncryptionReady
            && signedTrustedImportReady
            && pairingReady
            && timerConflictTestsReady
    }

    var userFacingLANSyncAvailable: Bool {
        securityModelReady && realLANTransportAvailable
    }
}

@MainActor
final class TBSyncSettingsModel: ObservableObject {
    @Published var selectedMode: TBSyncMode
    @Published private(set) var pairedDevices: [TBPairedSyncDevice]

    let capabilityGates: TBSyncCapabilityGates
    let deviceName: String
    let deviceIdentity: String
    let lastSync: Date?
    let retryStatus: String?
    let listenerPort: Int
    let storageHealthStatus: TBSyncStorageHealthStatus
    let correctionNotice: String?
    let statusOverride: String?
    let actionMessage: String?
    let runtimeMode: TBSyncServiceRuntimeMode
    let resetAvailable: Bool
    let activePairingFlows: [TBPairingFlowPresentation]
    private weak var service: TBSyncServiceProviding?

    init(selectedMode: TBSyncMode = .off,
         pairedDevices: [TBPairedSyncDevice] = [],
         capabilityGates: TBSyncCapabilityGates = .currentProductizedSurface,
         deviceName: String? = nil,
         deviceIdentity: String? = nil,
         lastSync: Date? = nil,
         retryStatus: String? = nil,
         listenerPort: Int = LANTransportInternalPlaintext.defaultPort,
         storageHealthStatus: TBSyncStorageHealthStatus = .ready,
         correctionNotice: String? = nil,
          statusOverride: String? = nil,
          actionMessage: String? = nil,
          runtimeMode: TBSyncServiceRuntimeMode = .syncOff,
          resetAvailable: Bool = false,
          activePairingFlows: [TBPairingFlowPresentation] = [],
          service: TBSyncServiceProviding? = nil) {
        self.selectedMode = capabilityGates.userFacingLANSyncAvailable ? selectedMode : .off
        self.pairedDevices = pairedDevices
        self.capabilityGates = capabilityGates
        self.deviceName = deviceName ?? Self.defaultDeviceName()
        self.deviceIdentity = deviceIdentity ?? Self.defaultDeviceIdentity()
        self.lastSync = lastSync
        self.retryStatus = retryStatus
        self.listenerPort = listenerPort
        self.storageHealthStatus = storageHealthStatus
        self.correctionNotice = correctionNotice
        self.statusOverride = statusOverride
        self.actionMessage = actionMessage
        self.runtimeMode = runtimeMode
        self.resetAvailable = resetAvailable
        self.activePairingFlows = activePairingFlows
        self.service = service
    }

    convenience init(snapshot: TBSyncServiceSnapshot, service: TBSyncServiceProviding? = nil) {
        self.init(selectedMode: snapshot.selectedMode,
                  pairedDevices: snapshot.pairedDevices,
                  capabilityGates: snapshot.capabilityGates,
                  deviceName: snapshot.deviceName,
                  deviceIdentity: snapshot.deviceIdentity,
                  lastSync: snapshot.lastSync,
                  retryStatus: snapshot.retryStatus,
                  listenerPort: snapshot.listenerPort,
                  storageHealthStatus: snapshot.storageHealthStatus,
                  correctionNotice: snapshot.correctionNotice,
                   statusOverride: snapshot.statusMessage,
                   actionMessage: snapshot.actionMessage,
                   runtimeMode: snapshot.runtimeMode,
                   resetAvailable: snapshot.resetAvailable,
                   activePairingFlows: snapshot.activePairingFlows,
                   service: service)
    }

    convenience init(service: TBSyncServiceProviding) {
        self.init(snapshot: service.snapshot, service: service)
    }

    var isCloudRelaySelectable: Bool { capabilityGates.cloudRelayAvailable }

    var areLANSetupActionsEnabled: Bool { capabilityGates.userFacingLANSyncAvailable && !requiresReset }

    var canResetSync: Bool { resetAvailable }

    private var requiresReset: Bool {
        if case .lanSyncDisabledRequiresReset = storageHealthStatus { return true }
        return false
    }

    var pairDeviceFlow: TBPairDeviceFlowModel { TBPairDeviceFlowModel(internalRole: .addDevice) }

    var pairDeviceButtonTitle: String { "Pair Device…" }

    var pairByAddressButtonTitle: String { "Pair by Address…" }

    var statusText: String {
        if let statusOverride { return statusOverride }

        if !capabilityGates.securityModelReady {
            return "Sync is unavailable: encryption, trusted import, pairing, and timer conflict gates must all pass first."
        }

        if !capabilityGates.realLANTransportAvailable {
            return "LAN sync setup is not available in this build. Security, pairing, and transport foundations are present, but live runtime wiring is still internal."
        }

        if storageHealthStatus != .ready {
            return "LAN sync requires attention: \(storageHealthSummary)."
        }

        switch selectedMode {
        case .off:
            if runtimeMode == .pairingSetup {
                return "Pairing setup is active. Pairing and resume handshakes use the LAN runtime when peers connect."
            }
            return "Sync is off."
        case .lanOnly:
            return "LAN sync is active on this local network."
        case .lanAndCloudRelay:
            return capabilityGates.cloudRelayAvailable
                ? "LAN sync is ready; Cloud Relay is enabled."
                : "Cloud Relay is planned for a future release and is unavailable in this build."
        }
    }

    var statusDetailText: String {
        let lastSyncText = lastSync.map { "Last sync: \(Self.relativeDateFormatter.localizedString(for: $0, relativeTo: Date()))." }
            ?? "Last sync: never."
        let retryText = retryStatus.map { "Retry: \($0)." } ?? "Retry: not scheduled."
        return "\(lastSyncText) \(retryText) Listening port: \(listenerPort)."
    }

    var securityCopy: String {
        "LAN sync uses authenticated encryption and imports only signed events from paired, trusted devices. Paired peers reconnect through protocol-validated resume handshakes."
    }

    var localNetworkPermissionCopy: String {
        "macOS may ask for Local Network access when tomatt browses for nearby devices, advertises this Mac, or listens on port \(listenerPort). Pair Device and Pair by Address start pairing setup when storage health permits it."
    }

    var syncDebugLogCopy: String {
        "Sync diagnostics are written to ~/Library/Containers/app.tomatt.tomatt/Data/Library/Caches/tomatt.log as JSON lines."
    }

    var incompleteFeatureCopy: String {
        "Cloud Relay is unavailable in this build. LAN pairing and paired-peer resume use the local network only."
    }

    var portOverrideCopy: String {
        listenerPort == LANTransportInternalPlaintext.defaultPort
            ? "Using default LAN sync port 40484. Change this only if the port is unavailable."
            : "Using custom LAN sync port \(listenerPort). Use the same port when pairing by address."
    }

    var resetSyncCopy: String {
        "Reset Sync removes local sync identity, trusted peers, and sync metadata, but preserves local timer/history events. Re-pair devices afterward."
    }

    var removeDeviceCopy: String {
        "Remove Device is operational-only in this version: it stops future sync attempts with that peer but does not erase copies already received by other devices."
    }

    var storageHealthSummary: String {
        switch storageHealthStatus {
        case .ready:
            return "Ready"
        case .lanSyncDisabledRequiresPairing(let reason):
            return "Pairing required (\(reason))"
        case .lanSyncDisabledRequiresReset(let reason):
            return "Reset required (\(reason))"
        }
    }

    var shouldShowCorrectionNotice: Bool { correctionNotice != nil }

    func validatePortOverride(_ text: String) -> Result<Int, TBSyncSettingsValidationError> {
        guard let port = Int(text), LANPort.isValid(port) else {
            return .failure(.message("Enter a port between 1 and 65535."))
        }
        return .success(port)
    }

    func manualEndpoint(host: String, portText: String? = nil) -> Result<LANManualEndpoint, TBSyncSettingsValidationError> {
        do {
            let port: Int
            if let portText, !portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch validatePortOverride(portText) {
                case .success(let parsedPort):
                    port = parsedPort
                case .failure(let message):
                    return .failure(message)
                }
            } else {
                port = listenerPort
            }
            return .success(try LANManualEndpoint(host: host, port: port))
        } catch LANManualEndpointValidationError.emptyHost {
            return .failure(.message("Enter an IP address, Tailscale address, or hostname."))
        } catch LANManualEndpointValidationError.invalidHost {
            return .failure(.message("Enter a valid LAN IP, Tailscale address, or hostname."))
        } catch LANManualEndpointValidationError.invalidPort {
            return .failure(.message("Enter a port between 1 and 65535."))
        } catch {
            return .failure(.message("The pairing address is invalid."))
        }
    }

    func isModeSelectable(_ mode: TBSyncMode) -> Bool {
        switch mode {
        case .off:
            return true
        case .lanOnly:
            return capabilityGates.userFacingLANSyncAvailable
        case .lanAndCloudRelay:
            return capabilityGates.userFacingLANSyncAvailable && capabilityGates.cloudRelayAvailable
        }
    }

    func selectMode(_ mode: TBSyncMode) {
        guard isModeSelectable(mode) else { return }
        if let service {
            service.selectMode(mode)
            return
        }
        selectedMode = mode
    }

    @discardableResult
    func startPairDevice() -> TBSyncServiceActionResult {
        service?.startPairDevice() ?? .blocked("Pairing setup is unavailable in this preview model.")
    }

    @discardableResult
    func pairByAddress(host: String, port: Int) -> TBSyncServiceActionResult {
        service?.pairByAddress(host: host, port: port) ?? .blocked("Manual pairing is unavailable in this preview model.")
    }

    @discardableResult
    func confirmVerificationCode(flowID: TBPairingRuntimeFlowID) -> TBSyncServiceActionResult {
        service?.confirmVerificationCode(flowID: flowID) ?? .blocked("Pairing verification is unavailable in this preview model.")
    }

    @discardableResult
    func approvePreview(flowID: TBPairingRuntimeFlowID,
                        settingsSource: TBPairingSettingsSourceChoice = .keepLocal) -> TBSyncServiceActionResult {
        service?.approvePreview(flowID: flowID, settingsSource: settingsSource) ?? .blocked("Pairing preview approval is unavailable in this preview model.")
    }

    @discardableResult
    func resetSync() -> TBSyncServiceActionResult {
        service?.resetSync() ?? .blocked("Reset Sync is unavailable in this preview model.")
    }

    func unpairDevice(id: UUID) {
        if let service {
            service.removeDevice(id: id)
            return
        }
        pairedDevices.removeAll { $0.id == id }
    }

    func deviceRows(from runtimePeers: [TBSyncRuntimePeer]) -> [TBPairedSyncDevice] {
        runtimePeers.map { peer in
            TBPairedSyncDevice(name: peer.displayName,
                               platform: "Paired device",
                               lastSeen: peer.lastSeenAt,
                               status: TBSyncDeviceConnectionStatus(peerState: peer.state))
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func defaultDeviceName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func defaultDeviceIdentity() -> String {
        "Local preview identity"
    }
}

extension TBSyncDeviceConnectionStatus {
    init(peerState: TBSyncPeerRuntimeState) {
        switch peerState {
        case .offline:
            self = .offline
        case .discovered:
            self = .discovered
        case .connecting:
            self = .connecting
        case .pairing:
            self = .pairing
        case .verifying:
            self = .verifying
        case .syncing:
            self = .syncing
        case .upToDate:
            self = .upToDate
        case .retryScheduled:
            self = .retryScheduled
        case .blocked:
            self = .blocked
        case .resetRequired:
            self = .resetRequired
        case .removed:
            self = .removed
        }
    }
}

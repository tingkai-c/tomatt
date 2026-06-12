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
    case pairingRequired
    case internalPreviewOnly

    var displayName: String {
        switch self {
        case .offline:
            return "Offline"
        case .pairingRequired:
            return "Pairing required"
        case .internalPreviewOnly:
            return "Internal preview only"
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
        realLANTransportAvailable: false,
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

final class TBSyncSettingsModel: ObservableObject {
    @Published var selectedMode: TBSyncMode
    @Published private(set) var pairedDevices: [TBPairedSyncDevice]

    let capabilityGates: TBSyncCapabilityGates
    let deviceName: String
    let deviceIdentity: String
    let lastSync: Date?
    let retryStatus: String?

    init(selectedMode: TBSyncMode = .off,
         pairedDevices: [TBPairedSyncDevice] = [],
         capabilityGates: TBSyncCapabilityGates = .currentProductizedSurface,
         deviceName: String = TBSyncSettingsModel.defaultDeviceName(),
         deviceIdentity: String = TBSyncSettingsModel.defaultDeviceIdentity(),
         lastSync: Date? = nil,
         retryStatus: String? = nil) {
        self.selectedMode = capabilityGates.userFacingLANSyncAvailable ? selectedMode : .off
        self.pairedDevices = pairedDevices
        self.capabilityGates = capabilityGates
        self.deviceName = deviceName
        self.deviceIdentity = deviceIdentity
        self.lastSync = lastSync
        self.retryStatus = retryStatus
    }

    var isCloudRelaySelectable: Bool { capabilityGates.cloudRelayAvailable }

    var areLANSetupActionsEnabled: Bool { capabilityGates.userFacingLANSyncAvailable }

    var addDeviceButtonTitle: String { "Add Device" }

    var joinSyncGroupButtonTitle: String { "Join Sync Group" }

    var statusText: String {
        if !capabilityGates.securityModelReady {
            return "Sync is unavailable: encryption, trusted import, pairing, and timer conflict gates must all pass first."
        }

        if !capabilityGates.realLANTransportAvailable {
            return "LAN sync setup is not available in this build. Security and pairing models are present, but real local-network transport is still internal preview."
        }

        switch selectedMode {
        case .off:
            return "Sync is off."
        case .lanOnly:
            return "LAN sync is ready for paired devices on this local network."
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
        return "\(lastSyncText) \(retryText)"
    }

    var securityCopy: String {
        "The sync design uses authenticated encryption and imports only signed events from paired, trusted devices; real LAN transport remains unavailable in this build."
    }

    var localNetworkPermissionCopy: String {
        "macOS asks for Local Network access only when tomatt starts browsing or advertising nearby sync devices. The current build does not start that transport automatically."
    }

    var incompleteFeatureCopy: String {
        "Real LAN server/client hookup is not productized yet; this pane is a setup and status surface, not an active network-sync claim. Cloud Relay is future/unavailable."
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
        selectedMode = mode
    }

    func unpairDevice(id: UUID) {
        pairedDevices.removeAll { $0.id == id }
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

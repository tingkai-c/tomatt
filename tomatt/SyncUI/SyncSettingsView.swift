import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject private var service: TBSyncService
    @State private var addressHost = ""
    @State private var addressPort = ""
    @State private var manualAddressMessage: String?

    init(service: TBSyncService) {
        self.service = service
    }

    private var model: TBSyncSettingsModel { TBSyncSettingsModel(service: service) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                syncModeSection
                statusSection
                networkSection
                deviceSection
                pairingSection
                privacySection
            }
            .padding(28)
            .frame(width: SettingsLayout.contentWidth, alignment: .topLeading)
        }
        .frame(minWidth: SettingsLayout.windowWidth,
               minHeight: SettingsLayout.windowHeight,
               alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var syncModeSection: some View {
        SyncSettingsSection(title: "Sync") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TBSyncMode.allCases, id: \.self) { mode in
                    Button {
                        model.selectMode(mode)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selectedMode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(model.isModeSelectable(mode) ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                if mode == .lanAndCloudRelay {
                                    Text("Future/unavailable: Cloud Relay is not included in this build.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isModeSelectable(mode))
                }
            }
            .padding(16)
        }
    }

    private var statusSection: some View {
        SyncSettingsSection(title: "Status") {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.statusText, systemImage: model.capabilityGates.userFacingLANSyncAvailable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(model.capabilityGates.userFacingLANSyncAvailable ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.statusDetailText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let correctionNotice = model.correctionNotice {
                    Label(correctionNotice, systemImage: "arrow.triangle.2.circlepath.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let actionMessage = model.actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(model.incompleteFeatureCopy)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var networkSection: some View {
        SyncSettingsSection(title: "Network") {
            VStack(alignment: .leading, spacing: 12) {
                deviceInfoRow(title: "Storage", value: model.storageHealthSummary)
                deviceInfoRow(title: "Port", value: String(model.listenerPort))
                Text(model.portOverrideCopy)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Reset Sync…") {
                        _ = model.resetSync()
                    }
                    .foregroundColor(.red)
                    .disabled(!model.canResetSync)
                    Spacer()
                }
                Text(model.resetSyncCopy)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
            .padding(16)
        }
    }

    private var deviceSection: some View {
        SyncSettingsSection(title: "This Device") {
            VStack(alignment: .leading, spacing: 8) {
                deviceInfoRow(title: "Name", value: model.deviceName)
                deviceInfoRow(title: "Identity", value: model.deviceIdentity)
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 13))
            .padding(16)
        }
    }

    private func deviceInfoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .fontWeight(.semibold)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var pairingSection: some View {
        SyncSettingsSection(title: "Paired Devices") {
            VStack(alignment: .leading, spacing: 14) {
                if model.pairedDevices.isEmpty {
                    Text("No paired devices yet. Use Pair Device for nearby devices or Pair by Address for LAN IP/Tailscale/hostname pairing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.pairedDevices) { device in
                            pairedDeviceRow(device)
                            if device.id != model.pairedDevices.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                pairingFlowControls

                HStack(spacing: 10) {
                    Button(model.pairDeviceButtonTitle) {
                        _ = model.startPairDevice()
                    }
                        .disabled(!model.areLANSetupActionsEnabled)
                    Button(model.pairByAddressButtonTitle) {
                        pairByAddress()
                    }
                        .disabled(!model.areLANSetupActionsEnabled)
                    Spacer()
                }
                .help(model.capabilityGates.realLANTransportAvailable
                      ? "Start secure pairing on the local network or by address."
                      : "Pairing setup is disabled because LAN transport is unavailable.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair by Address")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        TextField("IP, Tailscale address, or hostname", text: $addressHost)
                        TextField(String(model.listenerPort), text: $addressPort)
                            .frame(width: 86)
                    }
                    Text("Uses the same verification, encryption, and preview flow as nearby-device pairing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let manualAddressMessage {
                        Text(manualAddressMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(model.removeDeviceCopy)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var pairingFlowControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.activePairingFlows) { flow in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing with \(flow.remoteDisplayName)")
                        .font(.system(size: 13, weight: .semibold))
                    if let code = flow.verificationCode {
                        Text("Verification code: \(code)")
                            .font(.system(.body, design: .monospaced))
                        Button("Confirm Matching Code") {
                            _ = model.confirmVerificationCode(flowID: flow.id)
                        }
                    }
                    if let preview = flow.preview {
                        Text(preview.settingsDiffer ? "Review settings before approving pairing." : "Preview ready. Local settings will be kept.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Approve Preview") {
                            _ = model.approvePreview(flowID: flow.id, settingsSource: .keepLocal)
                        }
                    }
                }
            }
        }
    }

    private func pairedDeviceRow(_ device: TBPairedSyncDevice) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(device.platform) • \(lastSeenText(device.lastSeen)) • \(device.status.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Remove") {
                model.unpairDevice(id: device.id)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private var privacySection: some View {
        SyncSettingsSection(title: "Privacy & Local Network Permission") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.securityCopy)
                Text(model.localNetworkPermissionCopy)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
        }
    }

    private func lastSeenText(_ date: Date?) -> String {
        guard let date else { return "Never seen" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func pairByAddress() {
        switch model.manualEndpoint(host: addressHost, portText: addressPort) {
        case .success(let endpoint):
            let result = model.pairByAddress(host: endpoint.host, port: endpoint.port)
            switch result {
            case .started(let message), .blocked(let message), .reset(let message), .stopped(let message):
                manualAddressMessage = message
            }
        case .failure(.message(let message)):
            manualAddressMessage = message
        }
    }
}

private struct SyncSettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

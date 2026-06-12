import SwiftUI

struct SyncSettingsView: View {
    @StateObject private var model = TBSyncSettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                syncModeSection
                statusSection
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
                                } else if mode == .lanOnly && !model.capabilityGates.realLANTransportAvailable {
                                    Text("Unavailable until real LAN server/client transport is productized.")
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

                Text(model.incompleteFeatureCopy)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    Text("No paired devices yet. Add and Join are visible for setup, but disabled until real LAN transport is available.")
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

                HStack(spacing: 10) {
                    Button(model.addDeviceButtonTitle) {}
                        .disabled(!model.areLANSetupActionsEnabled)
                    Button(model.joinSyncGroupButtonTitle) {}
                        .disabled(!model.areLANSetupActionsEnabled)
                    Spacer()
                }
                .help(model.capabilityGates.realLANTransportAvailable
                      ? "Start secure pairing on the local network."
                      : "Pairing setup is disabled until real LAN transport is productized.")
            }
            .padding(16)
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
            Button("Unpair") {
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

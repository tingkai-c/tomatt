import XCTest

@MainActor
final class SyncSettingsModelTests: XCTestCase {
    func testCloudRelayIsUnavailableByDefault() {
        let model = TBSyncSettingsModel()

        XCTAssertFalse(model.isCloudRelaySelectable)
        XCTAssertFalse(model.isModeSelectable(.lanAndCloudRelay))
        XCTAssertTrue(model.isModeSelectable(.lanOnly))
        XCTAssertTrue(model.incompleteFeatureCopy.contains("Cloud Relay"))
        XCTAssertTrue(model.incompleteFeatureCopy.contains("unavailable"))
    }

    func testUserFacingSyncRequiresSecurityAndRealTransportGates() {
        let secureButNoTransport = TBSyncSettingsModel(capabilityGates: TBSyncCapabilityGates(
            authenticatedEncryptionReady: true,
            signedTrustedImportReady: true,
            pairingReady: true,
            timerConflictTestsReady: true,
            realLANTransportAvailable: false,
            cloudRelayAvailable: false
        ))
        XCTAssertFalse(secureButNoTransport.areLANSetupActionsEnabled)
        XCTAssertFalse(secureButNoTransport.isModeSelectable(.lanOnly))

        let ready = TBSyncSettingsModel(capabilityGates: TBSyncCapabilityGates(
            authenticatedEncryptionReady: true,
            signedTrustedImportReady: true,
            pairingReady: true,
            timerConflictTestsReady: true,
            realLANTransportAvailable: true,
            cloudRelayAvailable: false
        ))

        XCTAssertTrue(ready.areLANSetupActionsEnabled)
        XCTAssertTrue(ready.isModeSelectable(.lanOnly))
        XCTAssertFalse(ready.isModeSelectable(.lanAndCloudRelay))
    }

    func testRemoveUnpairUpdatesDeviceList() {
        let first = TBPairedSyncDevice(name: "MacBook", platform: "macOS")
        let second = TBPairedSyncDevice(name: "iMac", platform: "macOS")
        let model = TBSyncSettingsModel(pairedDevices: [first, second])

        model.unpairDevice(id: first.id)

        XCTAssertEqual(model.pairedDevices, [second])
    }

    func testOnePairDeviceActionIsUserFacingSetupTerm() {
        let model = TBSyncSettingsModel()

        XCTAssertEqual(model.pairDeviceButtonTitle, "Pair Device…")
        XCTAssertEqual(model.pairByAddressButtonTitle, "Pair by Address…")
        XCTAssertFalse(model.pairDeviceFlow.exposesTopLevelAddOrJoinActions)
    }

    func testStatusAndPermissionCopyAreExplicitAboutLANRuntime() {
        let model = TBSyncSettingsModel(selectedMode: .lanOnly)

        XCTAssertTrue(model.securityCopy.contains("authenticated encryption"))
        XCTAssertTrue(model.securityCopy.contains("authenticated encryption"))
        XCTAssertTrue(model.securityCopy.contains("resume handshakes"))
        XCTAssertTrue(model.localNetworkPermissionCopy.contains("Local Network access"))
        XCTAssertTrue(model.localNetworkPermissionCopy.contains("40484"))
        XCTAssertTrue(model.statusDetailText.contains("Last sync"))
        XCTAssertTrue(model.statusDetailText.contains("Listening port: 40484"))
        XCTAssertEqual(model.statusText, "LAN sync is active on this local network.")
        XCTAssertTrue(model.resetSyncCopy.contains("preserves local timer/history events"))
        XCTAssertTrue(model.removeDeviceCopy.contains("operational-only"))
    }

    func testManualPairByAddressAcceptsTailscaleAndPortOverride() throws {
        let model = TBSyncSettingsModel(listenerPort: 50505)

        let endpoint = try model.manualEndpoint(host: "macbook.tailnet.ts.net").get()
        let overrideEndpoint = try model.manualEndpoint(host: "192.168.1.23", portText: "40484").get()

        XCTAssertEqual(endpoint.host, "macbook.tailnet.ts.net")
        XCTAssertEqual(endpoint.port, 50505)
        XCTAssertEqual(overrideEndpoint.host, "192.168.1.23")
        XCTAssertEqual(overrideEndpoint.port, 40484)
    }

    func testManualPairByAddressRejectsInvalidInputs() {
        let model = TBSyncSettingsModel()

        XCTAssertEqual(try? model.manualEndpoint(host: "").get().host, nil)
        XCTAssertEqual(try? model.manualEndpoint(host: "bad host").get().host, nil)
        XCTAssertEqual(model.validatePortOverride("70000"), .failure(.message("Enter a port between 1 and 65535.")))
    }

    func testStorageHealthAndCorrectionNoticeSurface() {
        let model = TBSyncSettingsModel(storageHealthStatus: .lanSyncDisabledRequiresReset("corrupt key"),
                                        correctionNotice: "Timer state was corrected after sync.")

        XCTAssertTrue(model.statusText.contains("requires attention"))
        XCTAssertEqual(model.storageHealthSummary, "Reset required (corrupt key)")
        XCTAssertTrue(model.shouldShowCorrectionNotice)
        XCTAssertEqual(model.correctionNotice, "Timer state was corrected after sync.")
    }

    func testRuntimePeersMapToDeviceRows() {
        let model = TBSyncSettingsModel()
        let rows = model.deviceRows(from: [
            TBSyncRuntimePeer(deviceID: "a", displayName: "MacBook", state: .syncing, lastSeenAt: Date(timeIntervalSince1970: 1)),
            TBSyncRuntimePeer(deviceID: "b", displayName: "iMac", state: .retryScheduled(Date(timeIntervalSince1970: 2)), lastSeenAt: nil),
            TBSyncRuntimePeer(deviceID: "c", displayName: "Removed", state: .removed, lastSeenAt: nil),
        ])

        XCTAssertEqual(rows.map(\.name), ["MacBook", "iMac", "Removed"])
        XCTAssertEqual(rows.map(\.status), [.syncing, .retryScheduled, .removed])
    }

    func testActivePairingFlowSnapshotSurfacesVerificationState() {
        let flow = TBPairingFlowPresentation(id: TBPairingRuntimeFlowID(rawValue: "flow-1"),
                                             remoteDisplayName: "Peer Mac",
                                             verificationCode: "123-456",
                                             preview: nil)
        var snapshot = TBSyncServiceSnapshot.preview()
        snapshot.activePairingFlows = [flow]

        let model = TBSyncSettingsModel(snapshot: snapshot)

        XCTAssertEqual(model.activePairingFlows, [flow])
        XCTAssertTrue(model.activePairingFlows[0].isAwaitingVerificationConfirmation)
    }
}

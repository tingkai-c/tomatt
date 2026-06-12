import XCTest

final class SyncSettingsModelTests: XCTestCase {
    func testCloudRelayIsUnavailableByDefault() {
        let model = TBSyncSettingsModel()

        XCTAssertFalse(model.isCloudRelaySelectable)
        XCTAssertFalse(model.isModeSelectable(.lanAndCloudRelay))
        XCTAssertTrue(model.statusText.contains("LAN sync setup is not available"))
        XCTAssertTrue(model.incompleteFeatureCopy.contains("Cloud Relay is future/unavailable"))
    }

    func testUserFacingSyncRequiresSecurityAndRealTransportGates() {
        let secureButNoTransport = TBSyncSettingsModel(capabilityGates: .currentProductizedSurface)
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

    func testStatusAndPermissionCopyAreExplicitAboutPreviewTransport() {
        let model = TBSyncSettingsModel()

        XCTAssertTrue(model.securityCopy.contains("authenticated encryption"))
        XCTAssertTrue(model.securityCopy.contains("real LAN transport remains unavailable"))
        XCTAssertTrue(model.localNetworkPermissionCopy.contains("Local Network access"))
        XCTAssertTrue(model.localNetworkPermissionCopy.contains("does not start that transport automatically"))
        XCTAssertTrue(model.statusDetailText.contains("Last sync"))
    }
}

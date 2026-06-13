import XCTest

@MainActor
final class SyncServiceTests: XCTestCase {
    func testZeroActiveGroupPermitsPairingSetupButBlocksLanSync() {
        let lanRuntime = FakeServiceLANRuntime()
        let health = FakeServiceHealth(pairing: .ready,
                                       lan: .lanSyncDisabledRequiresPairing("missing active sync group"))
        let service = makeService(lanRuntime: lanRuntime, health: health)

        let pairingResult = service.startPairDevice()
        XCTAssertEqual(pairingResult, .started("Pairing setup is active. Waiting for a nearby device to enter the pairing runtime flow."))
        XCTAssertEqual(service.snapshot.runtimeMode, .pairingSetup)
        XCTAssertEqual(lanRuntime.startCount, 1)

        let lanResult = service.selectMode(.lanOnly)
        XCTAssertEqual(lanResult, .blocked("LAN sync is blocked: Pairing required (missing active sync group)."))
        XCTAssertEqual(service.snapshot.runtimeMode, .syncOff)
        XCTAssertEqual(lanRuntime.stopCount, 2)
    }

    func testLanSyncStartsAfterReadyHealth() {
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready))

        let result = service.selectMode(.lanOnly)

        XCTAssertEqual(result, .started("LAN sync started."))
        XCTAssertEqual(service.snapshot.selectedMode, .lanOnly)
        XCTAssertEqual(service.snapshot.runtimeMode, .lanSync)
        XCTAssertEqual(coordinator.setModes, [.lanOnly])
        XCTAssertEqual(lanRuntime.startCount, 1)
    }

    func testSyncOffStopsLanRuntime() {
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready))

        _ = service.selectMode(.lanOnly)
        let result = service.selectMode(.off)

        XCTAssertEqual(result, .stopped("Sync is off."))
        XCTAssertEqual(service.snapshot.runtimeMode, .syncOff)
        XCTAssertEqual(coordinator.setModes.last, .off)
        XCTAssertGreaterThanOrEqual(lanRuntime.stopCount, 1)
    }

    func testResetRequiredBlocksPairingActions() {
        let service = makeService(health: FakeServiceHealth(pairing: .lanSyncDisabledRequiresReset("corrupt device signing key"),
                                                            lan: .lanSyncDisabledRequiresReset("corrupt device signing key")))

        let result = service.startPairDevice()

        XCTAssertEqual(result, .blocked("Pairing setup is blocked: Reset required (corrupt device signing key)."))
        XCTAssertEqual(service.snapshot.runtimeMode, .syncOff)
    }

    func testSettingsActionModelCallsFakeService() {
        let fakeService = FakeSettingsService()
        let model = TBSyncSettingsModel(service: fakeService)

        model.selectMode(.lanOnly)
        _ = model.startPairDevice()
        _ = model.pairByAddress(host: "macbook.local", port: 40484)
        _ = model.confirmVerificationCode(flowID: TBPairingRuntimeFlowID(rawValue: "flow-1"))
        _ = model.approvePreview(flowID: TBPairingRuntimeFlowID(rawValue: "flow-1"), settingsSource: .keepLocal)
        _ = model.resetSync()
        model.unpairDevice(id: fakeService.snapshot.pairedDevices[0].id)

        XCTAssertEqual(fakeService.selectedModes, [.lanOnly])
        XCTAssertEqual(fakeService.startPairDeviceCount, 1)
        XCTAssertEqual(fakeService.pairByAddressCalls, ["macbook.local:40484"])
        XCTAssertEqual(fakeService.confirmedFlowIDs, [TBPairingRuntimeFlowID(rawValue: "flow-1")])
        XCTAssertEqual(fakeService.approvedPreviewCalls.map(\.flowID), [TBPairingRuntimeFlowID(rawValue: "flow-1")])
        XCTAssertEqual(fakeService.approvedPreviewCalls.map(\.settingsSource), [.keepLocal])
        XCTAssertEqual(fakeService.resetCount, 1)
        XCTAssertEqual(fakeService.removedIDs, [fakeService.snapshot.pairedDevices[0].id])
    }

    func testNoEnabledNoOpControlsAndCloudRelayDisabled() {
        let noResetSnapshot = TBSyncServiceSnapshot.preview()
        let noResetModel = TBSyncSettingsModel(snapshot: noResetSnapshot)
        XCTAssertFalse(noResetModel.canResetSync)
        XCTAssertTrue(noResetModel.areLANSetupActionsEnabled)
        XCTAssertFalse(noResetModel.isModeSelectable(.lanAndCloudRelay))

        var resetRequired = TBSyncServiceSnapshot.preview()
        resetRequired.storageHealthStatus = .lanSyncDisabledRequiresReset("sync storage error")
        resetRequired.resetAvailable = true
        let resetRequiredModel = TBSyncSettingsModel(snapshot: resetRequired)
        XCTAssertFalse(resetRequiredModel.areLANSetupActionsEnabled)
        XCTAssertTrue(resetRequiredModel.canResetSync)
    }

    func testManualPairByAddressUsesConnectorAndEntersPairingRuntimeFlow() {
        let connector = FakeManualConnector()
        let service = makeService(health: FakeServiceHealth(pairing: .ready, lan: .lanSyncDisabledRequiresPairing("missing active sync group")),
                                  manualConnector: connector)

        let result = service.pairByAddress(host: "macbook.local", port: 40484)

        XCTAssertEqual(result, .started("Manual pairing connection started for macbook.local:40484."))
        XCTAssertEqual(connector.endpoints.map { "\($0.host):\($0.port)" }, ["macbook.local:40484"])
        XCTAssertEqual(service.snapshot.runtimeMode, .pairingSetup)
        XCTAssertEqual(service.snapshot.actionMessage, "Connected to macbook.local:40484. Pairing runtime flow is active and awaiting peer verification data.")
        XCTAssertEqual(connector.sessions.first?.sentEnvelopes.first?.pairingStart.displayName, "Test Mac")
    }

    func testAcceptedAnonymousPairingStartRoutesToPairingRuntimeWhileSetupActive() throws {
        let coordinator = FakeServiceCoordinator(lanRuntime: FakeServiceLANRuntime())
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(), coordinator: coordinator)
        let service = makeService(coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .lanSyncDisabledRequiresPairing("missing active sync group")),
                                  router: router)
        let session = FakeManualSession(endpointDescription: "accepted")
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        envelope.pairingStart = Tomatt_Sync_V1_PairingStart.with {
            $0.deviceID = "00000000-0000-0000-0000-000000000499"
            $0.displayName = "Peer"
            $0.participant = pairingProtoParticipant(deviceID: $0.deviceID,
                                                     displayName: $0.displayName,
                                                     sessionNonce: Data(repeating: 5, count: 32))
        }

        _ = service.startPairDevice()
        router.admit(session: session)
        router.handleEnvelope(envelope, from: session)

        XCTAssertFalse(session.isClosed)
        XCTAssertEqual(coordinator.pairingPeerIDs, ["00000000-0000-0000-0000-000000000499"])
        XCTAssertEqual(session.sentEnvelopes.first?.pairingChallenge.participant.deviceID, "00000000-0000-0000-0000-000000000401")
    }

    func testManualFirstPairingTranscriptRetainsRuntimeFlowAndDerivesMatchingKeyMaterial() throws {
        let connector = FakeManualConnector()
        let pairingRuntime = TBPairingRuntimeCoordinator()
        let coordinator = FakeServiceCoordinator(lanRuntime: FakeServiceLANRuntime())
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(), coordinator: coordinator)
        let peerStore = TBInMemoryTrustedPeerStore()
        let persister = TBDefaultPairingCommitPersister(peerStore: peerStore,
                                                        metadataStore: TBInMemorySyncGroupMetadataStore(),
                                                        groupKeyStore: TBInMemorySyncGroupKeyStore())
        let engineMaker = FakeEngineMaker()
        let localSigner = TBDeterministicTestSigner(secret: Data("default-local".utf8))
        let localIdentity = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                       displayName: "Test Mac",
                                                       platform: "macOS",
                                                       signingPublicKey: localSigner.publicKey)
        let service = makeService(health: FakeServiceHealth(pairing: .ready, lan: .lanSyncDisabledRequiresPairing("missing active sync group")),
                                  coordinator: coordinator,
                                  manualConnector: connector,
                                  router: router,
                                  pairingRuntime: pairingRuntime,
                                  pairingCommitPersister: persister,
                                  localIdentity: localIdentity,
                                  engineMaker: engineMaker)

        _ = service.pairByAddress(host: "peer.local", port: 40484)
        let session = try XCTUnwrap(connector.sessions.first)
        let start = try XCTUnwrap(session.sentEnvelopes.first?.pairingStart)
        let remoteKeyPair = TBPairingEphemeralKeyPair()
        var challenge = Tomatt_Sync_V1_Envelope()
        challenge.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        challenge.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
        challenge.pairingChallenge = Tomatt_Sync_V1_PairingChallenge.with {
            $0.challengeID = "challenge"
            $0.challenge = Data([1, 2, 3])
            $0.participant = pairingProtoParticipant(deviceID: "00000000-0000-0000-0000-000000000499",
                                                     displayName: "Peer",
                                                     sessionNonce: start.participant.sessionNonce,
                                                     keyPair: remoteKeyPair)
        }

        session.onEnvelopeReceived?(challenge)

        let flow = try XCTUnwrap(pairingRuntime.retainedFlows.first)
        XCTAssertEqual(flow.session.transcript.sessionNonce, start.participant.sessionNonce)
        XCTAssertTrue(service.snapshot.actionMessage?.contains("Pairing verification code") == true)
        let responderTranscript = TBPairingTranscript(protocolVersion: flow.session.transcript.protocolVersion,
                                                      role: .joinSyncGroup,
                                                      local: flow.session.transcript.remote,
                                                      remote: flow.session.transcript.local,
                                                      timestamp: flow.session.transcript.timestamp,
                                                      sessionNonce: flow.session.transcript.sessionNonce,
                                                      capabilities: flow.session.transcript.capabilities)
        let responderEstablishment = try remoteKeyPair.deriveSessionEstablishment(localTranscript: responderTranscript)
        XCTAssertEqual(flow.establishment.keyMaterial.rawKeyData, responderEstablishment.keyMaterial.rawKeyData)
        XCTAssertEqual(flow.establishment.localNonceSeed, responderEstablishment.peerNonceSeed)
        XCTAssertEqual(flow.establishment.peerNonceSeed, responderEstablishment.localNonceSeed)
        guard case .awaitingCodeConfirmation(let code) = flow.session.state else {
            return XCTFail("Expected verification code state")
        }
        XCTAssertEqual(service.snapshot.activePairingFlows.first?.verificationCode, code)
        XCTAssertEqual(service.snapshot.activePairingFlows.first?.remoteDisplayName, "Peer")

        XCTAssertEqual(service.confirmVerificationCode(flowID: flow.id), .started("Pairing verification code confirmed for Peer."))
        XCTAssertEqual(service.snapshot.activePairingFlows.first?.verificationCode, nil)
        XCTAssertNotNil(service.snapshot.activePairingFlows.first?.preview)
        XCTAssertEqual(service.approvePreview(flowID: flow.id, settingsSource: .keepLocal), .started("Paired Peer."))
        XCTAssertEqual(service.snapshot.activePairingFlows, [])
        XCTAssertNotNil(try peerStore.trustedPeer(deviceID: "00000000-0000-0000-0000-000000000499"))
        XCTAssertEqual(engineMaker.sessions.map { $0.context.peerDeviceID }, ["00000000-0000-0000-0000-000000000499"])
        XCTAssertEqual(coordinator.initialSyncPeerIDs, ["00000000-0000-0000-0000-000000000499"])
    }

    func testApprovePreviewCommitsAndKeepsFlowVisibleWhenCommitFails() throws {
        let peerStore = TBInMemoryTrustedPeerStore()
        let persister = ThrowingPairingCommitPersister(peerStore: peerStore,
                                                       error: FakeServiceError.injectedFailure)
        let localSigner = TBDeterministicTestSigner(secret: Data("local".utf8))
        let localIdentity = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                       displayName: "Local",
                                                       platform: "macOS",
                                                       signingPublicKey: localSigner.publicKey)
        let service = makeService(pairingCommitPersister: persister,
                                  localIdentity: localIdentity,
                                  engineMaker: FakeEngineMaker())
        let flowID = TBPairingRuntimeFlowID(rawValue: "flow-approve-fail")
        let session = try makePairingSessionAwaitingPreview(localIdentity: localIdentity)
        let establishment = try TBPairingSessionEstablishment(keyMaterial: .fixedTestKey(Data(repeating: 7, count: 32), keyID: "pairing-key"),
                                                              localRole: .initiator,
                                                              localNonceSeed: Data(repeating: 1, count: 32),
                                                              peerNonceSeed: Data(repeating: 2, count: 32))
        service.retainPairingRuntimeFlow(TBPairingRuntimeFlow(id: flowID,
                                                              session: session,
                                                              establishment: establishment,
                                                              lanSession: nil))

        let result = service.approvePreview(flowID: flowID, settingsSource: .keepLocal)

        guard case .blocked(let message) = result else { return XCTFail("Expected blocked result") }
        XCTAssertTrue(message.contains("Pairing commit failed"))
        XCTAssertEqual(service.snapshot.activePairingFlows.map(\.id), [flowID])
        XCTAssertNil(try peerStore.trustedPeer(deviceID: "00000000-0000-0000-0000-000000000402"))
    }

    func testSettingsModelApprovePreviewCommitsTrustGroupAndSessionBinding() throws {
        let coordinator = FakeServiceCoordinator(lanRuntime: FakeServiceLANRuntime())
        let peerStore = TBInMemoryTrustedPeerStore()
        let persister = FakePairingCommitPersister(peerStore: peerStore)
        let engineMaker = FakeEngineMaker()
        let localSigner = TBDeterministicTestSigner(secret: Data("local".utf8))
        let localIdentity = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                       displayName: "Local",
                                                       platform: "macOS",
                                                       signingPublicKey: localSigner.publicKey)
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(), coordinator: coordinator)
        let service = makeService(coordinator: coordinator,
                                  router: router,
                                  pairingCommitPersister: persister,
                                  localIdentity: localIdentity,
                                  engineMaker: engineMaker)
        let flowID = TBPairingRuntimeFlowID(rawValue: "flow-model-approve")
        let session = try makePairingSessionAwaitingPreview(localIdentity: localIdentity)
        let establishment = try TBPairingSessionEstablishment(keyMaterial: .fixedTestKey(Data(repeating: 7, count: 32), keyID: "pairing-key"),
                                                              localRole: .initiator,
                                                              localNonceSeed: Data(repeating: 1, count: 32),
                                                              peerNonceSeed: Data(repeating: 2, count: 32))
        let lanSession = FakeManualSession(endpointDescription: "paired")
        service.retainPairingRuntimeFlow(TBPairingRuntimeFlow(id: flowID,
                                                              session: session,
                                                              establishment: establishment,
                                                              lanSession: lanSession))
        let model = TBSyncSettingsModel(service: service)

        let result = model.approvePreview(flowID: flowID, settingsSource: .keepLocal)

        XCTAssertEqual(result, .started("Paired Peer."))
        XCTAssertNotNil(try peerStore.trustedPeer(deviceID: "00000000-0000-0000-0000-000000000402"))
        XCTAssertEqual(persister.savedMetadata?.groupID, "group-a")
        XCTAssertEqual(router.boundContext(for: "00000000-0000-0000-0000-000000000402")?.syncGroupID, "group-a")
        XCTAssertEqual(engineMaker.sessions.map { $0.context.peerDeviceID }, ["00000000-0000-0000-0000-000000000402"])
    }

    func testLocalPairingArtifactsUseActiveGroupWhenPresent() throws {
        let connector = FakeManualConnector()
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let groupStore = TBInMemorySyncGroupKeyStore()
        let activeKey = try TBSyncGroupKeyRecord.importExisting(groupID: "existing-group",
                                                               keyID: "existing-key",
                                                               secret: Data(repeating: 3, count: 32))
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: activeKey.groupID,
                                                                          keyID: activeKey.keyID,
                                                                          createdAt: activeKey.createdAt,
                                                                          state: .active))
        try groupStore.saveSyncGroupKey(activeKey)
        let persister = TBDefaultPairingCommitPersister(peerStore: TBInMemoryTrustedPeerStore(),
                                                        metadataStore: metadataStore,
                                                        groupKeyStore: groupStore)
        let service = makeService(health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  manualConnector: connector,
                                  pairingCommitPersister: persister)

        _ = service.pairByAddress(host: "peer.local", port: 40484)

        let groupState = try XCTUnwrap(connector.sessions.first?.sentEnvelopes.first?.pairingStart.participant.groupState)
        XCTAssertEqual(groupState.kind, .grouped)
        XCTAssertEqual(groupState.groupID, "existing-group")
    }

    func testLocalPairingArtifactsRemainStandaloneWhenNoActiveGroup() throws {
        let connector = FakeManualConnector()
        let persister = TBDefaultPairingCommitPersister(peerStore: TBInMemoryTrustedPeerStore(),
                                                        metadataStore: TBInMemorySyncGroupMetadataStore(),
                                                        groupKeyStore: TBInMemorySyncGroupKeyStore())
        let service = makeService(health: FakeServiceHealth(pairing: .ready, lan: .lanSyncDisabledRequiresPairing("missing active sync group")),
                                  manualConnector: connector,
                                  pairingCommitPersister: persister)

        _ = service.pairByAddress(host: "peer.local", port: 40484)

        XCTAssertEqual(connector.sessions.first?.sentEnvelopes.first?.pairingStart.participant.groupState.kind, .standalone)
    }

    func testManualPairByAddressToKnownPeerStartsOutboundResumeHello() throws {
        let connector = FakeManualConnector()
        let peerID = "00000000-0000-0000-0000-000000000402"
        let coordinator = FakeServiceCoordinator(lanRuntime: FakeServiceLANRuntime())
        coordinator.peers[peerID] = TBSyncRuntimePeer(deviceID: peerID, displayName: "Peer", state: .offline, lastSeenAt: nil)
        let admission = FakeServiceAdmission(context: serviceContext(peerID: peerID))
        admission.outboundHello = hello(deviceID: "00000000-0000-0000-0000-000000000401", role: .initiator, groupID: "group")
        let router = TBLANEncryptedSessionRouter(admission: admission, coordinator: coordinator)
        let service = makeService(coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  manualConnector: connector,
                                  router: router)

        _ = service.pairByAddress(host: peerID, port: 40484)

        let session = try XCTUnwrap(connector.sessions.first)
        XCTAssertEqual(session.sentEnvelopes.first?.hello.sessionRole, .initiator)
        XCTAssertEqual(session.sentEnvelopes.first?.hello.syncGroupID, "group")
        XCTAssertEqual(service.snapshot.runtimeMode, .lanSync)
    }

    func testBonjourDiscoveryWithoutStableDeviceIDConnectsAndSendsAnonymousOutboundResumeHello() throws {
        let lanRuntime = FakeServiceLANRuntime()
        let connector = FakeManualConnector()
        let peerID = "00000000-0000-0000-0000-000000000402"
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let admission = FakeServiceAdmission(context: serviceContext(peerID: peerID))
        admission.anyOutboundHello = hello(deviceID: "00000000-0000-0000-0000-000000000401", role: .initiator, groupID: "group")
        let router = TBLANEncryptedSessionRouter(admission: admission, coordinator: coordinator)
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  manualConnector: connector,
                                  router: router)

        _ = service.selectMode(.lanOnly)
        lanRuntime.onPeerDiscovered?(LANDiscoveredPeer(host: "peer.local", port: 40484, metadata: [
            "proto": "tomatt-sync", "v": "1", "transport": "ws", "encoding": "protobuf", "disc": "ephemeral"
        ])!)

        XCTAssertEqual(connector.endpoints.map(\.host), ["peer.local"])
        XCTAssertEqual(connector.endpoints.first?.path, LANTransportInternalPlaintext.endpointPath)
        XCTAssertEqual(connector.sessions.first?.sentEnvelopes.first?.hello.deviceID, "00000000-0000-0000-0000-000000000401")
        XCTAssertEqual(service.snapshot.statusMessage, "Resume handshake started with discovered peer.")
    }

    func testPairingCommitPersistsPeerGroupKeyRegistersEngineBindsSessionAndInitialSyncs() throws {
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let peerStore = TBInMemoryTrustedPeerStore()
        let persister = FakePairingCommitPersister(peerStore: peerStore)
        let engineMaker = FakeEngineMaker()
        let localSigner = TBDeterministicTestSigner(secret: Data("local".utf8))
        let localIdentity = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                       displayName: "Local",
                                                       platform: "macOS",
                                                       signingPublicKey: localSigner.publicKey)
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(),
                                                 coordinator: coordinator,
                                                 now: { Date(timeIntervalSince1970: 100) })
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  router: router,
                                  pairingCommitPersister: persister,
                                  localIdentity: localIdentity,
                                  engineMaker: engineMaker)
        let flowID = TBPairingRuntimeFlowID(rawValue: "flow-1")
        let session = try makeApprovedPairingSession(localIdentity: localIdentity)
        let establishment = try TBPairingSessionEstablishment(keyMaterial: .fixedTestKey(Data(repeating: 7, count: 32), keyID: "pairing-key"),
                                                              localRole: .initiator,
                                                              localNonceSeed: Data(repeating: 1, count: 32),
                                                              peerNonceSeed: Data(repeating: 2, count: 32))
        let lanSession = FakeManualSession(endpointDescription: "paired")
        service.retainPairingRuntimeFlow(TBPairingRuntimeFlow(id: flowID,
                                                              session: session,
                                                              establishment: establishment,
                                                              lanSession: lanSession))

        let result = service.commitPairingRuntimeFlow(id: flowID, now: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(result, .started("Paired Peer."))
        XCTAssertEqual(persister.persistedCommits.count, 1)
        XCTAssertEqual(persister.savedMetadata?.groupID, "group-a")
        XCTAssertEqual(persister.savedKey?.keyID, "key-a")
        XCTAssertEqual(engineMaker.sessions.map { $0.context.peerDeviceID }, ["00000000-0000-0000-0000-000000000402"])
        XCTAssertEqual(coordinator.registeredPeerIDs, ["00000000-0000-0000-0000-000000000402"])
        XCTAssertEqual(coordinator.initialSyncPeerIDs, ["00000000-0000-0000-0000-000000000402"])
        XCTAssertEqual(lanSession.sentEnvelopes.count, 1)
    }

    func testStandalonePairingBindsCommittedNewGroupIDToRouterContext() throws {
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let peerStore = TBInMemoryTrustedPeerStore()
        let persister = FakePairingCommitPersister(peerStore: peerStore)
        let engineMaker = FakeEngineMaker()
        let localSigner = TBDeterministicTestSigner(secret: Data("local".utf8))
        let localIdentity = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                       displayName: "Local",
                                                       platform: "macOS",
                                                       signingPublicKey: localSigner.publicKey)
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(), coordinator: coordinator)
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  router: router,
                                  pairingCommitPersister: persister,
                                  localIdentity: localIdentity,
                                  engineMaker: engineMaker)
        let flowID = TBPairingRuntimeFlowID(rawValue: "flow-standalone")
        let session = try makeApprovedPairingSession(localIdentity: localIdentity,
                                                     localGroupState: .standalone,
                                                     peerGroupState: .standalone,
                                                     committedGroupID: "committed-new-group")
        let establishment = try TBPairingSessionEstablishment(keyMaterial: .fixedTestKey(Data(repeating: 7, count: 32), keyID: "pairing-key"),
                                                              localRole: .initiator,
                                                              localNonceSeed: Data(repeating: 1, count: 32),
                                                              peerNonceSeed: Data(repeating: 2, count: 32))
        let lanSession = FakeManualSession(endpointDescription: "paired")
        service.retainPairingRuntimeFlow(TBPairingRuntimeFlow(id: flowID,
                                                              session: session,
                                                              establishment: establishment,
                                                              lanSession: lanSession))

        XCTAssertEqual(service.commitPairingRuntimeFlow(id: flowID, now: Date(timeIntervalSince1970: 10)), .started("Paired Peer."))

        XCTAssertEqual(router.boundContext(for: "00000000-0000-0000-0000-000000000402")?.syncGroupID, "committed-new-group")
    }

    func testDefaultPairingCommitFailsBeforePartialWritesForUnsupportedStagedData() throws {
        let peerStore = TBInMemoryTrustedPeerStore()
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let groupStore = TBInMemorySyncGroupKeyStore()
        let persister = TBDefaultPairingCommitPersister(peerStore: peerStore,
                                                        metadataStore: metadataStore,
                                                        groupKeyStore: groupStore)
        var commit = try makePairingCommit()
        commit.membershipActions = [.devicePaired(deviceID: commit.trustedPeer.deviceID, displayName: commit.trustedPeer.displayName)]

        XCTAssertThrowsError(try persister.persistPairingCommit(commit))
        XCTAssertNil(try peerStore.trustedPeer(deviceID: commit.trustedPeer.deviceID))
        XCTAssertNil(try groupStore.loadSyncGroupKey(groupID: commit.syncGroupKey.groupID))
        XCTAssertEqual(try metadataStore.loadAllSyncGroupMetadata(), [])
    }

    func testDefaultPairingCommitDoesNotLeaveTrustedPeerWhenKeyOrMetadataWriteFails() throws {
        let peerStore = TBInMemoryTrustedPeerStore()
        let keyFail = FailingSyncGroupKeyStore(failSave: true)
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let commit = try makePairingCommit()

        XCTAssertThrowsError(try TBDefaultPairingCommitPersister(peerStore: peerStore,
                                                                 metadataStore: metadataStore,
                                                                 groupKeyStore: keyFail).persistPairingCommit(commit))
        XCTAssertNil(try peerStore.trustedPeer(deviceID: commit.trustedPeer.deviceID))
        XCTAssertEqual(try metadataStore.loadAllSyncGroupMetadata(), [])

        let peerStore2 = TBInMemoryTrustedPeerStore()
        let keyStore2 = TBInMemorySyncGroupKeyStore()
        let metadataFail = FailingSyncGroupMetadataStore(failSave: true)
        XCTAssertThrowsError(try TBDefaultPairingCommitPersister(peerStore: peerStore2,
                                                                 metadataStore: metadataFail,
                                                                 groupKeyStore: keyStore2).persistPairingCommit(commit))
        XCTAssertNil(try peerStore2.trustedPeer(deviceID: commit.trustedPeer.deviceID))
        XCTAssertNil(try keyStore2.loadSyncGroupKey(groupID: commit.syncGroupKey.groupID))
        XCTAssertEqual(try metadataFail.loadAllSyncGroupMetadata(), [])

        let peerFail = FailingTrustedPeerStore(failSave: true)
        let keyStore3 = TBInMemorySyncGroupKeyStore()
        let metadataStore3 = TBInMemorySyncGroupMetadataStore()
        XCTAssertThrowsError(try TBDefaultPairingCommitPersister(peerStore: peerFail,
                                                                 metadataStore: metadataStore3,
                                                                 groupKeyStore: keyStore3).persistPairingCommit(commit))
        XCTAssertNil(try peerFail.trustedPeer(deviceID: commit.trustedPeer.deviceID))
        XCTAssertNil(try keyStore3.loadSyncGroupKey(groupID: commit.syncGroupKey.groupID))
        XCTAssertEqual(try metadataStore3.loadAllSyncGroupMetadata(), [])
    }

    func testDefaultPairingCommitRollbackFailureThrowsResetRequiredError() throws {
        let peerStore = TBInMemoryTrustedPeerStore()
        let keyStore = FailingSyncGroupKeyStore(failSave: false, failDelete: true)
        let metadataStore = FailingSyncGroupMetadataStore(failSave: true)
        let commit = try makePairingCommit()

        XCTAssertThrowsError(try TBDefaultPairingCommitPersister(peerStore: peerStore,
                                                                 metadataStore: metadataStore,
                                                                 groupKeyStore: keyStore).persistPairingCommit(commit)) { error in
            guard let persistenceError = error as? TBPairingCommitPersistenceError else {
                return XCTFail("Expected typed persistence error, got \(error)")
            }
            XCTAssertTrue(persistenceError.requiresReset)
            XCTAssertEqual(persistenceError.resetReason, "pairing commit rollback failed")
        }
        XCTAssertNil(try peerStore.trustedPeer(deviceID: commit.trustedPeer.deviceID))
    }

    func testPairingCommitRollbackFailureMarksServiceSnapshotResetRequired() throws {
        let peerStore = TBInMemoryTrustedPeerStore()
        let persister = ThrowingPairingCommitPersister(peerStore: peerStore,
                                                       error: TBPairingCommitPersistenceError.rollbackFailed(writeError: "write", rollbackErrors: ["delete key"]))
        let localSigner = TBDeterministicTestSigner(secret: Data("local".utf8))
        let localIdentity = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                       displayName: "Local",
                                                       platform: "macOS",
                                                       signingPublicKey: localSigner.publicKey)
        let service = makeService(pairingCommitPersister: persister,
                                  localIdentity: localIdentity,
                                  engineMaker: FakeEngineMaker())
        let flowID = TBPairingRuntimeFlowID(rawValue: "flow-reset")
        let session = try makeApprovedPairingSession(localIdentity: localIdentity)
        let establishment = try TBPairingSessionEstablishment(keyMaterial: .fixedTestKey(Data(repeating: 7, count: 32), keyID: "pairing-key"),
                                                              localRole: .initiator,
                                                              localNonceSeed: Data(repeating: 1, count: 32),
                                                              peerNonceSeed: Data(repeating: 2, count: 32))
        service.retainPairingRuntimeFlow(TBPairingRuntimeFlow(id: flowID,
                                                              session: session,
                                                              establishment: establishment,
                                                              lanSession: nil))

        let result = service.commitPairingRuntimeFlow(id: flowID, now: Date(timeIntervalSince1970: 10))

        guard case .blocked = result else { return XCTFail("Expected blocked result") }
        XCTAssertEqual(service.snapshot.storageHealthStatus, .lanSyncDisabledRequiresReset("pairing commit rollback failed"))
    }

    func testRemoveDeviceBlocksWhenTrustedPeerPersistenceFails() throws {
        let peerID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let peerStore = FailingTrustedPeerStore(failSave: true)
        peerStore.records[peerID.uuidString.lowercased()] = TBTrustedPeerRecord(deviceID: peerID.uuidString.lowercased(),
                                                                                 displayName: "Peer",
                                                                                 platform: "macOS",
                                                                                 signingPublicKey: Data("public".utf8))
        let persister = FakePairingCommitPersister(peerStore: peerStore)
        let coordinator = FakeServiceCoordinator(lanRuntime: FakeServiceLANRuntime())
        coordinator.peers[peerID.uuidString.lowercased()] = TBSyncRuntimePeer(deviceID: peerID.uuidString.lowercased(),
                                                                              displayName: "Peer",
                                                                              state: .offline,
                                                                              lastSeenAt: nil)
        let service = makeService(coordinator: coordinator, pairingCommitPersister: persister)

        let result = service.removeDevice(id: peerID)

        guard case .blocked(let message) = result else { return XCTFail("Expected blocked result") }
        XCTAssertTrue(message.contains("Remove Device failed"))
        XCTAssertEqual(service.snapshot.pairedDevices.map(\.id), [peerID])
        XCTAssertEqual(coordinator.removedPeerIDs, [])
    }

    func testResetClearsRuntimeRouterPairingSessionsCoordinatorAndSnapshot() throws {
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let peerID = "00000000-0000-0000-0000-000000000402"
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(context: serviceContext(peerID: peerID)), coordinator: coordinator)
        let session = FakeManualSession(endpointDescription: "bound")
        router.bind(session: session, to: peerID, direction: .outbound, establishedAt: Date())
        coordinator.peers[peerID] = TBSyncRuntimePeer(deviceID: peerID, displayName: "Peer", state: .syncing, lastSeenAt: nil)
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  router: router)

        let result = service.resetSync()

        XCTAssertEqual(result, .reset("Sync identity, trusted peers, and sync metadata were reset."))
        XCTAssertTrue(session.isClosed)
        XCTAssertTrue(coordinator.resetRuntimeStateCalled)
        XCTAssertEqual(service.snapshot.pairedDevices, [])
        router.send(messages: [encryptedFor(peerID: peerID)], to: peerID)
        XCTAssertEqual(session.sentEnvelopes.count, 0)
    }

    func testLocalSyncableEventAppendTriggersEncryptedSendToActiveSession() async throws {
        let log = try makeEventLog()
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let peerID = "00000000-0000-0000-0000-000000000402"
        let router = TBLANEncryptedSessionRouter(admission: FakeServiceAdmission(context: serviceContext(peerID: peerID)),
                                                 coordinator: coordinator,
                                                 now: { Date(timeIntervalSince1970: 100) })
        coordinator.registerEngine(FakePeerEngine(), for: peerID, displayName: "Peer")
        let session = FakeManualSession(endpointDescription: "bound")
        router.bind(session: session, to: peerID, direction: .outbound, establishedAt: Date(timeIntervalSince1970: 100))
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  router: router,
                                  eventLog: log)

        log.append(.settingChanged(TBSettingChanged(key: .pauseAfterRestFinish, value: .bool(true))))
        await Task.yield()

        XCTAssertEqual(coordinator.localAppendTriggerCount, 1)
        XCTAssertEqual(session.sentEnvelopes.count, 1)
        XCTAssertEqual(try TomattSyncProtoMapper.encryptedLANMessage(from: session.sentEnvelopes[0]).recipientDeviceID, peerID)
        XCTAssertEqual(service.snapshot.deviceName, "Test Mac")
    }

    func testLocalOnlyActiveSnapshotAppendDoesNotTriggerEncryptedSend() async throws {
        let log = try makeEventLog()
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  eventLog: log)

        log.append(.activeTimerSessionCleared(TBActiveTimerSessionCleared(clearedAt: Date(timeIntervalSince1970: 1))))
        await Task.yield()

        XCTAssertEqual(coordinator.localAppendTriggerCount, 0)
        XCTAssertEqual(service.snapshot.deviceName, "Test Mac")
    }

    func testRemoteImportStatusRefreshesTimerAndSnapshot() async {
        let lanRuntime = FakeServiceLANRuntime()
        let coordinator = FakeServiceCoordinator(lanRuntime: lanRuntime)
        let refresher = FakeTimerSyncRefresher()
        let service = makeService(lanRuntime: lanRuntime,
                                  coordinator: coordinator,
                                  health: FakeServiceHealth(pairing: .ready, lan: .ready),
                                  timerSyncRefresher: refresher)

        coordinator.remoteImportHandler?("peer", "Desk Mac")
        await Task.yield()

        XCTAssertEqual(refresher.deviceNames, ["Desk Mac"])
        XCTAssertEqual(service.snapshot.statusMessage, "Synced with Desk Mac.")
        XCTAssertNotNil(service.snapshot.lastSync)
    }

    private func makeService(lanRuntime: FakeServiceLANRuntime = FakeServiceLANRuntime(),
                              coordinator: FakeServiceCoordinator? = nil,
                              health: FakeServiceHealth = FakeServiceHealth(pairing: .ready, lan: .ready),
                              resetService: FakeResetService? = FakeResetService(),
                               manualConnector: LANWebSocketConnecting? = nil,
                               router: TBLANEncryptedSessionRouter? = nil,
                               pairingRuntime: TBPairingRuntimeCoordinator = TBPairingRuntimeCoordinator(),
                                pairingCommitPersister: TBPairingCommitPersisting? = nil,
                               localIdentity: TBSyncDevicePublicIdentity? = nil,
                               engineMaker: TBSyncPeerEngineMaking? = nil,
                               eventLog: TBLocalEventLog? = nil,
                               timerSyncRefresher: TBTimerSyncRefreshing? = nil) -> TBSyncService {
        let runtimeCoordinator = coordinator ?? FakeServiceCoordinator(lanRuntime: lanRuntime)
        return TBSyncService(dependencies: TBSyncService.Dependencies(lanRuntime: lanRuntime,
                                                                       coordinator: runtimeCoordinator,
                                                                       router: router,
                                                                       healthChecker: health,
                                                                       resetService: resetService,
                                                                       manualConnector: manualConnector,
                                                                        pairingRuntime: pairingRuntime,
                                                                        pairingCommitPersister: pairingCommitPersister,
                                                                        localIdentity: localIdentity ?? TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                                                                                                    displayName: "Test Mac",
                                                                                                                                    platform: "macOS",
                                                                                                                                    signingPublicKey: TBDeterministicTestSigner(secret: Data("default-local".utf8)).publicKey),
                                                                        engineMaker: engineMaker,
                                                                        eventLog: eventLog,
                                                                        timerSyncRefresher: timerSyncRefresher,
                                                                        capabilityGates: .currentProductizedSurface,
                                                                        deviceName: "Test Mac",
                                                                        deviceIdentity: "test-device",
                                                                        listenerPort: 40484))
    }

    private func makeEventLog() throws -> TBLocalEventLog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TBLocalEventLog(store: TBJSONLEventStore(fileURL: directory.appendingPathComponent("events.jsonl")),
                               identity: TBDeviceIdentity(deviceID: "00000000-0000-0000-0000-000000000401",
                                                          displayName: "Local",
                                                          platform: "macOS"))
    }

    private func serviceContext(peerID: String) -> TBLANEncryptedSessionContext {
        TBLANEncryptedSessionContext(peerID: peerID,
                                     displayName: "Peer",
                                     sessionKeyID: "session-key",
                                     sessionNonceSeed: Data(repeating: 1, count: 32),
                                     peerRole: .initiator,
                                     syncGroupID: "group")
    }

    private func hello(deviceID: String, role: Tomatt_Sync_V1_Hello.SessionRole, groupID: String) -> Tomatt_Sync_V1_Hello {
        var hello = Tomatt_Sync_V1_Hello()
        hello.deviceID = deviceID
        hello.displayName = "Peer"
        hello.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        hello.protocolMinor = TomattSyncProtocolV1.supportedMinorVersion
        hello.sessionKeyID = "session-key"
        hello.sessionNonceSeed = Data(repeating: 1, count: 32)
        hello.sessionRole = role
        hello.syncGroupID = groupID
        return hello
    }

    private func encryptedFor(peerID: String) -> TBEncryptedLANMessage {
        TBEncryptedLANMessage(protocolVersion: 1,
                              senderDeviceID: "00000000-0000-0000-0000-000000000401",
                              recipientDeviceID: peerID,
                              senderSigningKeyFingerprint: String(repeating: "a", count: 64),
                              direction: .initiatorToResponder,
                              counter: 1,
                              nonce: Data([1]),
                              ciphertextAndTag: Data([2]))
    }

    private func makeApprovedPairingSession(localIdentity: TBSyncDevicePublicIdentity,
                                            localGroupState: TBPairingGroupState = .standalone,
                                            peerGroupState: TBPairingGroupState = .grouped(groupID: "group-a"),
                                            committedGroupID: String = "group-a") throws -> TBPairingSession {
        let peerSigner = TBDeterministicTestSigner(secret: Data("peer".utf8))
        let peerID = "00000000-0000-0000-0000-000000000402"
        let now = Date(timeIntervalSince1970: 1)
        let localParticipant = makeParticipant(deviceID: localIdentity.deviceID,
                                               displayName: "Local",
                                               signingPublicKey: localIdentity.signingPublicKey,
                                               groupState: localGroupState)
        let peerParticipant = makeParticipant(deviceID: peerID,
                                               displayName: "Peer",
                                               signingPublicKey: peerSigner.publicKey,
                                               groupState: peerGroupState)
        let transcript = TBPairingTranscript(protocolVersion: 1,
                                             role: .addDevice,
                                             local: localParticipant,
                                             remote: peerParticipant,
                                             timestamp: now,
                                             sessionNonce: Data(repeating: 9, count: 32),
                                             capabilities: [])
        let trustedPeer = TBTrustedPeerRecord(deviceID: peerID,
                                              displayName: "Peer",
                                              platform: "macOS",
                                              signingPublicKey: peerSigner.publicKey)
        let groupKey = try TBSyncGroupKeyRecord.importExisting(groupID: committedGroupID,
                                                               keyID: "key-a",
                                                               secret: Data(repeating: 8, count: 32),
                                                               createdAt: now)
        let staged = TBPairingStagedCommit(trustedPeer: trustedPeer,
                                           syncGroupKey: groupKey,
                                           membershipActions: [],
                                           importedEvents: [],
                                           settingsSourceChoice: .keepLocal)
        let session = TBPairingSession(transcript: transcript,
                                       stagedCommit: staged,
                                       expiresAt: Date(timeIntervalSince1970: 100))
        let code = try session.start(now: now)
        try session.confirmCode(code, now: now)
        try session.approvePreview(TBPairingPreMergePreview(localDevice: TBDeviceIdentity(deviceID: localIdentity.deviceID,
                                                                                          displayName: "Local",
                                                                                          platform: "macOS"),
                                                            remoteDevice: TBDeviceIdentity(deviceID: peerID,
                                                                                           displayName: "Peer",
                                                                                           platform: "macOS"),
                                                            bothIdle: true,
                                                            settingsDiffer: false,
                                                            localPresetCount: 0,
                                                            remotePresetCount: 0,
                                                            localHistory: TBPairingHistorySummary(eventCount: 0, dateRangeStart: nil, dateRangeEnd: nil),
                                                            remoteHistory: TBPairingHistorySummary(eventCount: 0, dateRangeStart: nil, dateRangeEnd: nil),
                                                            settingsSourceChoice: .keepLocal),
                                   now: now)
        return session
    }

    private func makePairingSessionAwaitingPreview(localIdentity: TBSyncDevicePublicIdentity) throws -> TBPairingSession {
        let peerSigner = TBDeterministicTestSigner(secret: Data("peer".utf8))
        let peerID = "00000000-0000-0000-0000-000000000402"
        let now = Date(timeIntervalSince1970: 1)
        let transcript = TBPairingTranscript(protocolVersion: 1,
                                             role: .addDevice,
                                             local: makeParticipant(deviceID: localIdentity.deviceID,
                                                                    displayName: "Local",
                                                                    signingPublicKey: localIdentity.signingPublicKey,
                                                                    groupState: .standalone),
                                             remote: makeParticipant(deviceID: peerID,
                                                                     displayName: "Peer",
                                                                     signingPublicKey: peerSigner.publicKey,
                                                                     groupState: .grouped(groupID: "group-a")),
                                             timestamp: now,
                                             sessionNonce: Data(repeating: 9, count: 32),
                                             capabilities: [])
        let key = try TBSyncGroupKeyRecord.importExisting(groupID: "group-a",
                                                          keyID: "key-a",
                                                          secret: Data(repeating: 8, count: 32),
                                                          createdAt: now)
        let session = TBPairingSession(transcript: transcript,
                                       stagedCommit: TBPairingStagedCommit(trustedPeer: TBTrustedPeerRecord(deviceID: peerID,
                                                                                                             displayName: "Peer",
                                                                                                             platform: "macOS",
                                                                                                             signingPublicKey: peerSigner.publicKey),
                                                                            syncGroupKey: key,
                                                                            membershipActions: [],
                                                                            importedEvents: [],
                                                                            settingsSourceChoice: .keepLocal),
                                       expiresAt: Date(timeIntervalSince1970: 100))
        let code = try session.start(now: now)
        try session.confirmCode(code, now: now)
        return session
    }

    private func makePairingCommit() throws -> TBPairingStagedCommit {
        let peerSigner = TBDeterministicTestSigner(secret: Data("peer".utf8))
        let peer = TBTrustedPeerRecord(deviceID: "00000000-0000-0000-0000-000000000402",
                                       displayName: "Peer",
                                       platform: "macOS",
                                       signingPublicKey: peerSigner.publicKey)
        let key = try TBSyncGroupKeyRecord.importExisting(groupID: "group-a",
                                                          keyID: "key-a",
                                                          secret: Data(repeating: 8, count: 32),
                                                          createdAt: Date(timeIntervalSince1970: 1))
        return TBPairingStagedCommit(trustedPeer: peer,
                                     syncGroupKey: key,
                                     membershipActions: [],
                                     importedEvents: [],
                                     settingsSourceChoice: .keepLocal)
    }

    private func makeParticipant(deviceID: String,
                                 displayName: String,
                                 signingPublicKey: Data,
                                 groupState: TBPairingGroupState) -> TBPairingTranscriptParticipant {
        TBPairingTranscriptParticipant(deviceID: deviceID,
                                       displayName: displayName,
                                       platform: "macOS",
                                       ephemeralPairingPublicKey: Data(repeating: 1, count: 65),
                                       signingPublicKey: signingPublicKey,
                                       ephemeralDiscoveryID: deviceID,
                                       endpoint: TBPairingEndpointMetadata(host: "localhost", port: 40484, transport: "websocket", path: "/", metadata: [:]),
                                       idle: .idle(at: Date(timeIntervalSince1970: 1)),
                                       capabilities: [],
                                       groupState: groupState)
    }

    private func pairingProtoParticipant(deviceID: String,
                                         displayName: String,
                                         sessionNonce: Data,
                                         keyPair: TBPairingEphemeralKeyPair = TBPairingEphemeralKeyPair()) -> Tomatt_Sync_V1_PairingTranscriptParticipant {
        let signer = TBDeterministicTestSigner(secret: Data(deviceID.utf8))
        return Tomatt_Sync_V1_PairingTranscriptParticipant.with {
            $0.deviceID = deviceID
            $0.displayName = displayName
            $0.platform = "macOS"
            $0.syncSigningPublicKey = signer.publicKey
            $0.syncSigningKeyFingerprint = TBSyncKeyFingerprint.fingerprint(signer.publicKey)
            $0.ephemeralPairingPublicKey = keyPair.publicKey
            $0.ephemeralDiscoveryID = "test-discovery"
            $0.endpoint = Tomatt_Sync_V1_PairingEndpointMetadata.with {
                $0.host = "peer.local"
                $0.port = 40484
                $0.transport = "websocket"
                $0.path = LANTransportInternalPlaintext.endpointPath
            }
            $0.idle = Tomatt_Sync_V1_PairingIdleDeclaration.with {
                $0.isIdle = true
                $0.declaredAt.seconds = 1
            }
            $0.capabilities = ["pairing-v1"]
            $0.groupState = Tomatt_Sync_V1_PairingGroupState.with { $0.kind = .standalone }
            $0.sessionNonce = sessionNonce
            $0.transcriptProtocolVersion = UInt32(TBPairingTranscript.canonicalVersion)
        }
    }
}

private final class FakeServiceLANRuntime: TBSyncLANRuntimeControlling {
    var status: LANTransportStatus = .stopped
    var shouldReconnect = false
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)?
    var startCount = 0
    var stopCount = 0

    func start(discoveryID: LANDiscoveryID) {
        startCount += 1
        status = .active(port: 40484)
        shouldReconnect = true
    }

    func stop() {
        stopCount += 1
        status = .stopped
        shouldReconnect = false
    }

    func markDisconnected(peerID: String, direction: LANDuplicateConnectionDirection, now: Date, jitterUnit: Double) {}
}

private final class FakeServiceCoordinator: TBSyncRuntimeCoordinating {
    private let lanRuntime: FakeServiceLANRuntime
    var peers: [String: TBSyncRuntimePeer] = [:]
    var setModes: [TBSyncRuntimeMode] = []
    var registeredPeerIDs: [String] = []
    var initialSyncPeerIDs: [String] = []
    var pairingPeerIDs: [String] = []
    var removedPeerIDs: [String] = []
    var localAppendTriggerCount = 0
    var resetRuntimeStateCalled = false
    var remoteImportHandler: ((String, String) -> Void)?

    init(lanRuntime: FakeServiceLANRuntime) {
        self.lanRuntime = lanRuntime
    }

    func setMode(_ newMode: TBSyncRuntimeMode, discoveryID: LANDiscoveryID) -> Bool {
        setModes.append(newMode)
        if newMode == .off {
            lanRuntime.stop()
        } else {
            lanRuntime.start(discoveryID: discoveryID)
        }
        return true
    }

    func registerEngine(_ engine: TBSyncPeerEngine, for deviceID: String, displayName: String?) {
        registeredPeerIDs.append(deviceID)
        peers[deviceID] = TBSyncRuntimePeer(deviceID: deviceID,
                                            displayName: displayName ?? deviceID,
                                            state: .offline,
                                            lastSeenAt: nil)
    }

    func markDiscovered(deviceID: String, displayName: String, lastSeenAt: Date?) {
        peers[deviceID] = TBSyncRuntimePeer(deviceID: deviceID, displayName: displayName, state: .discovered, lastSeenAt: lastSeenAt)
    }

    func beginConnection(to deviceID: String) -> Bool {
        peers[deviceID]?.state = .connecting
        return true
    }

    func beginPairing(deviceID: String) {
        pairingPeerIDs.append(deviceID)
        peers[deviceID]?.state = .pairing
    }

    func triggerConnectionEstablishedSync(deviceID: String) -> [TBEncryptedLANMessage] {
        initialSyncPeerIDs.append(deviceID)
        return [TBEncryptedLANMessage(protocolVersion: 1,
                                      senderDeviceID: "00000000-0000-0000-0000-000000000401",
                                      recipientDeviceID: deviceID,
                                      senderSigningKeyFingerprint: String(repeating: "a", count: 64),
                                      direction: .initiatorToResponder,
                                      counter: 1,
                                      nonce: Data(repeating: 1, count: 12),
                                      ciphertextAndTag: Data(repeating: 2, count: 32))]
    }

    func triggerLocalSyncableEventAppended() -> [TBEncryptedLANMessage] {
        localAppendTriggerCount += 1
        return peers.keys.sorted().map { peerID in
            TBEncryptedLANMessage(protocolVersion: 1,
                                  senderDeviceID: "00000000-0000-0000-0000-000000000401",
                                  recipientDeviceID: peerID,
                                  senderSigningKeyFingerprint: String(repeating: "a", count: 64),
                                  direction: .initiatorToResponder,
                                  counter: UInt64(localAppendTriggerCount),
                                  nonce: Data(repeating: 1, count: 12),
                                  ciphertextAndTag: Data(repeating: 2, count: 32))
        }
    }

    func markRemoved(deviceID: String, displayName: String?) { removedPeerIDs.append(deviceID) }

    func resetRuntimeState() {
        resetRuntimeStateCalled = true
        peers.removeAll()
    }
}

private struct FakeServiceHealth: TBSyncRuntimeHealthChecking {
    var pairing: TBSyncStorageHealthStatus
    var lan: TBSyncStorageHealthStatus

    func pairingSetupHealth() -> TBSyncStorageHealth { TBSyncStorageHealth(status: pairing) }
    func lanSyncHealth() -> TBSyncStorageHealth { TBSyncStorageHealth(status: lan) }
}

private final class FakeResetService: TBSyncStorageResetting {
    var resetCount = 0
    func resetSync(preservingRawEventsAt rawEventLogURL: URL?) throws { resetCount += 1 }
}

private final class FakePairingCommitPersister: TBPairingCommitPersisting {
    let peerStoreForContext: TBTrustedPeerStoring
    private(set) var persistedCommits: [TBPairingStagedCommit] = []
    private(set) var savedMetadata: TBSyncGroupMetadataRecord?
    private(set) var savedKey: TBSyncGroupKeyRecord?
    var activeGroupState: TBPairingGroupState = .standalone

    init(peerStore: TBTrustedPeerStoring) {
        peerStoreForContext = peerStore
    }

    func persistPairingCommit(_ commit: TBPairingStagedCommit) throws {
        persistedCommits.append(commit)
        try peerStoreForContext.saveTrustedPeer(commit.trustedPeer)
        savedKey = commit.syncGroupKey
        savedMetadata = TBSyncGroupMetadataRecord(groupID: commit.syncGroupKey.groupID,
                                                  keyID: commit.syncGroupKey.keyID,
                                                  createdAt: commit.syncGroupKey.createdAt,
                                                  state: .active)
    }

    func activePairingGroupState() throws -> TBPairingGroupState { activeGroupState }
}

private final class ThrowingPairingCommitPersister: TBPairingCommitPersisting {
    let peerStoreForContext: TBTrustedPeerStoring
    let error: Error

    init(peerStore: TBTrustedPeerStoring, error: Error) {
        self.peerStoreForContext = peerStore
        self.error = error
    }

    func persistPairingCommit(_ commit: TBPairingStagedCommit) throws {
        throw error
    }
}

private final class FakeEngineMaker: TBSyncPeerEngineMaking {
    private(set) var sessions: [TBSyncSessionCryptoBox] = []

    func makeEngine(session: TBSyncSessionCryptoBox) throws -> TBSyncPeerEngine {
        sessions.append(session)
        return FakePeerEngine()
    }
}

private final class FakePeerEngine: TBSyncPeerEngine {
    func beginSync() -> TBAntiEntropySyncStepResult { TBAntiEntropySyncStepResult() }
    func notifyNewLocalEventsAvailable() -> TBAntiEntropySyncStepResult { TBAntiEntropySyncStepResult() }
    func receive(_ message: TBEncryptedLANMessage) -> TBAntiEntropySyncStepResult { TBAntiEntropySyncStepResult() }
}

private final class FakeServiceAdmission: TBLANEncryptedSessionAdmitting {
    private var contexts: [String: TBLANEncryptedSessionContext] = [:]
    var outboundHello: Tomatt_Sync_V1_Hello?
    var anyOutboundHello: Tomatt_Sync_V1_Hello?

    init(context: TBLANEncryptedSessionContext? = nil) {
        if let context {
            contexts[context.peerID] = context
        }
    }

    func admitResume(hello: Tomatt_Sync_V1_Hello) -> Result<TBLANEncryptedSessionContext, TBLANEncryptedSessionAdmissionFailure> {
        .failure(.notReady("unused"))
    }

    func sessionContext(for peerID: String) -> TBLANEncryptedSessionContext? {
        contexts[peerID]
    }

    func prepareOutboundResume(peerID: String) -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        outboundHello.map { .success($0) } ?? .failure(.notReady("no outbound hello"))
    }

    func prepareAnyOutboundResume() -> Result<Tomatt_Sync_V1_Hello, TBLANEncryptedSessionAdmissionFailure> {
        anyOutboundHello.map { .success($0) } ?? .failure(.notReady("no anonymous outbound hello"))
    }

    func retainOutboundResumeHello(_ hello: Tomatt_Sync_V1_Hello, for peerID: String) {
        contexts[peerID] = TBLANEncryptedSessionContext(peerID: peerID,
                                                        displayName: hello.displayName,
                                                        sessionKeyID: hello.sessionKeyID,
                                                        sessionNonceSeed: hello.sessionNonceSeed,
                                                        peerRole: .responder,
                                                        syncGroupID: hello.syncGroupID)
    }
}

private final class FakeManualConnector: LANWebSocketConnecting {
    var endpoints: [LANManualEndpoint] = []
    var sessions: [FakeManualSession] = []

    func connect(to endpoint: LANManualEndpoint, completion: @escaping (Result<LANWebSocketSession, Error>) -> Void) {
        endpoints.append(endpoint)
        let session = FakeManualSession(endpointDescription: "ws://\(endpoint.host):\(endpoint.port)")
        sessions.append(session)
        completion(.success(session))
    }
}

private final class FakeManualSession: LANWebSocketSession {
    let endpointDescription: String
    var onEnvelopeReceived: ((Tomatt_Sync_V1_Envelope) -> Void)?
    private(set) var sentEnvelopes: [Tomatt_Sync_V1_Envelope] = []
    private(set) var isClosed = false

    init(endpointDescription: String) {
        self.endpointDescription = endpointDescription
    }

    func send(_ envelope: Tomatt_Sync_V1_Envelope, completion: @escaping (Result<Void, Error>) -> Void) {
        sentEnvelopes.append(envelope)
        completion(.success(()))
    }

    func close() { isClosed = true }
}

private final class FailingSyncGroupKeyStore: TBSyncGroupKeyStoring {
    let failSave: Bool
    let failDelete: Bool
    init(failSave: Bool, failDelete: Bool = false) {
        self.failSave = failSave
        self.failDelete = failDelete
    }
    func loadSyncGroupKey(groupID: String) throws -> TBSyncGroupKeyRecord? { nil }
    func saveSyncGroupKey(_ record: TBSyncGroupKeyRecord) throws {
        if failSave { throw FakeServiceError.injectedFailure }
    }
    func deleteSyncGroupKey(groupID: String) throws {
        if failDelete { throw FakeServiceError.injectedFailure }
    }
}

private final class FailingSyncGroupMetadataStore: TBSyncGroupMetadataStoring {
    let failSave: Bool
    init(failSave: Bool) { self.failSave = failSave }
    func loadSyncGroupMetadata(groupID: String) throws -> TBSyncGroupMetadataRecord? { nil }
    func loadAllSyncGroupMetadata() throws -> [TBSyncGroupMetadataRecord] { [] }
    func saveSyncGroupMetadata(_ record: TBSyncGroupMetadataRecord) throws {
        if failSave { throw FakeServiceError.injectedFailure }
    }
    func deleteSyncGroupMetadata(groupID: String) throws {}
}

private final class FailingTrustedPeerStore: TBTrustedPeerStoring {
    let failSave: Bool
    var failLoad = false
    var records: [String: TBTrustedPeerRecord] = [:]
    init(failSave: Bool) { self.failSave = failSave }
    func trustedPeer(deviceID: String) throws -> TBTrustedPeerRecord? {
        if failLoad { throw FakeServiceError.injectedFailure }
        return records[deviceID]
    }
    func saveTrustedPeer(_ record: TBTrustedPeerRecord) throws {
        if failSave { throw FakeServiceError.injectedFailure }
        records[record.deviceID] = record
    }
    func deleteTrustedPeer(deviceID: String) throws { records.removeValue(forKey: deviceID) }
}

private enum FakeServiceError: Error {
    case injectedFailure
}

@MainActor
private final class FakeTimerSyncRefresher: TBTimerSyncRefreshing {
    private(set) var deviceNames: [String] = []

    func reloadFromEventLogAfterSync(trustedDeviceName: String) {
        deviceNames.append(trustedDeviceName)
    }
}

@MainActor
private final class FakeSettingsService: TBSyncServiceProviding {
    var snapshot: TBSyncServiceSnapshot = {
        var snapshot = TBSyncServiceSnapshot.preview()
        snapshot.pairedDevices = [TBPairedSyncDevice(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                                     name: "MacBook",
                                                     platform: "macOS")]
        snapshot.resetAvailable = true
        return snapshot
    }()
    var selectedModes: [TBSyncMode] = []
    var startPairDeviceCount = 0
    var pairByAddressCalls: [String] = []
    var confirmedFlowIDs: [TBPairingRuntimeFlowID] = []
    var approvedPreviewCalls: [(flowID: TBPairingRuntimeFlowID, settingsSource: TBPairingSettingsSourceChoice)] = []
    var resetCount = 0
    var removedIDs: [UUID] = []

    func selectMode(_ mode: TBSyncMode) -> TBSyncServiceActionResult {
        selectedModes.append(mode)
        return .started("selected")
    }

    func startPairDevice() -> TBSyncServiceActionResult {
        startPairDeviceCount += 1
        return .started("pair")
    }

    func pairByAddress(host: String, port: Int) -> TBSyncServiceActionResult {
        pairByAddressCalls.append("\(host):\(port)")
        return .started("manual")
    }

    func confirmVerificationCode(flowID: TBPairingRuntimeFlowID) -> TBSyncServiceActionResult {
        confirmedFlowIDs.append(flowID)
        return .started("confirmed")
    }

    func approvePreview(flowID: TBPairingRuntimeFlowID, settingsSource: TBPairingSettingsSourceChoice) -> TBSyncServiceActionResult {
        approvedPreviewCalls.append((flowID, settingsSource))
        return .started("approved")
    }

    func resetSync() -> TBSyncServiceActionResult {
        resetCount += 1
        return .reset("reset")
    }

    func removeDevice(id: UUID) -> TBSyncServiceActionResult {
        removedIDs.append(id)
        return .started("removed")
    }
}

import CryptoKit
import XCTest

final class SyncSecurityTests: XCTestCase {
    func testDisplayIdentityAndCryptographicIdentityAreSeparate() {
        let display = TBDeviceIdentity(deviceID: "device-a", displayName: "Kitchen Mac", platform: "macOS")
        let crypto = TBSyncDevicePublicIdentity(deviceID: display.deviceID,
                                                displayName: display.displayName,
                                                platform: display.platform,
                                                signingPublicKey: Data("public-a".utf8))

        XCTAssertEqual(display.deviceID, crypto.deviceID)
        XCTAssertEqual(display.displayName, crypto.displayName)
        XCTAssertNotEqual(Data(display.displayName.utf8), crypto.signingPublicKey)
        XCTAssertEqual(crypto.signingKeyFingerprint, TBSyncKeyFingerprint.fingerprint(Data("public-a".utf8)))
    }

    func testKeyFingerprintDeterminism() {
        let key = Data([0, 1, 2, 3, 254, 255])
        XCTAssertEqual(TBSyncKeyFingerprint.fingerprint(key), TBSyncKeyFingerprint.fingerprint(key))
        XCTAssertEqual(TBSyncKeyFingerprint.fingerprint(key).count, 64)
    }

    func testSyncGroupKeyLifecycleCreateImportAndStore() throws {
        let store = TBInMemorySyncGroupKeyStore()
        let created = TBSyncGroupKeyRecord.createNew(groupID: "group-a",
                                                     keyID: "key-a",
                                                     createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(created.secret.count, 32)
        XCTAssertEqual(created.state, .active)
        try store.saveSyncGroupKey(created)

        let importedSecret = Data(repeating: 7, count: 32)
        let imported = try TBSyncGroupKeyRecord.importExisting(groupID: "group-b",
                                                              keyID: "key-b",
                                                              secret: importedSecret,
                                                              createdAt: Date(timeIntervalSince1970: 2))
        try store.saveSyncGroupKey(imported)

        XCTAssertEqual(try store.loadSyncGroupKey(groupID: "group-a"), created)
        XCTAssertEqual(try store.loadSyncGroupKey(groupID: "group-b")?.state, .imported)
        XCTAssertThrowsError(try TBSyncGroupKeyRecord.importExisting(groupID: "bad",
                                                                     keyID: "bad",
                                                                      secret: Data([1])))
    }

    func testFileTrustedPeerAndGroupMetadataStoresPersistPublicDataOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let peerStore = TBFileTrustedPeerStore(fileURL: directory.appendingPathComponent("trusted-peers.json"))
        let metadataStore = TBFileSyncGroupMetadataStore(fileURL: directory.appendingPathComponent("group-metadata.json"))
        let peer = TBTrustedPeerRecord(deviceID: "peer-a",
                                       displayName: "Peer A",
                                       platform: "macOS",
                                       signingPublicKey: Data("public".utf8),
                                       lastSeenAt: Date(timeIntervalSince1970: 5))
        let metadata = TBSyncGroupMetadataRecord(groupID: "group-a",
                                                 keyID: "key-a",
                                                 createdAt: Date(timeIntervalSince1970: 6),
                                                 state: .active)

        try peerStore.saveTrustedPeer(peer)
        try metadataStore.saveSyncGroupMetadata(metadata)

        XCTAssertEqual(try TBFileTrustedPeerStore(fileURL: directory.appendingPathComponent("trusted-peers.json"))
            .trustedPeer(deviceID: "peer-a"), peer)
        let reloadedMetadataStore = TBFileSyncGroupMetadataStore(fileURL: directory.appendingPathComponent("group-metadata.json"))
        XCTAssertEqual(try reloadedMetadataStore.loadSyncGroupMetadata(groupID: "group-a"), metadata)
        XCTAssertEqual(try reloadedMetadataStore.loadAllSyncGroupMetadata(), [metadata])
        XCTAssertEqual(try reloadedMetadataStore.loadActiveSyncGroupMetadata(), [metadata])
        let combined = try String(contentsOf: directory.appendingPathComponent("trusted-peers.json"))
            + String(contentsOf: directory.appendingPathComponent("group-metadata.json"))
        XCTAssertFalse(combined.contains("super-secret"))
    }

    func testInMemorySyncGroupMetadataStoreLoadsAllAndActiveRecords() throws {
        let store = TBInMemorySyncGroupMetadataStore()
        let active = TBSyncGroupMetadataRecord(groupID: "group-a",
                                               keyID: "key-a",
                                               createdAt: Date(timeIntervalSince1970: 1),
                                               state: .active)
        let retired = TBSyncGroupMetadataRecord(groupID: "group-b",
                                                keyID: "key-b",
                                                createdAt: Date(timeIntervalSince1970: 2),
                                                state: .retired)

        try store.saveSyncGroupMetadata(retired)
        try store.saveSyncGroupMetadata(active)

        XCTAssertEqual(try store.loadAllSyncGroupMetadata().map(\.groupID), ["group-a", "group-b"])
        XCTAssertEqual(try store.loadActiveSyncGroupMetadata(), [active])
    }

    func testSignedSyncEventStorePersistsExportsAndQueriesByOriginSequence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TBJSONLSignedSyncEventStore(fileURL: directory.appendingPathComponent("signed-events.jsonl"))
        let signer = TBDeterministicTestSigner(secret: Data("secret-a".utf8))
        let event1 = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "peer-a", sequence: 1),
                                                signerDeviceID: "peer-a",
                                                signer: signer)
        let event2 = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "peer-a", sequence: 2),
                                                signerDeviceID: "peer-a",
                                                signer: signer)
        let other = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "peer-b", sequence: 1),
                                               signerDeviceID: "peer-b",
                                               signer: signer)

        try store.saveSignedSyncEvent(event2)
        try store.saveSignedSyncEvent(event1)
        try store.saveSignedSyncEvent(event1)
        try store.saveSignedSyncEvent(other)

        XCTAssertTrue(try store.hasSignedMetadata(for: event1.envelope))
        XCTAssertFalse(try store.hasSignedMetadata(for: makeEnvelope(deviceID: "peer-a", sequence: 9)))
        XCTAssertEqual(try store.signedSyncEvent(eventID: event2.envelope.eventID), event2)
        XCTAssertEqual(try store.signedSyncEvent(originDeviceID: "peer-a", deviceSequence: 1), event1)
        XCTAssertEqual(try store.signedSyncEvents(originDeviceID: "peer-a", sequenceRange: 1...2).map { $0.envelope.deviceSequence }, [1, 2])
        XCTAssertEqual(try store.exportSignedSyncEvents().count, 3)
    }

    func testResetSyncClearsMetadataAndSignedSidecarButPreservesRawEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawEventURL = directory.appendingPathComponent("events.jsonl")
        let rawStore = TBJSONLEventStore(fileURL: rawEventURL)
        let envelope = makeEnvelope(deviceID: "local-a", sequence: 1)
        try rawStore.append(envelope)
        let signingStore = TBInMemoryDeviceSigningKeyStore()
        try signingStore.saveSigningPrivateKey(Curve25519.Signing.PrivateKey().rawRepresentation)
        let groupStore = TBInMemorySyncGroupKeyStore()
        try groupStore.saveSyncGroupKey(TBSyncGroupKeyRecord.createNew(groupID: "group-a"))
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a",
                                                                          keyID: "key-a",
                                                                          createdAt: Date(timeIntervalSince1970: 1),
                                                                          state: .active))
        let peerStore = TBFileTrustedPeerStore(fileURL: directory.appendingPathComponent("trusted-peers.json"))
        try peerStore.saveTrustedPeer(TBTrustedPeerRecord(deviceID: "peer-a",
                                                          displayName: "Peer A",
                                                          platform: nil,
                                                          signingPublicKey: Data("public".utf8)))
        let signedStore = TBJSONLSignedSyncEventStore(fileURL: directory.appendingPathComponent("signed-events.jsonl"))
        let signer = TBDeterministicTestSigner(secret: Data("secret-a".utf8))
        try signedStore.saveSignedSyncEvent(TBSignedSyncEvent.sign(envelope: envelope,
                                                                   signerDeviceID: "local-a",
                                                                   signer: signer))

        try TBSyncStorageResetService(stores: [signingStore, groupStore, metadataStore, peerStore, signedStore])
            .resetSync(preservingRawEventsAt: rawEventURL)

        XCTAssertNil(try signingStore.loadSigningPrivateKey())
        XCTAssertNil(try groupStore.loadSyncGroupKey(groupID: "group-a"))
        XCTAssertEqual(try metadataStore.loadAllSyncGroupMetadata(), [])
        XCTAssertNil(try peerStore.trustedPeer(deviceID: "peer-a"))
        XCTAssertEqual(try signedStore.exportSignedSyncEvents(), [])
        XCTAssertEqual(try rawStore.load(), [envelope])
    }

    func testResetSyncPropagatesStoreFailureAndFileStoresIgnoreMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingPeerStore = TBFileTrustedPeerStore(fileURL: directory.appendingPathComponent("missing-peers.json"))
        let missingMetadataStore = TBFileSyncGroupMetadataStore(fileURL: directory.appendingPathComponent("missing-metadata.json"))
        let missingSignedStore = TBJSONLSignedSyncEventStore(fileURL: directory.appendingPathComponent("missing-signed.jsonl"))

        XCTAssertNoThrow(try missingPeerStore.resetSyncStorage())
        XCTAssertNoThrow(try missingMetadataStore.resetSyncStorage())
        XCTAssertNoThrow(try missingSignedStore.resetSyncStorage())
        XCTAssertThrowsError(try TBSyncStorageResetService(stores: [ThrowingResettableStore()]).resetSync()) { error in
            XCTAssertEqual(error as? TBSyncSecurityError, .signedMetadataPersistenceFailed)
        }
    }

    func testKeychainGroupKeyResetStoreDeletesSpecificGroupSecret() throws {
        final class SpyGroupKeyStore: TBAppleKeychainSyncGroupKeyStore {
            var deletedGroupIDs: [String] = []

            override func deleteSyncGroupKey(groupID: String) throws {
                deletedGroupIDs.append(groupID)
            }
        }

        let spy = SpyGroupKeyStore(service: "test")
        try TBAppleKeychainSyncGroupKeyResetStore(keyStore: spy, groupID: "group-a").resetSyncStorage()

        XCTAssertEqual(spy.deletedGroupIDs, ["group-a"])
    }

    func testFreshDeviceSigningKeyResetRecreatesValidIdentityForPairingSetup() throws {
        let signingStore = TBInMemoryDeviceSigningKeyStore()
        try signingStore.saveSigningPrivateKey(Curve25519.Signing.PrivateKey().rawRepresentation)
        let groupStore = TBInMemorySyncGroupKeyStore()
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let health = TBSyncStorageHealthService(signingKeyStore: signingStore,
                                                groupKeyStore: groupStore,
                                                metadataStore: metadataStore)

        try TBFreshDeviceSigningKeyResetStore(resettableStore: signingStore,
                                             signingStore: signingStore).resetSyncStorage()

        XCTAssertEqual(health.pairingSetupHealth().status, .ready)
        XCTAssertNotNil(try signingStore.loadSigningPrivateKey())
        XCTAssertEqual(health.lanSyncHealth().status, .lanSyncDisabledRequiresPairing("missing active sync group"))
    }

    func testMetadataBackedGroupKeyResetDeletesEveryMetadataGroupSecret() throws {
        final class SpyGroupKeyStore: TBAppleKeychainSyncGroupKeyStore {
            var deletedGroupIDs: [String] = []

            override func deleteSyncGroupKey(groupID: String) throws {
                deletedGroupIDs.append(groupID)
            }
        }
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a", keyID: "key-a", createdAt: Date(), state: .active))
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-b", keyID: "key-b", createdAt: Date(), state: .retired))
        let spy = SpyGroupKeyStore(service: "test")

        try TBMetadataBackedSyncGroupKeyResetStore(keyStore: spy, metadataStore: metadataStore).resetSyncStorage()

        XCTAssertEqual(spy.deletedGroupIDs, ["group-a", "group-b"])
    }

    func testStorageHealthReportsReadyMissingAndCorruptKeyStates() throws {
        let signingStore = TBInMemoryDeviceSigningKeyStore()
        let groupStore = TBInMemorySyncGroupKeyStore()
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let service = TBSyncStorageHealthService(signingKeyStore: signingStore,
                                                  groupKeyStore: groupStore,
                                                  metadataStore: metadataStore)

        XCTAssertEqual(service.health().status, .lanSyncDisabledRequiresPairing("missing device signing key"))
        try signingStore.saveSigningPrivateKey(Data("not-a-real-key".utf8))
        XCTAssertEqual(service.health().status, .lanSyncDisabledRequiresReset("corrupt device signing key"))
        try signingStore.saveSigningPrivateKey(Curve25519.Signing.PrivateKey().rawRepresentation)
        XCTAssertEqual(service.pairingSetupHealth().status, .ready)
        XCTAssertEqual(service.lanSyncHealth().status, .lanSyncDisabledRequiresPairing("missing active sync group"))
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a",
                                                                          keyID: "key-a",
                                                                          createdAt: Date(timeIntervalSince1970: 1),
                                                                          state: .active))
        XCTAssertEqual(service.lanSyncHealth().status, .lanSyncDisabledRequiresPairing("missing sync group key"))
        try groupStore.saveSyncGroupKey(TBSyncGroupKeyRecord.createNew(groupID: "group-a"))
        XCTAssertEqual(service.lanSyncHealth().status, .lanSyncDisabledRequiresPairing("unusable sync group key"))
        try groupStore.saveSyncGroupKey(TBSyncGroupKeyRecord.createNew(groupID: "group-a", keyID: "key-a"))
        XCTAssertEqual(service.health().status, .ready)
        XCTAssertTrue(service.health().isLANSyncEnabled)
    }

    func testStorageHealthBlocksRetiredKeyAcceptsImportedKeyAndRequiresResetForMultipleActiveGroups() throws {
        let signingStore = TBInMemoryDeviceSigningKeyStore()
        try signingStore.saveSigningPrivateKey(Curve25519.Signing.PrivateKey().rawRepresentation)
        let groupStore = TBInMemorySyncGroupKeyStore()
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let service = TBSyncStorageHealthService(signingKeyStore: signingStore,
                                                 groupKeyStore: groupStore,
                                                 metadataStore: metadataStore)
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a",
                                                                          keyID: "key-a",
                                                                          createdAt: Date(timeIntervalSince1970: 1),
                                                                          state: .active))
        var retired = TBSyncGroupKeyRecord.createNew(groupID: "group-a", keyID: "key-a")
        retired.state = .retired
        try groupStore.saveSyncGroupKey(retired)
        XCTAssertEqual(service.lanSyncHealth().status, .lanSyncDisabledRequiresPairing("unusable sync group key"))

        let imported = try TBSyncGroupKeyRecord.importExisting(groupID: "group-a",
                                                              keyID: "key-a",
                                                              secret: Data(repeating: 7, count: 32))
        try groupStore.saveSyncGroupKey(imported)
        XCTAssertEqual(service.lanSyncHealth().status, .ready)

        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-b",
                                                                          keyID: "key-b",
                                                                          createdAt: Date(timeIntervalSince1970: 2),
                                                                          state: .active))
        XCTAssertEqual(service.lanSyncHealth().status, .lanSyncDisabledRequiresReset("multiple active sync groups"))
    }

    func testCanonicalSignedBytesDeterministicVector() throws {
        let event = makeEnvelope(deviceID: "peer-a", sequence: 1)
        let bytes = try TBSyncCanonicalEventBytes.encode(event)
        let string = String(decoding: bytes, as: UTF8.self)

        XCTAssertEqual(string, try String(decoding: TBSyncCanonicalEventBytes.encode(event), as: UTF8.self))
        XCTAssertEqual(string, "{\"canonicalVersion\":1,\"creatorDeviceID\":\"peer-a\",\"deviceSequence\":1,\"domainPayloadSHA256\":\"a4497e2e164a637eaf2e7b4196b611589496f36e8274c78a2b48b843bdc0a6e4\",\"eventID\":\"76a978fb-ef0a-5182-b200-065c6c93ec19\",\"eventType\":\"settingChanged\",\"recordedAt\":\"2023-11-14T22:13:20.000Z\",\"schemaVersion\":2}")
    }

    func testValidSignatureAccepted() throws {
        let fixture = try makeTrustedImportFixture()
        let outcome = try fixture.importer.importSignedEvents([fixture.signedEvent], context: fixture.context)

        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(fixture.sink.importCallCount, 1)
    }

    func testTamperedEventSignatureAndWrongKeyRejected() throws {
        let fixture = try makeTrustedImportFixture()

        var tamperedEvent = fixture.signedEvent
        tamperedEvent.envelope = makeEnvelope(deviceID: "peer-a", sequence: 2)
        XCTAssertThrowsError(try fixture.importer.importSignedEvents([tamperedEvent], context: fixture.context))

        var tamperedSignature = fixture.signedEvent
        tamperedSignature.signature = Data("bad".utf8)
        XCTAssertThrowsError(try fixture.importer.importSignedEvents([tamperedSignature], context: fixture.context))

        var wrongKey = fixture.signedEvent
        wrongKey.signingPublicKey = Data("wrong".utf8)
        XCTAssertThrowsError(try fixture.importer.importSignedEvents([wrongKey], context: fixture.context))
        XCTAssertEqual(fixture.sink.importCallCount, 0)
    }

    func testUntrustedPeerRejected() throws {
        let fixture = try makeTrustedImportFixture(trustedPeer: nil)

        XCTAssertThrowsError(try fixture.importer.importSignedEvents([fixture.signedEvent], context: fixture.context))
        XCTAssertEqual(fixture.sink.importCallCount, 0)
    }

    func testRemovedPeerRejected() throws {
        let fixture = try makeTrustedImportFixture(isRemoved: true)

        XCTAssertThrowsError(try fixture.importer.importSignedEvents([fixture.signedEvent], context: fixture.context))
        XCTAssertEqual(fixture.sink.importCallCount, 0)
    }

    func testRawImportNotCalledOnStructuralVerificationFailure() throws {
        let fixture = try makeTrustedImportFixture()
        var invalid = fixture.signedEvent
        invalid.envelope.eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        invalid.signature = try fixture.signer.sign(TBSyncCanonicalEventBytes.encode(invalid.envelope))

        XCTAssertThrowsError(try fixture.importer.importSignedEvents([invalid], context: fixture.context))
        XCTAssertEqual(fixture.sink.importCallCount, 0)
    }

    func testRelayedOriginalSignerEventAcceptedAndMetadataPersisted() throws {
        let originSigner = TBDeterministicTestSigner(secret: Data("origin-a".utf8))
        let transportSigner = TBDeterministicTestSigner(secret: Data("transport-b".utf8))
        let originEvent = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "origin-a", sequence: 1),
                                                     signerDeviceID: "origin-a",
                                                     signer: originSigner)
        let peerStore = TBInMemoryTrustedPeerStore(records: [
            TBTrustedPeerRecord(deviceID: "origin-a", displayName: "Origin", platform: nil, signingPublicKey: originSigner.publicKey),
            TBTrustedPeerRecord(deviceID: "transport-b", displayName: "Transport", platform: nil, signingPublicKey: transportSigner.publicKey),
        ])
        let sink = FakeImportSink()
        let signedStore = FakeSignedEventStore()
        let importer = TBSignedSyncEventTrustedImporter(peerStore: peerStore,
                                                        verifier: originSigner,
                                                        sink: sink,
                                                        signedEventStore: signedStore)
        let context = TBAuthenticatedSyncContext(peerDeviceID: "transport-b",
                                                 peerSigningKeyFingerprint: TBSyncKeyFingerprint.fingerprint(transportSigner.publicKey),
                                                 authenticatedAt: Date(timeIntervalSince1970: 1))

        let outcome = try importer.importSignedEvents([originEvent], context: context)

        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(sink.importCallCount, 1)
        XCTAssertEqual(signedStore.saved, [originEvent])
    }

    func testRelayedEventRejectedWhenOriginalSignerUnknown() throws {
        let originSigner = TBDeterministicTestSigner(secret: Data("origin-a".utf8))
        let transportSigner = TBDeterministicTestSigner(secret: Data("transport-b".utf8))
        let originEvent = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "origin-a", sequence: 1),
                                                     signerDeviceID: "origin-a",
                                                     signer: originSigner)
        let peerStore = TBInMemoryTrustedPeerStore(records: [
            TBTrustedPeerRecord(deviceID: "transport-b", displayName: "Transport", platform: nil, signingPublicKey: transportSigner.publicKey),
        ])
        let sink = FakeImportSink()
        let importer = TBSignedSyncEventTrustedImporter(peerStore: peerStore, verifier: originSigner, sink: sink)
        let context = TBAuthenticatedSyncContext(peerDeviceID: "transport-b",
                                                 peerSigningKeyFingerprint: TBSyncKeyFingerprint.fingerprint(transportSigner.publicKey))

        XCTAssertThrowsError(try importer.importSignedEvents([originEvent], context: context)) { error in
            XCTAssertEqual(error as? TBSyncSecurityError, .untrustedPeer("origin-a"))
        }
        XCTAssertEqual(sink.importCallCount, 0)
    }

    func testTransportPeerTrustStillRequiredForRelayedEvents() throws {
        let originSigner = TBDeterministicTestSigner(secret: Data("origin-a".utf8))
        let transportSigner = TBDeterministicTestSigner(secret: Data("transport-b".utf8))
        let originEvent = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "origin-a", sequence: 1),
                                                     signerDeviceID: "origin-a",
                                                     signer: originSigner)
        let peerStore = TBInMemoryTrustedPeerStore(records: [
            TBTrustedPeerRecord(deviceID: "origin-a", displayName: "Origin", platform: nil, signingPublicKey: originSigner.publicKey),
        ])
        let sink = FakeImportSink()
        let importer = TBSignedSyncEventTrustedImporter(peerStore: peerStore, verifier: originSigner, sink: sink)
        let context = TBAuthenticatedSyncContext(peerDeviceID: "transport-b",
                                                 peerSigningKeyFingerprint: TBSyncKeyFingerprint.fingerprint(transportSigner.publicKey))

        XCTAssertThrowsError(try importer.importSignedEvents([originEvent], context: context)) { error in
            XCTAssertEqual(error as? TBSyncSecurityError, .untrustedPeer("transport-b"))
        }
        XCTAssertEqual(sink.importCallCount, 0)
    }

    func testMembershipIntervalAcceptsPreRemovalAndRejectsPostRemoval() throws {
        let fixture = try makeTrustedImportFixture(membershipValidator: TBSequenceCutoffMembershipValidator(activeThroughSequenceByDeviceID: ["peer-a": 1]))
        let preRemoval = fixture.signedEvent
        let postRemoval = try TBSignedSyncEvent.sign(envelope: makeEnvelope(deviceID: "peer-a", sequence: 2),
                                                     signerDeviceID: "peer-a",
                                                     signer: fixture.signer)

        XCTAssertNoThrow(try fixture.importer.importSignedEvents([preRemoval], context: fixture.context))
        XCTAssertThrowsError(try fixture.importer.importSignedEvents([postRemoval], context: fixture.context)) { error in
            XCTAssertEqual(error as? TBSyncSecurityError, .eventOutsideMembershipInterval("peer-a"))
        }
    }

    func testSignerMismatchRejectedForRelayedEvent() throws {
        let fixture = try makeTrustedImportFixture()
        var mismatched = fixture.signedEvent
        mismatched.signerDeviceID = "other-device"

        XCTAssertThrowsError(try fixture.importer.importSignedEvents([mismatched], context: fixture.context)) { error in
            XCTAssertEqual(error as? TBSyncSecurityError, .signerMismatch)
        }
        XCTAssertEqual(fixture.sink.importCallCount, 0)
    }

    func testSignedMetadataPersistenceFailurePreventsRawImport() throws {
        let signedStore = FakeSignedEventStore()
        signedStore.failure = TBSyncSecurityError.signedMetadataPersistenceFailed
        let fixture = try makeTrustedImportFixture(signedEventStore: signedStore)

        XCTAssertThrowsError(try fixture.importer.importSignedEvents([fixture.signedEvent], context: fixture.context)) { error in
            XCTAssertEqual(error as? TBSyncSecurityError, .signedMetadataPersistenceFailed)
        }
        XCTAssertEqual(fixture.sink.importCallCount, 0)
    }

    private func makeTrustedImportFixture(trustedPeer: TBTrustedPeerRecord? = TBTrustedPeerRecord(deviceID: "peer-a",
                                                                                                   displayName: "Peer A",
                                                                                                   platform: "macOS",
                                                                                                   signingPublicKey: TBDeterministicTestSigner(secret: Data("secret-a".utf8)).publicKey),
                                          isRemoved: Bool = false,
                                          signedEventStore: TBSignedSyncEventStoring? = nil,
                                          membershipValidator: TBSyncMembershipValidating = TBTrustedPeerMembershipValidator()) throws -> Fixture {
        let signer = TBDeterministicTestSigner(secret: Data("secret-a".utf8))
        let envelope = makeEnvelope(deviceID: "peer-a", sequence: 1)
        let signed = try TBSignedSyncEvent.sign(envelope: envelope, signerDeviceID: "peer-a", signer: signer)
        let peerStore = TBInMemoryTrustedPeerStore()
        if var trustedPeer = trustedPeer {
            trustedPeer.isRemoved = isRemoved
            try peerStore.saveTrustedPeer(trustedPeer)
        }
        let sink = FakeImportSink()
        let importer = TBSignedSyncEventTrustedImporter(peerStore: peerStore,
                                                        verifier: signer,
                                                        sink: sink,
                                                        signedEventStore: signedEventStore,
                                                        membershipValidator: membershipValidator)
        let context = TBAuthenticatedSyncContext(peerDeviceID: "peer-a",
                                                 peerSigningKeyFingerprint: TBSyncKeyFingerprint.fingerprint(signer.publicKey),
                                                 authenticatedAt: Date(timeIntervalSince1970: 1))
        return Fixture(signer: signer, signedEvent: signed, importer: importer, context: context, sink: sink)
    }

    private func makeEnvelope(deviceID: String, sequence: Int64) -> TBEventEnvelope {
        TBEventEnvelope(eventID: TBSyncEventID.derive(originDeviceID: deviceID, deviceSequence: sequence),
                        streamID: "sync",
                        sequence: sequence,
                        originDeviceID: deviceID,
                        deviceSequence: sequence,
                        recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        event: .settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(25))))
    }

    private struct Fixture {
        let signer: TBDeterministicTestSigner
        let signedEvent: TBSignedSyncEvent
        let importer: TBSignedSyncEventTrustedImporter
        let context: TBAuthenticatedSyncContext
        let sink: FakeImportSink
    }

    private final class FakeImportSink: TBSignedSyncEventImportSink {
        private(set) var importCallCount = 0

        func importAlreadyVerifiedEvents(_ events: [TBEventEnvelope]) -> TBSyncImportOutcome {
            importCallCount += 1
            var result = TBImportResult()
            result.imported = events.count
            return TBSyncImportOutcome(result: result)
        }
    }

    private final class FakeSignedEventStore: TBSignedSyncEventStoring {
        var saved: [TBSignedSyncEvent] = []
        var failure: Error?

        func saveSignedSyncEvent(_ event: TBSignedSyncEvent) throws {
            if let failure { throw failure }
            saved.append(event)
        }

        func signedSyncEvent(eventID: UUID) throws -> TBSignedSyncEvent? {
            saved.first { $0.envelope.eventID == eventID }
        }

        func signedSyncEvent(originDeviceID: String, deviceSequence: Int64) throws -> TBSignedSyncEvent? {
            saved.first { $0.envelope.originDeviceID == originDeviceID && $0.envelope.deviceSequence == deviceSequence }
        }

        func signedSyncEvents(originDeviceID: String, sequenceRange: ClosedRange<Int64>) throws -> [TBSignedSyncEvent] {
            saved.filter { event in
                event.envelope.originDeviceID == originDeviceID
                    && event.envelope.deviceSequence.map { sequenceRange.contains($0) } == true
            }
        }

        func hasSignedMetadata(for envelope: TBEventEnvelope) throws -> Bool {
            try signedSyncEvent(eventID: envelope.eventID) != nil
        }

        func exportSignedSyncEvents() throws -> [TBSignedSyncEvent] { saved }
    }

    private struct ThrowingResettableStore: TBSyncResettableStore {
        func resetSyncStorage() throws { throw TBSyncSecurityError.signedMetadataPersistenceFailed }
    }
}

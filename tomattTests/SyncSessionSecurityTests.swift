import XCTest

final class SyncSessionSecurityTests: XCTestCase {
    func testAuthenticatedEncryptionRequiredBeforeSyncEventExchange() throws {
        let fixture = try makeFixture()
        let gate = TBAuthenticatedLANSyncGate(session: nil, importer: fixture.responderImporter)

        XCTAssertThrowsError(try gate.sealSignedEventBatch([fixture.signedEvent], messageID: "msg-1")) { error in
            XCTAssertEqual(error as? TBSyncSessionError, .unauthenticatedSession)
        }
    }

    func testSealOpenSucceedsWithMatchingPeersAndSession() throws {
        let fixture = try makeFixture()
        let envelope = LANControlEnvelopeFactory.ping(messageID: "ping-1", nonce: "nonce-1")

        let encrypted = try fixture.initiatorSession.seal(envelope: envelope)
        let opened = try fixture.responderSession.open(encrypted)

        XCTAssertEqual(opened.messageID, "ping-1")
        XCTAssertEqual(opened.ping.nonce, "nonce-1")
    }

    func testPairingDerivedSessionMaterialMatchesAndSealsOpens() throws {
        let initiatorID = "00000000-0000-0000-0000-000000000101"
        let responderID = "00000000-0000-0000-0000-000000000102"
        let initiatorSigner = TBDeterministicTestSigner(secret: Data("initiator".utf8))
        let responderSigner = TBDeterministicTestSigner(secret: Data("responder".utf8))
        let initiatorKeyPair = try TBPairingEphemeralKeyPair(rawPrivateKeyRepresentation: Data(repeating: 1, count: 32))
        let responderKeyPair = try TBPairingEphemeralKeyPair(rawPrivateKeyRepresentation: Data(repeating: 2, count: 32))
        let initiatorTranscript = makePairingTranscript(localDeviceID: initiatorID,
                                                        remoteDeviceID: responderID,
                                                        role: .addDevice,
                                                        localEphemeralPublicKey: initiatorKeyPair.publicKey,
                                                        remoteEphemeralPublicKey: responderKeyPair.publicKey,
                                                        localSigningPublicKey: initiatorSigner.publicKey,
                                                        remoteSigningPublicKey: responderSigner.publicKey)
        let responderTranscript = makePairingTranscript(localDeviceID: responderID,
                                                        remoteDeviceID: initiatorID,
                                                        role: .joinSyncGroup,
                                                        localEphemeralPublicKey: responderKeyPair.publicKey,
                                                        remoteEphemeralPublicKey: initiatorKeyPair.publicKey,
                                                        localSigningPublicKey: responderSigner.publicKey,
                                                        remoteSigningPublicKey: initiatorSigner.publicKey)

        XCTAssertEqual(try initiatorTranscript.verificationCode(), try responderTranscript.verificationCode())
        let initiatorEstablishment = try initiatorKeyPair.deriveSessionEstablishment(localTranscript: initiatorTranscript)
        let responderEstablishment = try responderKeyPair.deriveSessionEstablishment(localTranscript: responderTranscript)
        XCTAssertEqual(initiatorEstablishment.keyMaterial.keyID, responderEstablishment.keyMaterial.keyID)
        XCTAssertEqual(initiatorEstablishment.localNonceSeed, responderEstablishment.peerNonceSeed)
        XCTAssertEqual(initiatorEstablishment.peerNonceSeed, responderEstablishment.localNonceSeed)

        let initiatorContext = try makeAuthenticatedContext(localID: initiatorID,
                                                            localName: "Initiator",
                                                            localSigner: initiatorSigner,
                                                            peerID: responderID,
                                                            peerName: "Responder",
                                                            peerSigner: responderSigner)
        let responderContext = try makeAuthenticatedContext(localID: responderID,
                                                            localName: "Responder",
                                                            localSigner: responderSigner,
                                                            peerID: initiatorID,
                                                            peerName: "Initiator",
                                                            peerSigner: initiatorSigner)
        let initiatorSession = initiatorEstablishment.makeCryptoBox(context: initiatorContext)
        let responderSession = responderEstablishment.makeCryptoBox(context: responderContext)
        let encrypted = try initiatorSession.seal(envelope: LANControlEnvelopeFactory.ping(messageID: "paired", nonce: "nonce"))
        let opened = try responderSession.open(encrypted)

        XCTAssertEqual(opened.messageID, "paired")
        XCTAssertEqual(opened.ping.nonce, "nonce")
    }

    func testTamperedCiphertextOrTagRejected() throws {
        let fixture = try makeFixture()
        var encrypted = try fixture.initiatorSession.seal(envelope: LANControlEnvelopeFactory.ping(messageID: "p", nonce: "n"))
        encrypted = TBEncryptedLANMessage(protocolVersion: encrypted.protocolVersion,
                                          senderDeviceID: encrypted.senderDeviceID,
                                          recipientDeviceID: encrypted.recipientDeviceID,
                                          senderSigningKeyFingerprint: encrypted.senderSigningKeyFingerprint,
                                          direction: encrypted.direction,
                                          counter: encrypted.counter,
                                          nonce: encrypted.nonce,
                                          ciphertextAndTag: encrypted.ciphertextAndTag.flippingLastByte())

        XCTAssertThrowsError(try fixture.responderSession.open(encrypted)) { error in
            XCTAssertEqual(error as? TBSyncSessionError, .tamperedOrUnauthentic)
        }
    }

    func testReplayAndLowerCounterRejected() throws {
        let fixture = try makeFixture()
        let first = try fixture.initiatorSession.seal(envelope: LANControlEnvelopeFactory.ping(messageID: "p1", nonce: "n1"))
        _ = try fixture.responderSession.open(first)

        XCTAssertThrowsError(try fixture.responderSession.open(first)) { error in
            XCTAssertEqual(error as? TBSyncSessionError, .replayOrLowerCounter(counter: 1, highestSeen: 1))
        }

        var lower = try fixture.initiatorSession.seal(envelope: LANControlEnvelopeFactory.ping(messageID: "p2", nonce: "n2"))
        lower = TBEncryptedLANMessage(protocolVersion: lower.protocolVersion,
                                      senderDeviceID: lower.senderDeviceID,
                                      recipientDeviceID: lower.recipientDeviceID,
                                      senderSigningKeyFingerprint: lower.senderSigningKeyFingerprint,
                                      direction: lower.direction,
                                      counter: 1,
                                      nonce: lower.nonce,
                                      ciphertextAndTag: lower.ciphertextAndTag)
        XCTAssertThrowsError(try fixture.responderSession.open(lower))
    }

    func testWrongRecipientAndWrongPeerRejected() throws {
        let fixture = try makeFixture()
        let encrypted = try fixture.initiatorSession.seal(envelope: LANControlEnvelopeFactory.ping(messageID: "p", nonce: "n"))
        let wrongRecipient = TBEncryptedLANMessage(protocolVersion: encrypted.protocolVersion,
                                                   senderDeviceID: encrypted.senderDeviceID,
                                                   recipientDeviceID: "00000000-0000-0000-0000-000000009999",
                                                   senderSigningKeyFingerprint: encrypted.senderSigningKeyFingerprint,
                                                   direction: encrypted.direction,
                                                   counter: encrypted.counter,
                                                   nonce: encrypted.nonce,
                                                   ciphertextAndTag: encrypted.ciphertextAndTag)
        XCTAssertThrowsError(try fixture.responderSession.open(wrongRecipient)) { error in
            XCTAssertEqual(error as? TBSyncSessionError,
                           .wrongRecipient(expected: fixture.responderID, actual: "00000000-0000-0000-0000-000000009999"))
        }

        let wrongPeer = TBEncryptedLANMessage(protocolVersion: encrypted.protocolVersion,
                                              senderDeviceID: "00000000-0000-0000-0000-000000008888",
                                              recipientDeviceID: encrypted.recipientDeviceID,
                                              senderSigningKeyFingerprint: encrypted.senderSigningKeyFingerprint,
                                              direction: encrypted.direction,
                                              counter: encrypted.counter,
                                              nonce: encrypted.nonce,
                                              ciphertextAndTag: encrypted.ciphertextAndTag)
        XCTAssertThrowsError(try fixture.responderSession.open(wrongPeer)) { error in
            XCTAssertEqual(error as? TBSyncSessionError,
                           .wrongPeer(expected: fixture.initiatorID, actual: "00000000-0000-0000-0000-000000008888"))
        }
    }

    func testUntrustedAndRemovedPeersRejectedWhenBuildingAuthenticatedContext() throws {
        let signer = TBDeterministicTestSigner(secret: Data("a".utf8))
        let local = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000101",
                                               displayName: "A",
                                               platform: "macOS",
                                               signingPublicKey: signer.publicKey)
        let store = TBInMemoryTrustedPeerStore()

        XCTAssertThrowsError(try TBAuthenticatedPeerContextBuilder.build(localIdentity: local,
                                                                         peerDeviceID: "00000000-0000-0000-0000-000000000102",
                                                                         peerStore: store)) { error in
            XCTAssertEqual(error as? TBSyncSessionError, .unpairedPeer("00000000-0000-0000-0000-000000000102"))
        }

        try store.saveTrustedPeer(TBTrustedPeerRecord(deviceID: "00000000-0000-0000-0000-000000000102",
                                                      displayName: "B",
                                                      platform: "macOS",
                                                      signingPublicKey: Data("removed".utf8),
                                                      isRemoved: true))
        XCTAssertThrowsError(try TBAuthenticatedPeerContextBuilder.build(localIdentity: local,
                                                                         peerDeviceID: "00000000-0000-0000-0000-000000000102",
                                                                         peerStore: store)) { error in
            XCTAssertEqual(error as? TBSyncSessionError, .removedPeer("00000000-0000-0000-0000-000000000102"))
        }
    }

    func testReconnectHKDFVectorMatchesBothDirectionsAndImportedKeyUsable() throws {
        let localSigner = TBDeterministicTestSigner(secret: Data("local".utf8))
        let peerSigner = TBDeterministicTestSigner(secret: Data("peer".utf8))
        let local = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000201",
                                               displayName: "Local",
                                               platform: "macOS",
                                               signingPublicKey: localSigner.publicKey)
        let peerID = "00000000-0000-0000-0000-000000000202"
        let peerStore = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: peerID,
                                                                                  displayName: "Peer",
                                                                                  platform: "macOS",
                                                                                  signingPublicKey: peerSigner.publicKey)])
        let peerIdentity = TBSyncDevicePublicIdentity(deviceID: peerID,
                                                      displayName: "Peer",
                                                      platform: "macOS",
                                                      signingPublicKey: peerSigner.publicKey)
        let reversePeerStore = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: local.deviceID,
                                                                                         displayName: "Local",
                                                                                         platform: "macOS",
                                                                                         signingPublicKey: localSigner.publicKey)])
        let metadataStore = TBInMemorySyncGroupMetadataStore()
        let groupKeyStore = TBInMemorySyncGroupKeyStore()
        let groupKey = try TBSyncGroupKeyRecord.importExisting(groupID: "group-a",
                                                               keyID: "key-a",
                                                               secret: Data((0..<32).map { UInt8($0) }),
                                                               createdAt: Date(timeIntervalSince1970: 1))
        try metadataStore.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a",
                                                                          keyID: "key-a",
                                                                          createdAt: groupKey.createdAt,
                                                                          state: .active))
        try groupKeyStore.saveSyncGroupKey(groupKey)
        let localHello = makeResumeHello(deviceID: local.deviceID,
                                         role: .initiator,
                                         nonce: Data(repeating: 1, count: 32))
        let peerHello = makeResumeHello(deviceID: peerID,
                                        role: .responder,
                                        nonce: Data(repeating: 2, count: 32))

        let forward = try TBReconnectSessionHydrator.hydrate(localIdentity: local,
                                                             localHello: localHello,
                                                             peerHello: peerHello,
                                                             peerStore: peerStore,
                                                             metadataStore: metadataStore,
                                                             groupKeyStore: groupKeyStore)
        let reverse = try TBReconnectSessionHydrator.hydrate(localIdentity: peerIdentity,
                                                             localHello: peerHello,
                                                             peerHello: localHello,
                                                             peerStore: reversePeerStore,
                                                             metadataStore: metadataStore,
                                                             groupKeyStore: groupKeyStore)

        XCTAssertEqual(forward.keyMaterial.keyID, reverse.keyMaterial.keyID)
        XCTAssertEqual(forward.keyMaterial.rawKeyData, reverse.keyMaterial.rawKeyData)
        XCTAssertEqual(forward.keyMaterial.keyID, "7347637312aa7849206ce21a198f5e039b4e3e0907ab941063de48568bac4be4")
        XCTAssertEqual(forward.keyMaterial.rawKeyData.map { String(format: "%02x", $0) }.joined(),
                       "68defa787f0b8662878a1d1075238f8e80403d46504469eebe8dc061f3f83e45")
        XCTAssertEqual(forward.localNonceSeed, reverse.peerNonceSeed)
        XCTAssertEqual(forward.peerNonceSeed, reverse.localNonceSeed)
    }

    func testReconnectHydrationFailsClosedForMissingMultipleRetiredRemovedAndUnpaired() throws {
        let signer = TBDeterministicTestSigner(secret: Data("local".utf8))
        let peerSigner = TBDeterministicTestSigner(secret: Data("peer".utf8))
        let local = TBSyncDevicePublicIdentity(deviceID: "00000000-0000-0000-0000-000000000211",
                                               displayName: "Local",
                                               platform: "macOS",
                                               signingPublicKey: signer.publicKey)
        let peerID = "00000000-0000-0000-0000-000000000212"
        let localHello = makeResumeHello(deviceID: local.deviceID, role: .initiator, nonce: Data(repeating: 3, count: 32))
        let peerHello = makeResumeHello(deviceID: peerID, role: .responder, nonce: Data(repeating: 4, count: 32))

        XCTAssertThrowsError(try TBReconnectSessionHydrator.hydrate(localIdentity: local,
                                                                    localHello: localHello,
                                                                    peerHello: peerHello,
                                                                    peerStore: TBInMemoryTrustedPeerStore(),
                                                                    metadataStore: TBInMemorySyncGroupMetadataStore(),
                                                                    groupKeyStore: TBInMemorySyncGroupKeyStore())) { error in
            XCTAssertEqual(error as? TBReconnectSessionHydrationError, .pairingRequired("missing active sync group"))
        }

        let multipleMetadata = TBInMemorySyncGroupMetadataStore()
        try multipleMetadata.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a", keyID: "key-a", createdAt: Date(), state: .active))
        try multipleMetadata.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-b", keyID: "key-b", createdAt: Date(), state: .active))
        XCTAssertThrowsError(try TBReconnectSessionHydrator.hydrate(localIdentity: local,
                                                                    localHello: localHello,
                                                                    peerHello: peerHello,
                                                                    peerStore: TBInMemoryTrustedPeerStore(),
                                                                    metadataStore: multipleMetadata,
                                                                    groupKeyStore: TBInMemorySyncGroupKeyStore())) { error in
            XCTAssertEqual(error as? TBReconnectSessionHydrationError, .resetRequired("multiple active sync groups"))
        }

        let metadata = TBInMemorySyncGroupMetadataStore()
        let keys = TBInMemorySyncGroupKeyStore()
        try metadata.saveSyncGroupMetadata(TBSyncGroupMetadataRecord(groupID: "group-a", keyID: "key-a", createdAt: Date(), state: .active))
        try keys.saveSyncGroupKey(TBSyncGroupKeyRecord(groupID: "group-a",
                                                       keyID: "key-a",
                                                       secret: Data(repeating: 9, count: 32),
                                                       createdAt: Date(),
                                                       state: .retired))
        XCTAssertThrowsError(try TBReconnectSessionHydrator.hydrate(localIdentity: local,
                                                                    localHello: localHello,
                                                                    peerHello: peerHello,
                                                                    peerStore: TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: peerID, displayName: "Peer", platform: "macOS", signingPublicKey: peerSigner.publicKey)]),
                                                                    metadataStore: metadata,
                                                                    groupKeyStore: keys)) { error in
            XCTAssertEqual(error as? TBReconnectSessionHydrationError, .retiredSyncGroupKey("key-a"))
        }

        try keys.saveSyncGroupKey(TBSyncGroupKeyRecord(groupID: "group-a",
                                                       keyID: "key-a",
                                                       secret: Data(repeating: 9, count: 32),
                                                       createdAt: Date(),
                                                       state: .active))
        XCTAssertThrowsError(try TBReconnectSessionHydrator.hydrate(localIdentity: local,
                                                                    localHello: localHello,
                                                                    peerHello: peerHello,
                                                                    peerStore: TBInMemoryTrustedPeerStore(),
                                                                    metadataStore: metadata,
                                                                    groupKeyStore: keys)) { error in
            XCTAssertEqual(error as? TBReconnectSessionHydrationError, .unpairedPeer(peerID))
        }
        XCTAssertThrowsError(try TBReconnectSessionHydrator.hydrate(localIdentity: local,
                                                                    localHello: localHello,
                                                                    peerHello: peerHello,
                                                                    peerStore: TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: peerID, displayName: "Peer", platform: "macOS", signingPublicKey: peerSigner.publicKey, isRemoved: true)]),
                                                                    metadataStore: metadata,
                                                                    groupKeyStore: keys)) { error in
            XCTAssertEqual(error as? TBReconnectSessionHydrationError, .removedPeer(peerID))
        }
    }

    func testTrustedImportPathAfterDecryptVerifyOnlyThenCallsRawSink() throws {
        let fixture = try makeFixture()
        let gate = TBAuthenticatedLANSyncGate(session: fixture.responderSession, importer: fixture.responderImporter)
        let senderGate = TBAuthenticatedLANSyncGate(session: fixture.initiatorSession, importer: fixture.initiatorImporter)

        let encrypted = try senderGate.sealSignedEventBatch([fixture.signedEvent], messageID: "events-1")
        let outcome = try gate.openAndImportSignedEventBatch(encrypted)

        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(fixture.responderSink.importCallCount, 1)
    }

    func testInvalidSignedEventDoesNotReachRawImportSinkAfterDecrypt() throws {
        let fixture = try makeFixture()
        var invalid = fixture.signedEvent
        invalid.signature = Data("bad".utf8)
        let senderGate = TBAuthenticatedLANSyncGate(session: fixture.initiatorSession, importer: fixture.initiatorImporter)
        let encrypted = try senderGate.sealSignedEventBatch([invalid], messageID: "events-1")

        let gate = TBAuthenticatedLANSyncGate(session: fixture.responderSession, importer: fixture.responderImporter)
        XCTAssertThrowsError(try gate.openAndImportSignedEventBatch(encrypted))
        XCTAssertEqual(fixture.responderSink.importCallCount, 0)
    }

    func testPlaintextFrameCannotBeUsedForEventSyncInAuthenticatedGate() throws {
        let fixture = try makeFixture()
        let gate = TBAuthenticatedLANSyncGate(session: fixture.responderSession, importer: fixture.responderImporter)
        var plaintext = Tomatt_Sync_V1_Envelope()
        plaintext.messageID = "plain-events"
        plaintext.payload = .eventBatch(Tomatt_Sync_V1_EventBatch())

        XCTAssertNoThrow(try LANEnvelopeFrameCodec.encode(plaintext))
        XCTAssertThrowsError(try gate.rejectPlaintextSyncEventEnvelope(plaintext)) { error in
            XCTAssertEqual(error as? TBSyncSessionError, .plaintextSyncEventExchangeUnavailable)
        }
        XCTAssertEqual(fixture.responderSink.importCallCount, 0)
    }

    private func makeFixture() throws -> Fixture {
        let initiatorID = "00000000-0000-0000-0000-000000000101"
        let responderID = "00000000-0000-0000-0000-000000000102"
        let initiatorSigner = TBDeterministicTestSigner(secret: Data("initiator".utf8))
        let responderSigner = TBDeterministicTestSigner(secret: Data("responder".utf8))
        let initiatorIdentity = TBSyncDevicePublicIdentity(deviceID: initiatorID,
                                                           displayName: "Initiator",
                                                           platform: "macOS",
                                                           signingPublicKey: initiatorSigner.publicKey)
        let responderIdentity = TBSyncDevicePublicIdentity(deviceID: responderID,
                                                           displayName: "Responder",
                                                           platform: "macOS",
                                                           signingPublicKey: responderSigner.publicKey)
        let initiatorStore = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: responderID,
                                                                                       displayName: "Responder",
                                                                                       platform: "macOS",
                                                                                       signingPublicKey: responderSigner.publicKey)])
        let responderStore = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: initiatorID,
                                                                                       displayName: "Initiator",
                                                                                       platform: "macOS",
                                                                                       signingPublicKey: initiatorSigner.publicKey)])
        let initiatorContext = try TBAuthenticatedPeerContextBuilder.build(localIdentity: initiatorIdentity,
                                                                           peerDeviceID: responderID,
                                                                           peerStore: initiatorStore,
                                                                           capabilities: ["encrypted-lan", "signed-events"])
        let responderContext = try TBAuthenticatedPeerContextBuilder.build(localIdentity: responderIdentity,
                                                                           peerDeviceID: initiatorID,
                                                                           peerStore: responderStore,
                                                                           capabilities: ["signed-events", "encrypted-lan"])
        let key = try TBSessionKeyMaterial.fixedTestKey(Data(repeating: 7, count: 32))
        let initiatorSeed = Data(repeating: 1, count: 32)
        let responderSeed = Data(repeating: 2, count: 32)
        let initiatorSession = TBSyncSessionCryptoBox(context: initiatorContext,
                                                      keyMaterial: key,
                                                      localRole: .initiator,
                                                      localNonceSeed: initiatorSeed,
                                                      peerNonceSeed: responderSeed)
        let responderSession = TBSyncSessionCryptoBox(context: responderContext,
                                                      keyMaterial: key,
                                                      localRole: .responder,
                                                      localNonceSeed: responderSeed,
                                                      peerNonceSeed: initiatorSeed)
        let event = makeEnvelope(deviceID: initiatorID, sequence: 1)
        let signed = try TBSignedSyncEvent.sign(envelope: event, signerDeviceID: initiatorID, signer: initiatorSigner)
        let responderSink = FakeImportSink()
        let responderImporter = TBSignedSyncEventTrustedImporter(peerStore: responderStore,
                                                                 verifier: initiatorSigner,
                                                                 sink: responderSink)
        let initiatorSink = FakeImportSink()
        let initiatorImporter = TBSignedSyncEventTrustedImporter(peerStore: initiatorStore,
                                                                 verifier: responderSigner,
                                                                 sink: initiatorSink)
        return Fixture(initiatorID: initiatorID,
                       responderID: responderID,
                       initiatorSession: initiatorSession,
                       responderSession: responderSession,
                       initiatorImporter: initiatorImporter,
                       responderImporter: responderImporter,
                       signedEvent: signed,
                       responderSink: responderSink)
    }

    private func makeResumeHello(deviceID: String,
                                 role: Tomatt_Sync_V1_Hello.SessionRole,
                                 nonce: Data,
                                 groupID: String = "group-a") -> Tomatt_Sync_V1_Hello {
        var hello = Tomatt_Sync_V1_Hello()
        hello.deviceID = deviceID
        hello.displayName = deviceID
        hello.protocolMajor = TomattSyncProtocolV1.supportedMajorVersion
        hello.sessionKeyID = "session-a"
        hello.sessionNonceSeed = nonce
        hello.sessionRole = role
        hello.syncGroupID = groupID
        return hello
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

    private func makeAuthenticatedContext(localID: String,
                                          localName: String,
                                          localSigner: TBDeterministicTestSigner,
                                          peerID: String,
                                          peerName: String,
                                          peerSigner: TBDeterministicTestSigner) throws -> TBAuthenticatedPeerContext {
        let identity = TBSyncDevicePublicIdentity(deviceID: localID,
                                                  displayName: localName,
                                                  platform: "macOS",
                                                  signingPublicKey: localSigner.publicKey)
        let store = TBInMemoryTrustedPeerStore(records: [TBTrustedPeerRecord(deviceID: peerID,
                                                                              displayName: peerName,
                                                                              platform: "macOS",
                                                                              signingPublicKey: peerSigner.publicKey)])
        return try TBAuthenticatedPeerContextBuilder.build(localIdentity: identity,
                                                           peerDeviceID: peerID,
                                                           peerStore: store,
                                                           capabilities: ["encrypted-lan", "signed-events"])
    }

    private func makePairingTranscript(localDeviceID: String,
                                       remoteDeviceID: String,
                                       role: TBPairingRole,
                                       localEphemeralPublicKey: Data,
                                       remoteEphemeralPublicKey: Data,
                                       localSigningPublicKey: Data,
                                       remoteSigningPublicKey: Data) -> TBPairingTranscript {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return TBPairingTranscript(protocolVersion: 1,
                                   role: role,
                                   local: makePairingParticipant(deviceID: localDeviceID,
                                                                 displayName: role == .addDevice ? "Initiator" : "Responder",
                                                                 ephemeralPublicKey: localEphemeralPublicKey,
                                                                 signingPublicKey: localSigningPublicKey,
                                                                 host: role == .addDevice ? "initiator.local" : "responder.local",
                                                                 port: role == .addDevice ? 4040 : 4041,
                                                                 date: date),
                                   remote: makePairingParticipant(deviceID: remoteDeviceID,
                                                                  displayName: role == .addDevice ? "Responder" : "Initiator",
                                                                  ephemeralPublicKey: remoteEphemeralPublicKey,
                                                                  signingPublicKey: remoteSigningPublicKey,
                                                                  host: role == .addDevice ? "responder.local" : "initiator.local",
                                                                  port: role == .addDevice ? 4041 : 4040,
                                                                  date: date),
                                   timestamp: date,
                                   sessionNonce: Data("session-nonce-0001".utf8),
                                   capabilities: ["pairing-v1", "preview-v1"])
    }

    private func makePairingParticipant(deviceID: String,
                                        displayName: String,
                                        ephemeralPublicKey: Data,
                                        signingPublicKey: Data,
                                        host: String,
                                        port: Int,
                                        date: Date) -> TBPairingTranscriptParticipant {
        TBPairingTranscriptParticipant(deviceID: deviceID,
                                       displayName: displayName,
                                       platform: "macOS",
                                       ephemeralPairingPublicKey: ephemeralPublicKey,
                                       signingPublicKey: signingPublicKey,
                                       ephemeralDiscoveryID: "disc-\(deviceID)",
                                       endpoint: TBPairingEndpointMetadata(host: host,
                                                                           port: port,
                                                                           transport: "ws",
                                                                           path: "/tomatt-sync",
                                                                           metadata: ["source": "bonjour", "encoding": "protobuf"]),
                                       idle: .idle(at: date),
                                       capabilities: ["pairing-v1", "preview-v1"],
                                       groupState: .standalone)
    }

    private struct Fixture {
        let initiatorID: String
        let responderID: String
        let initiatorSession: TBSyncSessionCryptoBox
        let responderSession: TBSyncSessionCryptoBox
        let initiatorImporter: TBSignedSyncEventTrustedImporter
        let responderImporter: TBSignedSyncEventTrustedImporter
        let signedEvent: TBSignedSyncEvent
        let responderSink: FakeImportSink
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
}

private extension Data {
    func flippingLastByte() -> Data {
        var data = self
        if let last = data.indices.last {
            data[last] ^= 0x01
        }
        return data
    }
}

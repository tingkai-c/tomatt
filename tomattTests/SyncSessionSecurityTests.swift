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

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

    private func makeTrustedImportFixture(trustedPeer: TBTrustedPeerRecord? = TBTrustedPeerRecord(deviceID: "peer-a",
                                                                                                  displayName: "Peer A",
                                                                                                  platform: "macOS",
                                                                                                  signingPublicKey: TBDeterministicTestSigner(secret: Data("secret-a".utf8)).publicKey),
                                          isRemoved: Bool = false) throws -> Fixture {
        let signer = TBDeterministicTestSigner(secret: Data("secret-a".utf8))
        let envelope = makeEnvelope(deviceID: "peer-a", sequence: 1)
        let signed = try TBSignedSyncEvent.sign(envelope: envelope, signerDeviceID: "peer-a", signer: signer)
        let peerStore = TBInMemoryTrustedPeerStore()
        if var trustedPeer = trustedPeer {
            trustedPeer.isRemoved = isRemoved
            try peerStore.saveTrustedPeer(trustedPeer)
        }
        let sink = FakeImportSink()
        let importer = TBSignedSyncEventTrustedImporter(peerStore: peerStore, verifier: signer, sink: sink)
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
}

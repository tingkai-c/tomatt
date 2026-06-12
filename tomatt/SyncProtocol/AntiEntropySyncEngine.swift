import Foundation

enum TBAntiEntropySyncError: Error, Equatable {
    case session(TBSyncSessionError)
    case protocolViolation(String)
    case signing(String)
    case importSecurity(TBSyncSecurityError)
    case importFailed(TBSyncImportOutcome)
    case decoding(String)
}

enum TBAntiEntropySyncStatus: Equatable {
    case summaryReceived(deviceID: String, eventCount: Int64)
    case missingEventsRequested(deviceID: String, afterSequence: Int64)
    case eventBatchSent(messageID: String, eventIDs: [String])
    case eventBatchImported(messageID: String, outcome: TBSyncImportOutcome)
    case eventBatchAcked(TBAntiEntropyEventBatchAck)
    case newEventsAvailable(deviceID: String, eventCount: Int64)
    case error(TBAntiEntropySyncError)
}

struct TBAntiEntropyEventBatchAck: Equatable {
    var batchMessageID: String
    var acceptedEventIDs: [String]
    var rejectedEventIDs: [String]
}

struct TBAntiEntropySyncStepResult: Equatable {
    var outgoingMessages: [TBEncryptedLANMessage]
    var statuses: [TBAntiEntropySyncStatus]

    init(outgoingMessages: [TBEncryptedLANMessage] = [], statuses: [TBAntiEntropySyncStatus] = []) {
        self.outgoingMessages = outgoingMessages
        self.statuses = statuses
    }
}

final class TBAntiEntropySyncEngine {
    private let session: TBSyncSessionCryptoBox
    private let eventLog: TBSyncEventLogExporting
    private let signerDeviceID: String
    private let signer: TBSyncEventSigning
    private let trustedImporter: TBSignedSyncEventTrustedImporter
    private let batchLimit: Int
    private var nextMessageSequence: UInt64 = 0

    init(session: TBSyncSessionCryptoBox,
         eventLog: TBSyncEventLogExporting,
         signerDeviceID: String,
         signer: TBSyncEventSigning,
         trustedImporter: TBSignedSyncEventTrustedImporter,
         batchLimit: Int = 250) {
        self.session = session
        self.eventLog = eventLog
        self.signerDeviceID = signerDeviceID
        self.signer = signer
        self.trustedImporter = trustedImporter
        self.batchLimit = batchLimit
    }

    func beginSync() -> TBAntiEntropySyncStepResult {
        sealLocalSummaries(reason: "summary")
    }

    func notifyNewLocalEventsAvailable() -> TBAntiEntropySyncStepResult {
        let summary = localSignerSummary()
        let eventCount = summary[signerDeviceID] ?? 0
        var notification = Tomatt_Sync_V1_NewEventsAvailable()
        notification.deviceID = signerDeviceID
        notification.eventCount = UInt64(max(0, eventCount))

        let messageID = nextMessageID(prefix: "new-events")
        var envelope = makeEnvelope(messageID: messageID)
        envelope.payload = .newEventsAvailable(notification)
        do {
            return TBAntiEntropySyncStepResult(outgoingMessages: [try session.seal(envelope: envelope)],
                                             statuses: [.newEventsAvailable(deviceID: signerDeviceID,
                                                                           eventCount: eventCount)])
        } catch let error as TBSyncSessionError {
            return TBAntiEntropySyncStepResult(statuses: [.error(.session(error))])
        } catch {
            return TBAntiEntropySyncStepResult(statuses: [.error(.protocolViolation(String(describing: error)))])
        }
    }

    func receive(_ message: TBEncryptedLANMessage) -> TBAntiEntropySyncStepResult {
        let envelope: Tomatt_Sync_V1_Envelope
        do {
            envelope = try session.open(message)
        } catch let error as TBSyncSessionError {
            return TBAntiEntropySyncStepResult(statuses: [.error(.session(error))])
        } catch {
            return TBAntiEntropySyncStepResult(statuses: [.error(.protocolViolation(String(describing: error)))])
        }

        switch envelope.payload {
        case .eventSummary(let summary):
            return handleSummary(summary)
        case .missingEventRequest(let request):
            return handleMissingEventRequest(request)
        case .eventBatch(let batch):
            return handleEventBatch(batch, messageID: envelope.messageID)
        case .eventBatchAck(let ack):
            let modeled = TBAntiEntropyEventBatchAck(batchMessageID: ack.batchMessageID,
                                                    acceptedEventIDs: ack.acceptedEventIds,
                                                    rejectedEventIDs: ack.rejectedEventIds)
            return TBAntiEntropySyncStepResult(statuses: [.eventBatchAcked(modeled)])
        case .newEventsAvailable(let notification):
            return handleNewEventsAvailable(notification)
        case nil:
            return TBAntiEntropySyncStepResult(statuses: [.error(.protocolViolation("missing sync payload"))])
        default:
            return TBAntiEntropySyncStepResult(statuses: [.error(.protocolViolation("unsupported anti-entropy payload"))])
        }
    }

    private func sealLocalSummaries(reason: String) -> TBAntiEntropySyncStepResult {
        let summary = localSignerSummary()

        var messages: [TBEncryptedLANMessage] = []
        var statuses: [TBAntiEntropySyncStatus] = []
        for deviceID in summary.keys.sorted() {
            var proto = Tomatt_Sync_V1_EventSummary()
            proto.deviceID = deviceID
            proto.eventCount = UInt64(max(0, summary[deviceID] ?? 0))
            let messageID = nextMessageID(prefix: reason)
            var envelope = makeEnvelope(messageID: messageID)
            envelope.payload = .eventSummary(proto)
            do {
                messages.append(try session.seal(envelope: envelope))
            } catch let error as TBSyncSessionError {
                statuses.append(.error(.session(error)))
            } catch {
                statuses.append(.error(.protocolViolation(String(describing: error))))
            }
        }
        return TBAntiEntropySyncStepResult(outgoingMessages: messages, statuses: statuses)
    }

    private func handleSummary(_ summary: Tomatt_Sync_V1_EventSummary) -> TBAntiEntropySyncStepResult {
        let remoteCount = Int64(summary.eventCount)
        var statuses: [TBAntiEntropySyncStatus] = [.summaryReceived(deviceID: summary.deviceID, eventCount: remoteCount)]
        guard summary.deviceID == session.context.peerDeviceID else { return TBAntiEntropySyncStepResult(statuses: statuses) }
        let localCount = eventLog.localSummary()[summary.deviceID] ?? 0
        guard remoteCount > localCount else { return TBAntiEntropySyncStepResult(statuses: statuses) }

        let request = missingRequest(deviceID: summary.deviceID, afterSequence: localCount)
        let sealed = sealMissingRequest(request)
        statuses.append(contentsOf: sealed.statuses)
        return TBAntiEntropySyncStepResult(outgoingMessages: sealed.outgoingMessages, statuses: statuses)
    }

    private func handleNewEventsAvailable(_ notification: Tomatt_Sync_V1_NewEventsAvailable) -> TBAntiEntropySyncStepResult {
        let remoteCount = Int64(notification.eventCount)
        var statuses: [TBAntiEntropySyncStatus] = [.newEventsAvailable(deviceID: notification.deviceID,
                                                                       eventCount: remoteCount)]
        guard notification.deviceID == session.context.peerDeviceID else { return TBAntiEntropySyncStepResult(statuses: statuses) }
        let localCount = eventLog.localSummary()[notification.deviceID] ?? 0
        guard remoteCount > localCount else { return TBAntiEntropySyncStepResult(statuses: statuses) }

        let request = missingRequest(deviceID: notification.deviceID, afterSequence: localCount)
        let sealed = sealMissingRequest(request)
        statuses.append(contentsOf: sealed.statuses)
        return TBAntiEntropySyncStepResult(outgoingMessages: sealed.outgoingMessages, statuses: statuses)
    }

    private func sealMissingRequest(_ request: Tomatt_Sync_V1_MissingEventRequest) -> TBAntiEntropySyncStepResult {
        let messageID = nextMessageID(prefix: "missing")
        var envelope = makeEnvelope(messageID: messageID)
        envelope.payload = .missingEventRequest(request)
        do {
            return TBAntiEntropySyncStepResult(outgoingMessages: [try session.seal(envelope: envelope)],
                                             statuses: [.missingEventsRequested(deviceID: request.deviceID,
                                                                               afterSequence: Int64(request.afterSequence))])
        } catch let error as TBSyncSessionError {
            return TBAntiEntropySyncStepResult(statuses: [.error(.session(error))])
        } catch {
            return TBAntiEntropySyncStepResult(statuses: [.error(.protocolViolation(String(describing: error)))])
        }
    }

    private func handleMissingEventRequest(_ proto: Tomatt_Sync_V1_MissingEventRequest) -> TBAntiEntropySyncStepResult {
        let request = TBSyncMissingEventsRequest(remoteSummary: [proto.deviceID: Int64(proto.afterSequence)],
                                                 limit: proto.limit == 0 ? batchLimit : Int(proto.limit))
        let batch = TBSyncEventBatch(events: eventLog.missingEvents(for: request).events.filter {
            $0.originDeviceID == signerDeviceID
        })
        do {
            let signedEvents = try batch.events.map {
                try TBSignedSyncEvent.sign(envelope: $0, signerDeviceID: signerDeviceID, signer: signer)
            }
            let messageID = nextMessageID(prefix: "batch")
            var protoBatch = Tomatt_Sync_V1_EventBatch()
            protoBatch.deviceID = signerDeviceID
            protoBatch.events = try signedEvents.map(protoSyncEvent(from:))
            var envelope = makeEnvelope(messageID: messageID)
            envelope.payload = .eventBatch(protoBatch)
            return TBAntiEntropySyncStepResult(outgoingMessages: [try session.seal(envelope: envelope)],
                                             statuses: [.eventBatchSent(messageID: messageID,
                                                                       eventIDs: signedEvents.map { $0.envelope.eventID.uuidString.lowercased() })])
        } catch let error as TBSyncSessionError {
            return TBAntiEntropySyncStepResult(statuses: [.error(.session(error))])
        } catch {
            return TBAntiEntropySyncStepResult(statuses: [.error(.signing(String(describing: error)))])
        }
    }

    private func handleEventBatch(_ batch: Tomatt_Sync_V1_EventBatch,
                                  messageID: String) -> TBAntiEntropySyncStepResult {
        let signedEvents: [TBSignedSyncEvent]
        do {
            signedEvents = try batch.events.map(signedSyncEvent(from:))
        } catch {
            return TBAntiEntropySyncStepResult(statuses: [.error(.decoding(String(describing: error)))])
        }

        let eventIDs = signedEvents.map { $0.envelope.eventID.uuidString.lowercased() }
        do {
            let outcome = try trustedImporter.importSignedEvents(signedEvents, context: session.context.importContext)
            let hasImportFailure = outcome.rejected > 0 || outcome.collision > 0 || outcome.persistenceFailed
            let accepted = hasImportFailure ? [] : eventIDs
            let rejected = hasImportFailure ? eventIDs : []
            let ack = TBAntiEntropyEventBatchAck(batchMessageID: messageID,
                                                acceptedEventIDs: accepted,
                                                rejectedEventIDs: rejected)
            var statuses: [TBAntiEntropySyncStatus] = [.eventBatchImported(messageID: messageID, outcome: outcome)]
            if hasImportFailure {
                statuses.append(.error(.importFailed(outcome)))
            }
            return appendAck(ack, statuses: statuses)
        } catch let error as TBSyncSecurityError {
            let ack = TBAntiEntropyEventBatchAck(batchMessageID: messageID,
                                                acceptedEventIDs: [],
                                                rejectedEventIDs: eventIDs)
            return appendAck(ack, statuses: [.error(.importSecurity(error))])
        } catch {
            let ack = TBAntiEntropyEventBatchAck(batchMessageID: messageID,
                                                acceptedEventIDs: [],
                                                rejectedEventIDs: eventIDs)
            return appendAck(ack, statuses: [.error(.decoding(String(describing: error)))])
        }
    }

    private func appendAck(_ ack: TBAntiEntropyEventBatchAck,
                           statuses: [TBAntiEntropySyncStatus]) -> TBAntiEntropySyncStepResult {
        var proto = Tomatt_Sync_V1_EventBatchAck()
        proto.batchMessageID = ack.batchMessageID
        proto.acceptedEventIds = ack.acceptedEventIDs
        proto.rejectedEventIds = ack.rejectedEventIDs
        var envelope = makeEnvelope(messageID: nextMessageID(prefix: "ack"))
        envelope.payload = .eventBatchAck(proto)
        do {
            return TBAntiEntropySyncStepResult(outgoingMessages: [try session.seal(envelope: envelope)],
                                             statuses: statuses + [.eventBatchAcked(ack)])
        } catch let error as TBSyncSessionError {
            return TBAntiEntropySyncStepResult(statuses: statuses + [.error(.session(error))])
        } catch {
            return TBAntiEntropySyncStepResult(statuses: statuses + [.error(.protocolViolation(String(describing: error)))])
        }
    }

    private func signedSyncEvent(from proto: Tomatt_Sync_V1_SyncEvent) throws -> TBSignedSyncEvent {
        guard !proto.canonicalJson.isEmpty else { throw TBAntiEntropySyncError.decoding("missing signed event json") }
        return try JSONDecoder().decode(TBSignedSyncEvent.self, from: proto.canonicalJson)
    }

    private func protoSyncEvent(from signedEvent: TBSignedSyncEvent) throws -> Tomatt_Sync_V1_SyncEvent {
        guard signedEvent.envelope.event.isSyncable,
              let originDeviceID = signedEvent.envelope.originDeviceID,
              let deviceSequence = signedEvent.envelope.deviceSequence,
              deviceSequence > 0 else {
            throw TBAntiEntropySyncError.protocolViolation("attempted to export non-syncable or local-only event")
        }
        var proto = Tomatt_Sync_V1_SyncEvent()
        proto.eventID = signedEvent.envelope.eventID.uuidString.lowercased()
        proto.originDeviceID = originDeviceID
        proto.sequence = UInt64(deviceSequence)
        proto.canonicalJson = try JSONEncoder().encode(signedEvent)
        return proto
    }

    private func missingRequest(deviceID: String, afterSequence: Int64) -> Tomatt_Sync_V1_MissingEventRequest {
        var request = Tomatt_Sync_V1_MissingEventRequest()
        request.deviceID = deviceID
        request.afterSequence = UInt64(max(0, afterSequence))
        request.limit = UInt32(max(0, batchLimit))
        return request
    }

    private func localSignerSummary() -> TBSyncWatermarkSummary {
        [signerDeviceID: eventLog.localSummary()[signerDeviceID] ?? 0]
    }

    private func makeEnvelope(messageID: String) -> Tomatt_Sync_V1_Envelope {
        var envelope = Tomatt_Sync_V1_Envelope()
        envelope.messageID = messageID
        envelope.protocolMajor = session.context.protocolMajor
        envelope.protocolMinor = session.context.protocolMinor
        return envelope
    }

    private func nextMessageID(prefix: String) -> String {
        nextMessageSequence += 1
        return "\(prefix)-\(signerDeviceID)-\(nextMessageSequence)"
    }
}

final class TBInMemoryEncryptedSyncPeer {
    let engine: TBAntiEntropySyncEngine

    init(engine: TBAntiEntropySyncEngine) {
        self.engine = engine
    }

    func beginSync() -> [TBEncryptedLANMessage] {
        engine.beginSync().outgoingMessages
    }

    func notifyNewLocalEventsAvailable() -> [TBEncryptedLANMessage] {
        engine.notifyNewLocalEventsAvailable().outgoingMessages
    }

    @discardableResult
    func receive(_ message: TBEncryptedLANMessage) -> TBAntiEntropySyncStepResult {
        engine.receive(message)
    }
}

enum TBInMemoryEncryptedSyncHarness {
    static func drain(_ initialMessages: [TBEncryptedLANMessage],
                      deliver: (TBEncryptedLANMessage) -> TBInMemoryEncryptedSyncPeer?,
                      maxSteps: Int = 100) -> [TBAntiEntropySyncStatus] {
        var queue = initialMessages
        var statuses: [TBAntiEntropySyncStatus] = []
        var steps = 0
        while !queue.isEmpty && steps < maxSteps {
            steps += 1
            let message = queue.removeFirst()
            guard let recipient = deliver(message) else { continue }
            let result = recipient.receive(message)
            statuses.append(contentsOf: result.statuses)
            queue.append(contentsOf: result.outgoingMessages)
        }
        return statuses
    }
}

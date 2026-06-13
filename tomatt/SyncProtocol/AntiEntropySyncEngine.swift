import Foundation

enum TBAntiEntropySyncError: Error, Equatable {
    case session(TBSyncSessionError)
    case protocolViolation(String)
    case signing(String)
    case importSecurity(TBSyncSecurityError)
    case importFailed(TBSyncImportOutcome)
    case decoding(String)
    case signedMetadataMissing(deviceID: String, sequence: Int64)
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
    private let signedEventStore: TBSignedSyncEventStoring?
    private let batchLimit: Int
    private var nextMessageSequence: UInt64 = 0

    init(session: TBSyncSessionCryptoBox,
         eventLog: TBSyncEventLogExporting,
         signerDeviceID: String,
         signer: TBSyncEventSigning,
         trustedImporter: TBSignedSyncEventTrustedImporter,
         signedEventStore: TBSignedSyncEventStoring? = nil,
         batchLimit: Int = 250) {
        self.session = session
        self.eventLog = eventLog
        self.signerDeviceID = signerDeviceID
        self.signer = signer
        self.trustedImporter = trustedImporter
        self.signedEventStore = signedEventStore
        self.batchLimit = batchLimit
    }

    func beginSync() -> TBAntiEntropySyncStepResult {
        sealLocalSummaries(reason: "summary")
    }

    func notifyNewLocalEventsAvailable() -> TBAntiEntropySyncStepResult {
        let summary = localSummary()
        var messages: [TBEncryptedLANMessage] = []
        var statuses: [TBAntiEntropySyncStatus] = []
        for deviceID in summary.keys.sorted() {
            let eventCount = summary[deviceID] ?? 0
            var notification = Tomatt_Sync_V1_NewEventsAvailable()
            notification.deviceID = deviceID
            notification.eventCount = UInt64(max(0, eventCount))

            let messageID = nextMessageID(prefix: "new-events")
            var envelope = makeEnvelope(messageID: messageID)
            envelope.payload = .newEventsAvailable(notification)
            do {
                messages.append(try session.seal(envelope: envelope))
                statuses.append(.newEventsAvailable(deviceID: deviceID, eventCount: eventCount))
            } catch let error as TBSyncSessionError {
                statuses.append(.error(.session(error)))
            } catch {
                statuses.append(.error(.protocolViolation(String(describing: error))))
            }
        }
        return TBAntiEntropySyncStepResult(outgoingMessages: messages, statuses: statuses)
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
        let summary = localSummary()

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
        let limit = proto.limit == 0 ? batchLimit : Int(proto.limit)
        let request = TBSyncMissingEventsRequest(remoteSummary: [proto.deviceID: Int64(proto.afterSequence)],
                                                 limit: nil)
        let batch = TBSyncEventBatch(events: eventLog.missingEvents(for: request).events.filter {
            $0.originDeviceID == proto.deviceID
        }.prefix(limit).map { $0 })
        do {
            var signedEvents: [TBSignedSyncEvent] = []
            var statuses: [TBAntiEntropySyncStatus] = []
            for event in batch.events {
                do {
                    signedEvents.append(try signedEventForExport(event))
                } catch let error as TBAntiEntropySyncError {
                    statuses.append(.error(error))
                }
            }
            let messageID = nextMessageID(prefix: "batch")
            var protoBatch = Tomatt_Sync_V1_EventBatch()
            protoBatch.deviceID = proto.deviceID
            protoBatch.events = try signedEvents.map(protoSyncEvent(from:))
            var envelope = makeEnvelope(messageID: messageID)
            envelope.payload = .eventBatch(protoBatch)
            return TBAntiEntropySyncStepResult(outgoingMessages: [try session.seal(envelope: envelope)],
                                             statuses: statuses + [.eventBatchSent(messageID: messageID,
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
        let originDeviceID = batch.deviceID
        let previousWatermark = eventLog.localSummary()[originDeviceID] ?? 0
        do {
            let outcome = try trustedImporter.importSignedEvents(signedEvents, context: session.context.importContext)
            let currentWatermark = eventLog.localSummary()[originDeviceID] ?? 0
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
            var result = appendAck(ack, statuses: statuses)
            if !hasImportFailure,
               batchLimit > 0,
               signedEvents.count >= batchLimit,
               currentWatermark > previousWatermark {
                let continuation = sealMissingRequest(missingRequest(deviceID: originDeviceID,
                                                                     afterSequence: currentWatermark))
                result.outgoingMessages.append(contentsOf: continuation.outgoingMessages)
                result.statuses.append(contentsOf: continuation.statuses)
            }
            return result
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

    private func signedEventForExport(_ envelope: TBEventEnvelope) throws -> TBSignedSyncEvent {
        if let existing = try signedEventStore?.signedSyncEvent(eventID: envelope.eventID) {
            return existing
        }
        guard envelope.originDeviceID == signerDeviceID else {
            throw TBAntiEntropySyncError.signedMetadataMissing(deviceID: envelope.originDeviceID ?? "",
                                                              sequence: envelope.deviceSequence ?? 0)
        }
        let signed = try TBSignedSyncEvent.sign(envelope: envelope,
                                               signerDeviceID: signerDeviceID,
                                               signer: signer)
        try signedEventStore?.saveSignedSyncEvent(signed)
        return signed
    }

    private func missingRequest(deviceID: String, afterSequence: Int64) -> Tomatt_Sync_V1_MissingEventRequest {
        var request = Tomatt_Sync_V1_MissingEventRequest()
        request.deviceID = deviceID
        request.afterSequence = UInt64(max(0, afterSequence))
        request.limit = UInt32(max(0, batchLimit))
        return request
    }

    private func localSummary() -> TBSyncWatermarkSummary {
        eventLog.localSummary()
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

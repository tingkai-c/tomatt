import Foundation

typealias TBSyncWatermarkSummary = [String: Int64]

enum TBSyncSessionState: Equatable {
    case idle
    case preparingSummary
    case requestingMissingEvents
    case exportingBatch
    case awaitingTrustedImport
    case completed
    case failed(String)
}

struct TBSyncMissingEventsRequest: Equatable {
    var remoteSummary: TBSyncWatermarkSummary
    var limit: Int?

    init(remoteSummary: TBSyncWatermarkSummary, limit: Int? = nil) {
        self.remoteSummary = remoteSummary
        self.limit = limit
    }
}

struct TBSyncEventBatch: Equatable {
    var events: [TBEventEnvelope]

    init(events: [TBEventEnvelope]) {
        self.events = TBEventProjector.canonicalize(events)
    }
}

struct TBSyncImportOutcome: Equatable {
    var imported: Int
    var duplicate: Int
    var rejected: Int
    var collision: Int
    var persistenceFailed: Bool

    init(result: TBImportResult) {
        imported = result.imported
        duplicate = result.duplicate
        rejected = result.rejected
        collision = result.collision
        persistenceFailed = result.persistenceFailed
    }
}

protocol TBSyncEventLogExporting {
    func localSummary() -> TBSyncWatermarkSummary
    func missingEvents(for request: TBSyncMissingEventsRequest) -> TBSyncEventBatch
}

protocol TBSyncAlreadyVerifiedEventImporting {
    func importAlreadyVerifiedEvents(_ batch: TBSyncEventBatch) -> TBSyncImportOutcome
}

typealias TBSyncEventLogAccess = TBSyncEventLogExporting & TBSyncAlreadyVerifiedEventImporting

/// Platform-neutral façade over the local event log anti-entropy primitives.
///
/// This type intentionally exposes only domain sync values. It does not know
/// about encodings, connectivity, pairing, signatures, or trust establishment.
/// Callers must route external input through verification before reaching
/// `importAlreadyVerifiedEvents(_:)`.
final class TBSyncEventLogFacade: TBSyncEventLogAccess {
    private let eventLog: TBLocalEventLog

    init(eventLog: TBLocalEventLog) {
        self.eventLog = eventLog
    }

    func localSummary() -> TBSyncWatermarkSummary {
        eventLog.syncSummary()
    }

    func missingEvents(for request: TBSyncMissingEventsRequest) -> TBSyncEventBatch {
        var events = eventLog.missingEvents(relativeTo: request.remoteSummary)
        if let limit = request.limit, limit >= 0 {
            events = Array(events.prefix(limit))
        }
        return TBSyncEventBatch(events: events)
    }

    func importAlreadyVerifiedEvents(_ batch: TBSyncEventBatch) -> TBSyncImportOutcome {
        TBSyncImportOutcome(result: eventLog.importEvents(batch.events))
    }
}

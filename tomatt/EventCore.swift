import Foundation

let TBEventSchemaVersion = 2

struct TBDeviceIdentity: Codable, Equatable {
    let deviceID: String
    var displayName: String
    var platform: String?
}

protocol TBDeviceIdentityStoring {
    func loadIdentity() throws -> TBDeviceIdentity?
    func saveIdentity(_ identity: TBDeviceIdentity) throws
}

final class TBFileDeviceIdentityStore: TBDeviceIdentityStoring {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL = TBFileDeviceIdentityStore.defaultFileURL()) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.sortedKeys]
    }

    func loadIdentity() throws -> TBDeviceIdentity? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(TBDeviceIdentity.self, from: Data(contentsOf: fileURL))
    }

    func saveIdentity(_ identity: TBDeviceIdentity) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(identity).write(to: fileURL, options: [.atomic])
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("tomatt", isDirectory: true)
        return baseURL.appendingPathComponent("device-identity.json")
    }
}

enum TBDeviceIdentityProvider {
    static func loadOrCreate(store: TBDeviceIdentityStoring,
                             defaultName: String = Host.current().localizedName ?? "This Mac") throws -> TBDeviceIdentity {
        if let identity = try store.loadIdentity() {
            return identity
        }
        let identity = TBDeviceIdentity(deviceID: UUID().uuidString.lowercased(),
                                        displayName: defaultName,
                                        platform: "macOS")
        try store.saveIdentity(identity)
        return identity
    }
}

enum TBSyncEventID {
    static let namespace = "tomatt.sync.v2.event"

    static func derive(originDeviceID: String, deviceSequence: Int64) -> UUID {
        let input = "\(namespace):\(originDeviceID):\(deviceSequence)"
        var first = fnv1a64(seed: 0xcbf29ce484222325, bytes: Array(input.utf8))
        var second = fnv1a64(seed: 0x84222325cbf29ce4, bytes: Array(input.utf8.reversed()))
        first = (first & 0xffffffffffff0fff) | 0x0000000000005000
        second = (second & 0x3fffffffffffffff) | 0x8000000000000000
        let uuidString = String(format: "%08llx-%04llx-%04llx-%04llx-%012llx",
                                first >> 32,
                                (first >> 16) & 0xffff,
                                first & 0xffff,
                                second >> 48,
                                second & 0x0000ffffffffffff)
        return UUID(uuidString: uuidString)!
    }

    private static func fnv1a64(seed: UInt64, bytes: [UInt8]) -> UInt64 {
        bytes.reduce(seed) { hash, byte in
            (hash ^ UInt64(byte)).multipliedReportingOverflow(by: 0x100000001b3).partialValue
        }
    }
}

enum TBEventEnvelopeFactory {
    static func makeLocal(event: TBEvent,
                           existingEnvelopes: [TBEventEnvelope],
                           identity: TBDeviceIdentity?,
                           streamID: String = "local",
                           recordedAt: Date = Date()) -> TBEventEnvelope? {
        if event.isSyncable, identity == nil {
            return nil
        }
        let sequence = (existingEnvelopes.map(\.sequence).max() ?? 0) + 1
        let deviceSequence: Int64? = event.isSyncable && identity != nil
            ? nextLocalDeviceSequence(in: existingEnvelopes, deviceID: identity!.deviceID)
            : nil
        let eventID = deviceSequence.map {
            TBSyncEventID.derive(originDeviceID: identity!.deviceID, deviceSequence: $0)
        } ?? UUID()
        return TBEventEnvelope(eventID: eventID,
                               streamID: streamID,
                               sequence: sequence,
                               originDeviceID: event.isSyncable ? identity?.deviceID : nil,
                               deviceSequence: deviceSequence,
                               recordedAt: recordedAt,
                               event: event)
    }

    private static func nextLocalDeviceSequence(in envelopes: [TBEventEnvelope], deviceID: String) -> Int64 {
        (envelopes.compactMap { envelope -> Int64? in
            guard envelope.schemaVersion == TBEventSchemaVersion,
                  envelope.event.isSyncable,
                  envelope.originDeviceID == deviceID else { return nil }
            return envelope.deviceSequence
        }.max() ?? 0) + 1
    }
}

struct TBEventEnvelope: Codable, Equatable, Identifiable {
    var schemaVersion: Int
    var eventID: UUID
    var streamID: String
    var sequence: Int64
    var originDeviceID: String?
    var deviceSequence: Int64?
    var recordedAt: Date
    var event: TBEvent

    var id: UUID { eventID }


    init(schemaVersion: Int = TBEventSchemaVersion,
         eventID: UUID = UUID(),
         streamID: String,
         sequence: Int64,
         originDeviceID: String? = nil,
         deviceSequence: Int64? = nil,
         recordedAt: Date = Date(),
         event: TBEvent) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.streamID = streamID
        self.sequence = sequence
        self.originDeviceID = originDeviceID
        self.deviceSequence = deviceSequence
        self.recordedAt = recordedAt
        self.event = event
    }
}

enum TBEvent: Codable, Equatable {
    case settingChanged(TBSettingChanged)
    case presetUpserted(TBPresetUpserted)
    case presetDeleted(TBPresetDeleted)
    case presetSelected(TBPresetSelected)
    case presetOrderChanged(TBPresetOrderChanged)
    case timerStarted(TBTimerStarted)
    case timerPaused(TBTimerPaused)
    case timerResumed(TBTimerResumed)
    case timerStopped(TBTimerStopped)
    case timerSkipped(TBTimerSkipped)
    case timerCompleted(TBTimerCompleted)
    case activeTimerSessionPersisted(TBActiveTimerSessionPersisted)
    case activeTimerSessionCleared(TBActiveTimerSessionCleared)
    case statsRecordAppended(TBStatsRecordAppended)
    case devicePaired(TBDevicePaired)
    case deviceRenamed(TBDeviceRenamed)
    case deviceRemoved(TBDeviceRemoved)

    var isSyncable: Bool {
        switch self {
        case .settingChanged,
             .presetUpserted,
             .presetDeleted,
             .presetSelected,
             .presetOrderChanged,
             .timerStarted,
             .timerPaused,
             .timerResumed,
             .timerStopped,
             .timerSkipped,
             .timerCompleted,
             .statsRecordAppended,
             .devicePaired,
             .deviceRenamed,
             .deviceRemoved:
            return true
        case .activeTimerSessionPersisted,
             .activeTimerSessionCleared:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum EventType: String, Codable {
        case settingChanged
        case presetUpserted
        case presetDeleted
        case presetSelected
        case presetOrderChanged
        case timerStarted
        case timerPaused
        case timerResumed
        case timerStopped
        case timerSkipped
        case timerCompleted
        case activeTimerSessionPersisted
        case activeTimerSessionCleared
        case statsRecordAppended
        case devicePaired
        case deviceRenamed
        case deviceRemoved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .settingChanged:
            self = .settingChanged(try container.decode(TBSettingChanged.self, forKey: .payload))
        case .presetUpserted:
            self = .presetUpserted(try container.decode(TBPresetUpserted.self, forKey: .payload))
        case .presetDeleted:
            self = .presetDeleted(try container.decode(TBPresetDeleted.self, forKey: .payload))
        case .presetSelected:
            self = .presetSelected(try container.decode(TBPresetSelected.self, forKey: .payload))
        case .presetOrderChanged:
            self = .presetOrderChanged(try container.decode(TBPresetOrderChanged.self, forKey: .payload))
        case .timerStarted:
            self = .timerStarted(try container.decode(TBTimerStarted.self, forKey: .payload))
        case .timerPaused:
            self = .timerPaused(try container.decode(TBTimerPaused.self, forKey: .payload))
        case .timerResumed:
            self = .timerResumed(try container.decode(TBTimerResumed.self, forKey: .payload))
        case .timerStopped:
            self = .timerStopped(try container.decode(TBTimerStopped.self, forKey: .payload))
        case .timerSkipped:
            self = .timerSkipped(try container.decode(TBTimerSkipped.self, forKey: .payload))
        case .timerCompleted:
            self = .timerCompleted(try container.decode(TBTimerCompleted.self, forKey: .payload))
        case .activeTimerSessionPersisted:
            self = .activeTimerSessionPersisted(
                try container.decode(TBActiveTimerSessionPersisted.self, forKey: .payload)
            )
        case .activeTimerSessionCleared:
            self = .activeTimerSessionCleared(
                try container.decode(TBActiveTimerSessionCleared.self, forKey: .payload)
            )
        case .statsRecordAppended:
            self = .statsRecordAppended(try container.decode(TBStatsRecordAppended.self, forKey: .payload))
        case .devicePaired:
            self = .devicePaired(try container.decode(TBDevicePaired.self, forKey: .payload))
        case .deviceRenamed:
            self = .deviceRenamed(try container.decode(TBDeviceRenamed.self, forKey: .payload))
        case .deviceRemoved:
            self = .deviceRemoved(try container.decode(TBDeviceRemoved.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .settingChanged(let payload):
            try container.encode(EventType.settingChanged, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .presetUpserted(let payload):
            try container.encode(EventType.presetUpserted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .presetDeleted(let payload):
            try container.encode(EventType.presetDeleted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .presetSelected(let payload):
            try container.encode(EventType.presetSelected, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .presetOrderChanged(let payload):
            try container.encode(EventType.presetOrderChanged, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .timerStarted(let payload):
            try container.encode(EventType.timerStarted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .timerPaused(let payload):
            try container.encode(EventType.timerPaused, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .timerResumed(let payload):
            try container.encode(EventType.timerResumed, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .timerStopped(let payload):
            try container.encode(EventType.timerStopped, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .timerSkipped(let payload):
            try container.encode(EventType.timerSkipped, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .timerCompleted(let payload):
            try container.encode(EventType.timerCompleted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .activeTimerSessionPersisted(let payload):
            try container.encode(EventType.activeTimerSessionPersisted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .activeTimerSessionCleared(let payload):
            try container.encode(EventType.activeTimerSessionCleared, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .statsRecordAppended(let payload):
            try container.encode(EventType.statsRecordAppended, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .devicePaired(let payload):
            try container.encode(EventType.devicePaired, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .deviceRenamed(let payload):
            try container.encode(EventType.deviceRenamed, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .deviceRemoved(let payload):
            try container.encode(EventType.deviceRemoved, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

enum TBSettingKey: String, Codable, Equatable {
    case workDurationMinutes
    case shortRestDurationMinutes
    case longRestDurationMinutes
    case workIntervalsPerSet
    case pauseAfterRestFinish
    case extendWorkAfterFinish
}

enum TBSettingValue: Codable, Equatable {
    case int(Int)
    case bool(Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case int
        case bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let value):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct TBSettingChanged: Codable, Equatable {
    let key: TBSettingKey
    let value: TBSettingValue
}

struct TBPresetUpserted: Codable, Equatable {
    let preset: NamedTimerPreset
}

struct TBPresetDeleted: Codable, Equatable {
    let presetID: UUID
}

struct TBPresetSelected: Codable, Equatable {
    let presetID: UUID
}

struct TBPresetOrderChanged: Codable, Equatable {
    let presetIDs: [UUID]
}

enum TBTimerSessionKind: String, Codable, Equatable {
    case work
    case shortRest
    case longRest

    var statsKind: TBStatsIntervalKind {
        switch self {
        case .work: return .work
        case .shortRest: return .shortRest
        case .longRest: return .longRest
        }
    }
}

struct TBTimerStarted: Codable, Equatable {
    let sessionID: UUID
    let setID: UUID
    let kind: TBTimerSessionKind
    let startedAt: Date
    let plannedDuration: TimeInterval
    let preset: TimerPresetSnapshot
    let workIntervalIndex: Int
}

struct TBTimerPaused: Codable, Equatable {
    let sessionID: UUID
    let pausedAt: Date
}

struct TBTimerResumed: Codable, Equatable {
    let sessionID: UUID
    let resumedAt: Date
}

struct TBTimerStopped: Codable, Equatable {
    let sessionID: UUID
    let stoppedAt: Date
}

struct TBTimerSkipped: Codable, Equatable {
    let sessionID: UUID
    let skippedAt: Date
}

struct TBTimerCompleted: Codable, Equatable {
    let sessionID: UUID
    let completedAt: Date
}

struct TBActiveTimerSessionPersisted: Codable, Equatable {
    let session: PersistedTimerSession
}

struct TBActiveTimerSessionCleared: Codable, Equatable {
    let clearedAt: Date
}

struct TBStatsRecordAppended: Codable, Equatable {
    let record: TBSessionRecord
}

struct TBDevicePaired: Codable, Equatable {
    let deviceID: String
    let displayName: String
    let platform: String
    let pairedAt: Date
}

struct TBDeviceRenamed: Codable, Equatable {
    let deviceID: String
    let displayName: String
    let renamedAt: Date
}

struct TBDeviceRemoved: Codable, Equatable {
    let deviceID: String
    let removedAt: Date
}

enum TBEventCommand: Equatable {
    case changeSetting(TBSettingKey, TBSettingValue)
    case upsertPreset(NamedTimerPreset)
    case deletePreset(UUID)
    case selectPreset(UUID)
    case changePresetOrder([UUID])
    case startTimer(TBTimerStarted)
    case pauseTimer(UUID, Date)
    case resumeTimer(UUID, Date)
    case stopTimer(UUID, Date)
    case skipTimer(UUID, Date)
    case completeTimer(UUID, Date)
}

final class TBJSONLEventStore {
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let supportedSchemaVersion: Int

    init(fileURL: URL, supportedSchemaVersion: Int = TBEventSchemaVersion) {
        self.fileURL = fileURL
        self.supportedSchemaVersion = supportedSchemaVersion
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    convenience init(supportedSchemaVersion: Int = TBEventSchemaVersion) {
        self.init(fileURL: Self.defaultFileURL(), supportedSchemaVersion: supportedSchemaVersion)
    }

    func append(_ envelope: TBEventEnvelope) throws {
        try appendLine(for: envelope)
    }

    func append(contentsOf envelopes: [TBEventEnvelope]) throws {
        var seenIDs = Set(try load().map(\.eventID))
        for envelope in TBEventProjector.canonicalize(envelopes) where !seenIDs.contains(envelope.eventID) {
            try appendLine(for: envelope)
            seenIDs.insert(envelope.eventID)
        }
    }

    func load() throws -> [TBEventEnvelope] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let decoded = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> TBEventEnvelope? in
            guard let data = String(line).data(using: .utf8),
                  let probe = try? decoder.decode(SchemaProbe.self, from: data),
                  probe.schemaVersion <= supportedSchemaVersion else {
                return nil
            }
            return try? decoder.decode(TBEventEnvelope.self, from: data)
        }
        return TBEventProjector.canonicalize(decoded)
    }

    private func appendLine(for envelope: TBEventEnvelope) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let data = try encoder.encode(envelope) + Data([0x0A])
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("tomatt", isDirectory: true)
        return baseURL.appendingPathComponent("events.jsonl")
    }
}

final class TBLocalEventLog {
    private let store: TBJSONLEventStore
    private let identity: TBDeviceIdentity?
    private(set) var envelopes: [TBEventEnvelope]
    var onLocalSyncableEventAppended: (() -> Void)?

    init(store: TBJSONLEventStore = TBJSONLEventStore(),
         identityStore: TBDeviceIdentityStoring = TBFileDeviceIdentityStore()) {
        self.store = store
        do {
            identity = try TBDeviceIdentityProvider.loadOrCreate(store: identityStore)
        } catch {
            identity = nil
            print("cannot load stable device identity: \(error)")
        }
        envelopes = (try? store.load()) ?? []
    }

    init(store: TBJSONLEventStore, identity: TBDeviceIdentity) {
        self.store = store
        self.identity = identity
        envelopes = (try? store.load()) ?? []
    }

    var projection: TBEventProjectionState {
        TBEventProjector.project(envelopes)
    }

    func reloadFromStore() {
        envelopes = (try? store.load()) ?? envelopes
    }

    func append(_ event: TBEvent) {
        reloadFromStore()
        guard let envelope = TBEventEnvelopeFactory.makeLocal(event: event,
                                                               existingEnvelopes: envelopes,
                                                               identity: identity) else {
            print("cannot write syncable event without stable device identity")
            return
        }
        do {
            try store.append(envelope)
            envelopes = TBEventProjector.canonicalize(envelopes + [envelope])
            if event.isSyncable {
                onLocalSyncableEventAppended?()
            }
        } catch {
            print("cannot write event: \(error)")
        }
    }

    func seedDefaultPresetsIfEmpty(_ presets: [NamedTimerPreset]) {
        reloadFromStore()
        guard TBEventProjector.project(envelopes).presets.isEmpty else { return }
        for preset in presets {
            append(.presetUpserted(TBPresetUpserted(preset: preset)))
        }
        if let firstPreset = presets.first {
            append(.presetSelected(TBPresetSelected(presetID: firstPreset.id)))
        }
    }

    func syncSummary() -> [String: Int64] {
        TBAntiEntropy.syncSummary(for: envelopes)
    }

    func missingEvents(relativeTo summary: [String: Int64]) -> [TBEventEnvelope] {
        TBAntiEntropy.missingEvents(in: envelopes, relativeTo: summary)
    }

    func importEvents(_ remoteEvents: [TBEventEnvelope]) -> TBImportResult {
        reloadFromStore()
        let existingIDs = Set(envelopes.map(\.eventID))
        var mergedEvents = envelopes
        let result = TBAntiEntropy.importEvents(remoteEvents, into: &mergedEvents)
        let acceptedEvents = mergedEvents.filter { !existingIDs.contains($0.eventID) }
        do {
            try store.append(contentsOf: acceptedEvents)
            envelopes = (try? store.load()) ?? mergedEvents
        } catch {
            print("cannot write imported events: \(error)")
            var failedResult = result
            failedResult.rejected += acceptedEvents.count
            failedResult.imported = 0
            failedResult.persistenceFailed = true
            return failedResult
        }
        return result
    }
}

struct TBImportResult: Equatable {
    var imported = 0
    var duplicate = 0
    var rejected = 0
    var collision = 0
    var persistenceFailed = false
}

enum TBAntiEntropy {
    static func syncSummary(for envelopes: [TBEventEnvelope]) -> [String: Int64] {
        let grouped = Dictionary(grouping: syncableV2(envelopes)) { $0.originDeviceID! }
        return grouped.mapValues { deviceEvents in
            let sequences = Set(deviceEvents.compactMap(\.deviceSequence))
            var cursor: Int64 = 0
            while sequences.contains(cursor + 1) {
                cursor += 1
            }
            return cursor
        }.filter { $0.value > 0 }
    }

    static func missingEvents(in envelopes: [TBEventEnvelope], relativeTo summary: [String: Int64]) -> [TBEventEnvelope] {
        TBEventProjector.canonicalize(syncableV2(envelopes).filter { envelope in
            guard let origin = envelope.originDeviceID,
                  let deviceSequence = envelope.deviceSequence else { return false }
            return deviceSequence > (summary[origin] ?? 0)
        })
    }

    static func importEvents(_ remoteEvents: [TBEventEnvelope], into localEvents: inout [TBEventEnvelope]) -> TBImportResult {
        var result = TBImportResult()
        var byEventID = Dictionary(uniqueKeysWithValues: localEvents.map { ($0.eventID, $0) })
        var byOriginSequence: [String: TBEventEnvelope] = [:]
        for envelope in syncableV2(localEvents) {
            if let origin = envelope.originDeviceID, let deviceSequence = envelope.deviceSequence {
                byOriginSequence["\(origin):\(deviceSequence)"] = envelope
            }
        }

        for event in TBEventProjector.sort(remoteEvents) {
            guard event.schemaVersion == TBEventSchemaVersion,
                  event.event.isSyncable,
                  let originDeviceID = event.originDeviceID,
                  let deviceSequence = event.deviceSequence,
                  deviceSequence > 0,
                  event.eventID == TBSyncEventID.derive(originDeviceID: originDeviceID,
                                                        deviceSequence: deviceSequence) else {
                result.rejected += 1
                continue
            }
            if let existing = byEventID[event.eventID] {
                if payloadMatches(existing, event) {
                    result.duplicate += 1
                } else {
                    result.collision += 1
                }
                continue
            }
            let originSequenceKey = "\(originDeviceID):\(deviceSequence)"
            if let existing = byOriginSequence[originSequenceKey], existing.eventID != event.eventID {
                result.collision += 1
                continue
            }
            localEvents.append(event)
            byEventID[event.eventID] = event
            byOriginSequence[originSequenceKey] = event
            result.imported += 1
        }
        localEvents = TBEventProjector.canonicalize(localEvents)
        return result
    }

    private static func syncableV2(_ envelopes: [TBEventEnvelope]) -> [TBEventEnvelope] {
        envelopes.filter { envelope in
            envelope.schemaVersion == TBEventSchemaVersion &&
                envelope.event.isSyncable &&
                envelope.originDeviceID != nil &&
                envelope.deviceSequence != nil
        }
    }

    private static func payloadMatches(_ lhs: TBEventEnvelope, _ rhs: TBEventEnvelope) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else { return false }
        return lhsData == rhsData
    }
}

struct TBSettingsProjection: Equatable {
    var preset = TimerPreset()
    var pauseAfterRestFinish = false
    var extendWorkAfterFinish = false
}

enum TBProjectedTimerStatus: Equatable {
    case idle
    case running
    case paused
}

struct TBProjectedTimerSession: Equatable {
    let sessionID: UUID
    let setID: UUID
    let kind: TBTimerSessionKind
    let startedAt: Date
    let plannedDuration: TimeInterval
    let preset: TimerPresetSnapshot
    let workIntervalIndex: Int
    var status: TBProjectedTimerStatus
    var pausedAt: Date?
    var pausedDuration: TimeInterval
}

struct TBProjectedStatsRecord: Identifiable, Equatable {
    let id: UUID
    let kind: TBStatsIntervalKind
    let startedAt: Date
    let endedAt: Date
    let plannedDuration: TimeInterval
    let activeDuration: TimeInterval
    let pausedDuration: TimeInterval
    let completion: TBStatsCompletion
    let preset: TimerPresetSnapshot
    let workIntervalIndex: Int
    let overtimeDuration: TimeInterval
}

struct TBProjectedDevice: Identifiable, Equatable {
    var id: String { deviceID }
    let deviceID: String
    var displayName: String
    var platform: String
    var pairedAt: Date
}

struct TBEventProjectionState: Equatable {
    var settings = TBSettingsProjection()
    var presets: [NamedTimerPreset] = []
    var selectedPresetID: UUID?
    var stats: [TBSessionRecord] = []
    var timer: TBProjectedTimerSession?
    var activeTimerSession: PersistedTimerSession?
    var pairedDevices: [TBProjectedDevice] = []
    var distributedTimer = TBDistributedTimerProjection()
}

struct TBDistributedTimerProjection: Equatable {
    var branches: [TBTimerBranchProjection] = []
    var visibleSessionIDs: Set<UUID> = []
    var losingSessionIDs: Set<UUID> = []
    var currentTimer: TBProjectedTimerSession?
}

struct TBTimerBranchProjection: Identifiable, Equatable {
    var id: UUID { sessionID }
    let sessionID: UUID
    let startEnvelope: TBEventEnvelope
    let started: TBTimerStarted
    let intervalStart: Date
    let intervalEnd: Date?
    let terminalAt: Date?
    let isVisible: Bool
    let timer: TBProjectedTimerSession?
}

struct TBVisibleTimerState: Equatable {
    let sessionID: UUID?
    let status: TBProjectedTimerStatus?
    let kind: TBTimerSessionKind?
    let startedAt: Date?
    let plannedDuration: TimeInterval?
    let pausedAt: Date?
    let pausedDuration: TimeInterval?

    init(_ state: TBEventProjectionState) {
        sessionID = state.timer?.sessionID
        status = state.timer?.status
        kind = state.timer?.kind
        startedAt = state.timer?.startedAt
        plannedDuration = state.timer?.plannedDuration
        pausedAt = state.timer?.pausedAt
        pausedDuration = state.timer?.pausedDuration
    }
}

struct TBTimerSyncCorrectionNotice: Equatable {
    let message: String
}

enum TBTimerSyncCorrectionNoticeFactory {
    static func notice(before: TBEventProjectionState,
                       after: TBEventProjectionState,
                       trustedDeviceName: String) -> TBTimerSyncCorrectionNotice? {
        guard TBVisibleTimerState(before) != TBVisibleTimerState(after) else { return nil }
        return TBTimerSyncCorrectionNotice(message: "Timer updated after syncing with \(trustedDeviceName).")
    }
}

enum TBEventProjector {
    static func project(_ envelopes: [TBEventEnvelope]) -> TBEventProjectionState {
        let events = canonicalize(envelopes)
        var state = events.reduce(into: TBEventProjectionState()) { state, envelope in
            apply(envelope.event, recordedAt: envelope.recordedAt, to: &state)
        }
        applyDistributedTimerProjection(from: events, to: &state)
        return state
    }

    static func canonicalize(_ envelopes: [TBEventEnvelope]) -> [TBEventEnvelope] {
        var seenIDs = Set<UUID>()
        return sort(envelopes).filter { envelope in
            seenIDs.insert(envelope.eventID).inserted
        }
    }

    static func sort(_ envelopes: [TBEventEnvelope]) -> [TBEventEnvelope] {
        envelopes.sorted { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
            let lhsOrigin = lhs.originDeviceID ?? lhs.streamID
            let rhsOrigin = rhs.originDeviceID ?? rhs.streamID
            if lhsOrigin != rhsOrigin { return lhsOrigin < rhsOrigin }
            let lhsSequence = lhs.deviceSequence ?? lhs.sequence
            let rhsSequence = rhs.deviceSequence ?? rhs.sequence
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            return lhs.eventID.uuidString < rhs.eventID.uuidString
        }
    }

    private static func apply(_ event: TBEvent, recordedAt _: Date, to state: inout TBEventProjectionState) {
        switch event {
        case .settingChanged(let change):
            apply(change, to: &state.settings)
        case .presetUpserted(let upsert):
            if let index = state.presets.firstIndex(where: { $0.id == upsert.preset.id }) {
                state.presets[index] = upsert.preset
            } else {
                state.presets.append(upsert.preset)
            }
        case .presetDeleted(let deletion):
            state.presets.removeAll { $0.id == deletion.presetID }
            if state.selectedPresetID == deletion.presetID {
                state.selectedPresetID = state.presets.first?.id
            }
        case .presetSelected(let selection):
            if state.presets.contains(where: { $0.id == selection.presetID }) {
                state.selectedPresetID = selection.presetID
            }
        case .presetOrderChanged(let order):
            state.presets = orderedPresets(state.presets, by: order.presetIDs)
        case .timerStarted(let start):
            state.timer = TBProjectedTimerSession(sessionID: start.sessionID,
                                                 setID: start.setID,
                                                 kind: start.kind,
                                                 startedAt: start.startedAt,
                                                 plannedDuration: start.plannedDuration,
                                                 preset: start.preset,
                                                 workIntervalIndex: start.workIntervalIndex,
                                                 status: .running,
                                                 pausedAt: nil,
                                                 pausedDuration: 0)
        case .timerPaused(let pause):
            guard state.timer?.sessionID == pause.sessionID,
                  state.timer?.status == .running else { return }
            state.timer?.status = .paused
            state.timer?.pausedAt = pause.pausedAt
        case .timerResumed(let resume):
            guard state.timer?.sessionID == resume.sessionID,
                  state.timer?.status == .paused else { return }
            if let pausedAt = state.timer?.pausedAt {
                state.timer?.pausedDuration += max(0, resume.resumedAt.timeIntervalSince(pausedAt))
            }
            state.timer?.status = .running
            state.timer?.pausedAt = nil
        case .timerStopped(let stop):
            finishTimer(sessionID: stop.sessionID,
                        endedAt: stop.stoppedAt,
                        completion: .stopped,
                        state: &state)
        case .timerSkipped(let skip):
            finishTimer(sessionID: skip.sessionID,
                        endedAt: skip.skippedAt,
                        completion: .skipped,
                        state: &state)
        case .timerCompleted(let complete):
            finishTimer(sessionID: complete.sessionID,
                        endedAt: complete.completedAt,
                        completion: .completed,
                        state: &state)
        case .activeTimerSessionPersisted(let persisted):
            state.activeTimerSession = persisted.session
        case .activeTimerSessionCleared:
            state.activeTimerSession = nil
        case .statsRecordAppended(let appended):
            if let index = state.stats.firstIndex(where: { $0.id == appended.record.id }) {
                state.stats[index] = appended.record
            } else {
                state.stats.append(appended.record)
            }
        case .devicePaired(let paired):
            if let index = state.pairedDevices.firstIndex(where: { $0.deviceID == paired.deviceID }) {
                state.pairedDevices[index].displayName = paired.displayName
                state.pairedDevices[index].platform = paired.platform
                state.pairedDevices[index].pairedAt = paired.pairedAt
            } else {
                state.pairedDevices.append(TBProjectedDevice(deviceID: paired.deviceID,
                                                              displayName: paired.displayName,
                                                              platform: paired.platform,
                                                              pairedAt: paired.pairedAt))
            }
        case .deviceRenamed(let renamed):
            guard let index = state.pairedDevices.firstIndex(where: { $0.deviceID == renamed.deviceID }) else { return }
            state.pairedDevices[index].displayName = renamed.displayName
        case .deviceRemoved(let removed):
            state.pairedDevices.removeAll { $0.deviceID == removed.deviceID }
        }
    }

    private static func orderedPresets(_ presets: [NamedTimerPreset], by presetIDs: [UUID]) -> [NamedTimerPreset] {
        let byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        var usedIDs = Set<UUID>()
        var ordered = presetIDs.compactMap { id -> NamedTimerPreset? in
            guard let preset = byID[id], usedIDs.insert(id).inserted else { return nil }
            return preset
        }
        ordered.append(contentsOf: presets.filter { !usedIDs.contains($0.id) })
        return ordered
    }

    private static func apply(_ change: TBSettingChanged, to settings: inout TBSettingsProjection) {
        switch (change.key, change.value) {
        case (.workDurationMinutes, .int(let value)):
            settings.preset.workIntervalLength = value
        case (.shortRestDurationMinutes, .int(let value)):
            settings.preset.shortRestIntervalLength = value
        case (.longRestDurationMinutes, .int(let value)):
            settings.preset.longRestIntervalLength = value
        case (.workIntervalsPerSet, .int(let value)):
            settings.preset.workIntervalsInSet = value
        case (.pauseAfterRestFinish, .bool(let value)):
            settings.pauseAfterRestFinish = value
        case (.extendWorkAfterFinish, .bool(let value)):
            settings.extendWorkAfterFinish = value
        default:
            return
        }
        settings.preset = settings.preset.clamped()
    }

    private static func finishTimer(sessionID: UUID,
                                     endedAt _: Date,
                                     completion _: TBStatsCompletion,
                                     state: inout TBEventProjectionState) {
        guard state.timer?.sessionID == sessionID else { return }
        state.timer = nil
        if state.activeTimerSession?.sessionID == sessionID {
            state.activeTimerSession = nil
        }
    }

    private static func applyDistributedTimerProjection(from envelopes: [TBEventEnvelope],
                                                        to state: inout TBEventProjectionState) {
        let projection = distributedTimerProjection(from: envelopes)
        state.distributedTimer = projection
        state.timer = projection.currentTimer
        state.stats.removeAll { projection.losingSessionIDs.contains($0.id) }
        if let sessionID = state.activeTimerSession?.sessionID,
           projection.losingSessionIDs.contains(sessionID) {
            state.activeTimerSession = nil
        }
    }

    private static func distributedTimerProjection(from envelopes: [TBEventEnvelope]) -> TBDistributedTimerProjection {
        var starts: [UUID: TBEventEnvelope] = [:]
        for envelope in envelopes {
            if case .timerStarted(let start) = envelope.event,
               starts[start.sessionID] == nil {
                starts[start.sessionID] = envelope
            }
        }

        var branches = starts.values.compactMap { startEnvelope in
            timerBranch(startEnvelope: startEnvelope, envelopes: envelopes)
        }
        var losingSessionIDs = Set<UUID>()
        for candidate in branches {
            if branches.contains(where: { other in
                other.sessionID != candidate.sessionID &&
                    branchesOverlap(candidate, other) &&
                    branchSortPrecedes(other, candidate)
            }) {
                losingSessionIDs.insert(candidate.sessionID)
            }
        }
        branches = branches.map { branch in
            TBTimerBranchProjection(sessionID: branch.sessionID,
                                    startEnvelope: branch.startEnvelope,
                                    started: branch.started,
                                    intervalStart: branch.intervalStart,
                                    intervalEnd: branch.intervalEnd,
                                    terminalAt: branch.terminalAt,
                                    isVisible: !losingSessionIDs.contains(branch.sessionID),
                                    timer: losingSessionIDs.contains(branch.sessionID) ? nil : branch.timer)
        }.sorted { branchSortPrecedes($0, $1) }
        let visibleSessionIDs = Set(branches.filter(\.isVisible).map(\.sessionID))
        let currentTimer = branches
            .filter { $0.isVisible }
            .compactMap(\.timer)
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            .first
        return TBDistributedTimerProjection(branches: branches,
                                            visibleSessionIDs: visibleSessionIDs,
                                            losingSessionIDs: losingSessionIDs,
                                            currentTimer: currentTimer)
    }

    private static func timerBranch(startEnvelope: TBEventEnvelope,
                                    envelopes: [TBEventEnvelope]) -> TBTimerBranchProjection? {
        guard case .timerStarted(let start) = startEnvelope.event else { return nil }
        // Distributed conflict handling uses only synced lifecycle events. Local-only active-session
        // snapshots carry richer UI/runtime states such as rest-presentation-pending and work
        // extension/overtime flags, so those snapshots are intentionally not used to decide branch
        // winners until equivalent syncable lifecycle events exist. Without a terminal synced event,
        // the branch remains visible/open, preserving current timer, paused, pending-break, and
        // overtime visibility semantics across devices.
        var timer = TBProjectedTimerSession(sessionID: start.sessionID,
                                            setID: start.setID,
                                            kind: start.kind,
                                            startedAt: start.startedAt,
                                            plannedDuration: start.plannedDuration,
                                            preset: start.preset,
                                            workIntervalIndex: start.workIntervalIndex,
                                            status: .running,
                                            pausedAt: nil,
                                            pausedDuration: 0)
        var terminalAt: Date?
        for envelope in envelopes where timerLifecycleSessionID(envelope.event) == start.sessionID {
            switch envelope.event {
            case .timerStarted:
                continue
            case .timerPaused(let pause):
                guard terminalAt == nil, timer.status == .running else { continue }
                timer.status = .paused
                timer.pausedAt = pause.pausedAt
            case .timerResumed(let resume):
                guard terminalAt == nil, timer.status == .paused else { continue }
                if let pausedAt = timer.pausedAt {
                    timer.pausedDuration += max(0, resume.resumedAt.timeIntervalSince(pausedAt))
                }
                timer.status = .running
                timer.pausedAt = nil
            case .timerStopped(let stop):
                terminalAt = minTerminal(terminalAt, stop.stoppedAt)
            case .timerSkipped(let skip):
                terminalAt = minTerminal(terminalAt, skip.skippedAt)
            case .timerCompleted(let complete):
                terminalAt = minTerminal(terminalAt, complete.completedAt)
            default:
                continue
            }
        }
        let visibleTimer = terminalAt == nil ? timer : nil
        return TBTimerBranchProjection(sessionID: start.sessionID,
                                       startEnvelope: startEnvelope,
                                       started: start,
                                       intervalStart: start.startedAt,
                                       intervalEnd: terminalAt,
                                       terminalAt: terminalAt,
                                       isVisible: true,
                                       timer: visibleTimer)
    }

    private static func timerLifecycleSessionID(_ event: TBEvent) -> UUID? {
        switch event {
        case .timerStarted(let start): return start.sessionID
        case .timerPaused(let pause): return pause.sessionID
        case .timerResumed(let resume): return resume.sessionID
        case .timerStopped(let stop): return stop.sessionID
        case .timerSkipped(let skip): return skip.sessionID
        case .timerCompleted(let complete): return complete.sessionID
        default: return nil
        }
    }

    private static func minTerminal(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private static func branchesOverlap(_ lhs: TBTimerBranchProjection, _ rhs: TBTimerBranchProjection) -> Bool {
        let lhsEnd = lhs.intervalEnd ?? Date.distantFuture
        let rhsEnd = rhs.intervalEnd ?? Date.distantFuture
        return lhs.intervalStart < rhsEnd && rhs.intervalStart < lhsEnd
    }

    private static func branchSortPrecedes(_ lhs: TBTimerBranchProjection, _ rhs: TBTimerBranchProjection) -> Bool {
        if lhs.started.startedAt != rhs.started.startedAt { return lhs.started.startedAt < rhs.started.startedAt }
        if lhs.sessionID.uuidString != rhs.sessionID.uuidString { return lhs.sessionID.uuidString < rhs.sessionID.uuidString }
        let lhsOrigin = lhs.startEnvelope.originDeviceID ?? lhs.startEnvelope.streamID
        let rhsOrigin = rhs.startEnvelope.originDeviceID ?? rhs.startEnvelope.streamID
        if lhsOrigin != rhsOrigin { return lhsOrigin < rhsOrigin }
        let lhsSequence = lhs.startEnvelope.deviceSequence ?? lhs.startEnvelope.sequence
        let rhsSequence = rhs.startEnvelope.deviceSequence ?? rhs.startEnvelope.sequence
        if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
        return lhs.startEnvelope.eventID.uuidString < rhs.startEnvelope.eventID.uuidString
    }
}

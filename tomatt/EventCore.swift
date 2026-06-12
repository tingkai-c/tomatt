import Foundation

let TBEventSchemaVersion = 1

struct TBEventEnvelope: Codable, Equatable, Identifiable {
    var schemaVersion: Int
    var eventID: UUID
    var streamID: String
    var sequence: Int64
    var recordedAt: Date
    var event: TBEvent

    var id: UUID { eventID }


    init(schemaVersion: Int = TBEventSchemaVersion,
         eventID: UUID = UUID(),
         streamID: String,
         sequence: Int64,
         recordedAt: Date = Date(),
         event: TBEvent) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.streamID = streamID
        self.sequence = sequence
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
    private(set) var envelopes: [TBEventEnvelope]

    init(store: TBJSONLEventStore = TBJSONLEventStore()) {
        self.store = store
        envelopes = (try? store.load()) ?? []
    }

    var projection: TBEventProjectionState {
        TBEventProjector.project(envelopes)
    }

    func append(_ event: TBEvent) {
        envelopes = (try? store.load()) ?? envelopes
        let envelope = TBEventEnvelope(streamID: "local",
                                       sequence: nextSequence(),
                                       event: event)
        do {
            try store.append(envelope)
            envelopes = TBEventProjector.canonicalize(envelopes + [envelope])
        } catch {
            print("cannot write event: \(error)")
        }
    }

    func seedDefaultPresetsIfEmpty(_ presets: [NamedTimerPreset]) {
        envelopes = (try? store.load()) ?? envelopes
        guard TBEventProjector.project(envelopes).presets.isEmpty else { return }
        for preset in presets {
            append(.presetUpserted(TBPresetUpserted(preset: preset)))
        }
        if let firstPreset = presets.first {
            append(.presetSelected(TBPresetSelected(presetID: firstPreset.id)))
        }
    }

    private func nextSequence() -> Int64 {
        (envelopes.map(\.sequence).max() ?? 0) + 1
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

struct TBEventProjectionState: Equatable {
    var settings = TBSettingsProjection()
    var presets: [NamedTimerPreset] = []
    var selectedPresetID: UUID?
    var stats: [TBSessionRecord] = []
    var timer: TBProjectedTimerSession?
    var activeTimerSession: PersistedTimerSession?
}

enum TBEventProjector {
    static func project(_ envelopes: [TBEventEnvelope]) -> TBEventProjectionState {
        canonicalize(envelopes).reduce(into: TBEventProjectionState()) { state, envelope in
            apply(envelope.event, recordedAt: envelope.recordedAt, to: &state)
        }
    }

    static func canonicalize(_ envelopes: [TBEventEnvelope]) -> [TBEventEnvelope] {
        var seenIDs = Set<UUID>()
        return envelopes.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.recordedAt < rhs.recordedAt
            }
            return lhs.sequence < rhs.sequence
        }.filter { envelope in
            seenIDs.insert(envelope.eventID).inserted
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
}

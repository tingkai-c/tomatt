import Foundation

// Core timer values live outside TBTimer so state decisions can be tested without
// constructing AppKit, notification, audio, status-item, or DispatchSourceTimer side effects.
struct TimerPreset: Codable, Equatable {
    var workIntervalLength = 25
    var shortRestIntervalLength = 5
    var longRestIntervalLength = 15
    var workIntervalsInSet = 4
}

struct NamedTimerPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var preset: TimerPreset

    init(id: UUID = UUID(), name: String, preset: TimerPreset) {
        self.id = id
        self.name = name
        self.preset = preset.clamped()
    }
}

enum TBStatsIntervalKind: String, Codable {
    case work
    case shortRest
    case longRest

    var isBreak: Bool {
        self == .shortRest || self == .longRest
    }
}

enum TBStatsCompletion: String, Codable {
    case completed
    case skipped
    case stopped
    case abandoned
}

struct TimerPresetSnapshot: Codable, Equatable {
    let workIntervalLength: Int
    let shortRestIntervalLength: Int
    let longRestIntervalLength: Int
    let workIntervalsInSet: Int

    init(preset: TimerPreset) {
        workIntervalLength = preset.workIntervalLength
        shortRestIntervalLength = preset.shortRestIntervalLength
        longRestIntervalLength = preset.longRestIntervalLength
        workIntervalsInSet = preset.workIntervalsInSet
    }
}

struct PersistedTimerSession: Codable, Equatable {
    var schemaVersion = 1
    var state: TBStateMachineStates
    var preset: TimerPreset
    var currentWorkInterval: Int
    var kind: TBStatsIntervalKind
    var plannedDuration: TimeInterval
    var startedAt: Date
    var finishAt: Date
    var pauseStartedAt: Date?
    var pausedTimeRemaining: TimeInterval
    var pausedDuration: TimeInterval
    var workExtensionActive: Bool
    var workLimitNotificationSent: Bool
    var restPresentationPending: Bool
    var workStartPending: Bool? = nil
    var workFinishedPendingBreak: Bool? = nil
    var sessionID: UUID? = nil
    var setID: UUID? = nil
}

struct TimerCoreSettings: Equatable {
    var pauseAfterRestFinish: Bool
    var extendWorkAfterFinish: Bool

    init(pauseAfterRestFinish: Bool = false,
         extendWorkAfterFinish: Bool = false) {
        self.pauseAfterRestFinish = pauseAfterRestFinish
        self.extendWorkAfterFinish = extendWorkAfterFinish
    }
}

enum TimerRestoreAction: Equatable {
    case discard
    case running(remaining: TimeInterval)
    case paused(remaining: TimeInterval)
    case fireExpired
    case workFinishedBoundary
}

struct TimerRestoreDecision: Equatable {
    let state: TBStateMachineStates
    let action: TimerRestoreAction
}

enum TimerControlMode: Equatable {
    case inactive
    case workRunning
    case workPaused
    case workExtended
    case workFinishedPendingBreak
    case restRunning
    case restPaused
    case workStartPending
}

enum TimerCore {
    static func transition(from state: TBStateMachineStates,
                           event: TBStateMachineEvents,
                           settings: TimerCoreSettings,
                           currentWorkInterval: Int,
                           preset: TimerPreset,
                           workExtensionActive: Bool = false,
                           workFinishedPendingBreak: Bool = false) -> TBStateMachineStates? {
        switch event {
        case .startStop:
            switch state {
            case .idle:
                return .work
            case .work, .rest, .workPaused, .restPaused:
                return .idle
            }
        case .pauseResume:
            switch state {
            case .work:
                return .workPaused
            case .rest:
                return .restPaused
            case .workPaused:
                return .work
            case .restPaused:
                return .rest
            case .idle:
                return nil
            }
        case .startBreak:
            switch state {
            case .work, .workPaused:
                return workExtensionActive || workFinishedPendingBreak ? .rest : nil
            case .idle, .rest, .restPaused:
                return nil
            }
        case .restoreWork:
            return state == .idle ? .work : nil
        case .restoreRest:
            return state == .idle ? .rest : nil
        case .restoreWorkPaused:
            return state == .idle ? .workPaused : nil
        case .restoreRestPaused:
            return state == .idle ? .restPaused : nil
        case .timerFired:
            switch state {
            case .work:
                if workFinishedPendingBreak || settings.extendWorkAfterFinish {
                    return nil
                }
                return .rest
            case .rest:
                if isCurrentRestLongRest(currentWorkInterval: currentWorkInterval,
                                         preset: preset) {
                    return .idle
                }
                return settings.pauseAfterRestFinish ? .workPaused : .work
            case .idle, .workPaused, .restPaused:
                return nil
            }
        case .skipEvent:
            switch state {
            case .work, .workPaused:
                return .rest
            case .rest, .restPaused:
                return isCurrentRestLongRest(currentWorkInterval: currentWorkInterval,
                                             preset: preset) ? .idle : .work
            case .idle:
                return nil
            }
        }
    }

    static func isCurrentRestLongRest(currentWorkInterval: Int, preset: TimerPreset) -> Bool {
        currentWorkInterval >= preset.clamped().workIntervalsInSet
    }

    static func shouldExtendWorkSessionAtLimit(extendWorkAfterFinish: Bool) -> Bool {
        extendWorkAfterFinish
    }

    static func controlMode(timerActive: Bool,
                            state: TBStateMachineStates,
                            paused: Bool,
                            workExtensionActive: Bool,
                            workStartPending: Bool,
                            workFinishedPendingBreak: Bool) -> TimerControlMode {
        guard timerActive else { return .inactive }
        switch state {
        case .idle:
            return .inactive
        case .work where workExtensionActive:
            return .workExtended
        case .work where workFinishedPendingBreak:
            return .workFinishedPendingBreak
        case .work:
            return .workRunning
        case .workPaused where workStartPending:
            return .workStartPending
        case .workPaused:
            return paused ? .workPaused : .workRunning
        case .rest:
            return .restRunning
        case .restPaused:
            return .restPaused
        }
    }

    static func clockString(from duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func overtimeClockString(from duration: TimeInterval) -> String {
        "+\(clockString(from: duration))"
    }

    static func restoreDecision(for session: PersistedTimerSession,
                                now: Date,
                                settings: TimerCoreSettings) -> TimerRestoreDecision {
        guard isValidPersistedSession(session, now: now) else {
            return TimerRestoreDecision(state: .idle, action: .discard)
        }

        switch session.state {
        case .work:
            let remaining = session.finishAt.timeIntervalSince(now)
            if remaining > 0 {
                return TimerRestoreDecision(state: .work, action: .running(remaining: remaining))
            }
            if session.workFinishedPendingBreak ?? false || session.workExtensionActive {
                return TimerRestoreDecision(state: .work, action: .workFinishedBoundary)
            }
            if shouldExtendWorkSessionAtLimit(extendWorkAfterFinish: settings.extendWorkAfterFinish) {
                return TimerRestoreDecision(state: .work, action: .workFinishedBoundary)
            }
            return TimerRestoreDecision(state: .work, action: .fireExpired)
        case .rest:
            let remaining = session.finishAt.timeIntervalSince(now)
            if remaining > 0 {
                return TimerRestoreDecision(state: .rest, action: .running(remaining: remaining))
            }
            return TimerRestoreDecision(state: .rest, action: .fireExpired)
        case .workPaused, .restPaused:
            return TimerRestoreDecision(state: session.state,
                                        action: .paused(remaining: max(0, session.pausedTimeRemaining)))
        case .idle:
            return TimerRestoreDecision(state: .idle, action: .discard)
        }
    }

    static func isValidPersistedSession(_ session: PersistedTimerSession, now: Date) -> Bool {
        let restoredPausedDuration = restoredPausedDuration(for: session, now: now)

        guard session.state != .idle,
              isKindValid(session.kind, for: session.state),
              session.plannedDuration.isFinite,
              session.plannedDuration > 0,
              session.pausedTimeRemaining.isFinite,
              session.pausedTimeRemaining >= 0,
              session.pausedTimeRemaining <= session.plannedDuration,
              session.pausedDuration.isFinite,
              session.pausedDuration >= 0,
              session.startedAt.timeIntervalSinceReferenceDate.isFinite,
              session.finishAt.timeIntervalSinceReferenceDate.isFinite,
              session.startedAt <= now,
              session.finishAt >= session.startedAt,
              isValidFinishAnchor(for: session, now: now, restoredPausedDuration: restoredPausedDuration),
              session.currentWorkInterval >= 1,
              session.currentWorkInterval <= session.preset.clamped().workIntervalsInSet else {
            return false
        }

        if let pauseStartedAt = session.pauseStartedAt {
            guard session.state == .workPaused || session.state == .restPaused,
                  pauseStartedAt >= session.startedAt,
                  pauseStartedAt <= now else {
                return false
            }
        }

        if session.workFinishedPendingBreak ?? false || session.workExtensionActive {
            guard session.state == .work,
                  session.finishAt <= now,
                  session.pauseStartedAt == nil,
                  session.pausedTimeRemaining == 0 else {
                return false
            }
        }

        let wallDuration = max(0, now.timeIntervalSince(session.startedAt))
        return restoredPausedDuration <= wallDuration + 1
    }


    private static func isValidFinishAnchor(for session: PersistedTimerSession,
                                            now: Date,
                                            restoredPausedDuration: TimeInterval) -> Bool {
        let finishOffset = session.finishAt.timeIntervalSince(session.startedAt)
        if finishOffset <= session.plannedDuration + restoredPausedDuration + 1 {
            return true
        }

        let isFinishedWorkBoundary = session.state == .work
            && (session.workFinishedPendingBreak ?? false || session.workExtensionActive)
            && session.finishAt <= now
        return isFinishedWorkBoundary
    }

    static func restoredPausedDuration(for session: PersistedTimerSession, now: Date) -> TimeInterval {
        var pausedDuration = session.pausedDuration
        if let pauseStartedAt = session.pauseStartedAt {
            pausedDuration += max(0, now.timeIntervalSince(pauseStartedAt))
        }
        return pausedDuration
    }

    static func isKindValid(_ kind: TBStatsIntervalKind, for state: TBStateMachineStates) -> Bool {
        switch state {
        case .work, .workPaused:
            return kind == .work
        case .rest, .restPaused:
            return kind.isBreak
        case .idle:
            return false
        }
    }
}

extension TimerPreset {
    static let firstStartupDefault = TimerPreset(workIntervalLength: 30,
                                                shortRestIntervalLength: 5,
                                                longRestIntervalLength: 15,
                                                workIntervalsInSet: 4)

    func clamped() -> TimerPreset {
        TimerPreset(workIntervalLength: Self.clamp(workIntervalLength, to: 1 ... 120),
                    shortRestIntervalLength: Self.clamp(shortRestIntervalLength, to: 1 ... 120),
                    longRestIntervalLength: Self.clamp(longRestIntervalLength, to: 1 ... 120),
                    workIntervalsInSet: Self.clamp(workIntervalsInSet, to: 1 ... 10))
    }

    private static func clamp<T: Comparable>(_ value: T, to limits: ClosedRange<T>) -> T {
        min(max(value, limits.lowerBound), limits.upperBound)
    }
}

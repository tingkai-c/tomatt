import Foundation

// Core timer values live outside TBTimer so state decisions can be tested without
// constructing AppKit, notification, audio, status-item, or DispatchSourceTimer side effects.
enum StopAfterOption: String, CaseIterable, Codable {
    case disabled, work, rest, set
}

struct TimerPreset: Codable, Equatable {
    var workIntervalLength = 25
    var shortRestIntervalLength = 5
    var longRestIntervalLength = 15
    var workIntervalsInSet = 4
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
}

struct TimerCoreSettings: Equatable {
    var stopAfter: StopAfterOption
    var pauseAfterWorkFinish: Bool
    var pauseAfterRestFinish: Bool
    var extendWorkAfterFinish: Bool

    init(stopAfter: StopAfterOption = .disabled,
         pauseAfterWorkFinish: Bool = false,
         pauseAfterRestFinish: Bool = false,
         extendWorkAfterFinish: Bool = false) {
        self.stopAfter = stopAfter
        self.pauseAfterWorkFinish = pauseAfterWorkFinish
        self.pauseAfterRestFinish = pauseAfterRestFinish
        self.extendWorkAfterFinish = extendWorkAfterFinish
    }
}

enum TimerRestoreAction: Equatable {
    case discard
    case running(remaining: TimeInterval)
    case paused(remaining: TimeInterval)
    case fireExpired
    case extendExpiredWork
}

struct TimerRestoreDecision: Equatable {
    let state: TBStateMachineStates
    let action: TimerRestoreAction
}

enum TimerCore {
    static func transition(from state: TBStateMachineStates,
                           event: TBStateMachineEvents,
                           settings: TimerCoreSettings,
                           currentWorkInterval: Int,
                           preset: TimerPreset) -> TBStateMachineStates? {
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
                if settings.stopAfter == .work {
                    return .idle
                }
                if settings.extendWorkAfterFinish {
                    return nil
                }
                return settings.pauseAfterWorkFinish ? .restPaused : .rest
            case .rest:
                if shouldStopAfterRest(stopAfter: settings.stopAfter,
                                       currentWorkInterval: currentWorkInterval,
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
                return settings.stopAfter == .work ? .idle : .rest
            case .rest, .restPaused:
                return shouldStopAfterRest(stopAfter: settings.stopAfter,
                                           currentWorkInterval: currentWorkInterval,
                                           preset: preset) ? .idle : .work
            case .idle:
                return nil
            }
        }
    }

    static func shouldStopAfterRest(stopAfter: StopAfterOption,
                                    currentWorkInterval: Int,
                                    preset: TimerPreset) -> Bool {
        stopAfter == .rest || (stopAfter == .set && isCurrentRestLongRest(currentWorkInterval: currentWorkInterval,
                                                                         preset: preset))
    }

    static func isCurrentRestLongRest(currentWorkInterval: Int, preset: TimerPreset) -> Bool {
        currentWorkInterval >= preset.clamped().workIntervalsInSet
    }

    static func shouldExtendWorkSessionAtLimit(extendWorkAfterFinish: Bool,
                                               stopAfter: StopAfterOption) -> Bool {
        extendWorkAfterFinish && stopAfter != .work
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
            if shouldExtendWorkSessionAtLimit(extendWorkAfterFinish: settings.extendWorkAfterFinish,
                                               stopAfter: settings.stopAfter) {
                return TimerRestoreDecision(state: .work, action: .extendExpiredWork)
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
              session.finishAt.timeIntervalSince(session.startedAt) <= session.plannedDuration + restoredPausedDuration + 1,
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

        let wallDuration = max(0, now.timeIntervalSince(session.startedAt))
        return restoredPausedDuration <= wallDuration + 1
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
    func clamped() -> TimerPreset {
        TimerPreset(workIntervalLength: workIntervalLength.clamped(to: 1 ... 120),
                    shortRestIntervalLength: shortRestIntervalLength.clamped(to: 1 ... 120),
                    longRestIntervalLength: longRestIntervalLength.clamped(to: 1 ... 120),
                    workIntervalsInSet: workIntervalsInSet.clamped(to: 1 ... 10))
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

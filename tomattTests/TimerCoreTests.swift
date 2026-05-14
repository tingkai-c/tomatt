import XCTest

final class TimerCoreTests: XCTestCase {
    private let preset = TimerPreset(workIntervalLength: 25,
                                     shortRestIntervalLength: 5,
                                     longRestIntervalLength: 15,
                                     workIntervalsInSet: 4)

    func testAutoPauseTransitionsAfterWorkAndRest() {
        let workPause = TimerCoreSettings(pauseAfterWorkFinish: true)
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .timerFired,
                                            settings: workPause,
                                            currentWorkInterval: 1,
                                            preset: preset), .restPaused)

        let restPause = TimerCoreSettings(pauseAfterRestFinish: true)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .timerFired,
                                            settings: restPause,
                                            currentWorkInterval: 1,
                                            preset: preset), .workPaused)
    }

    func testDisabledAutoPauseContinuesToActiveIntervals() {
        let settings = TimerCoreSettings()
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .timerFired,
                                            settings: settings,
                                            currentWorkInterval: 1,
                                            preset: preset), .rest)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .timerFired,
                                            settings: settings,
                                            currentWorkInterval: 1,
                                            preset: preset), .work)
    }

    func testSkipAndStopAfterBoundaries() {
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(stopAfter: .work),
                                            currentWorkInterval: 1,
                                            preset: preset), .idle)
        XCTAssertEqual(TimerCore.transition(from: .workPaused,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .rest)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(stopAfter: .rest),
                                            currentWorkInterval: 1,
                                            preset: preset), .idle)
        XCTAssertEqual(TimerCore.transition(from: .restPaused,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(stopAfter: .set),
                                            currentWorkInterval: 4,
                                            preset: preset), .idle)
    }

    func testPauseResumeAndStartStopControls() {
        XCTAssertEqual(TimerCore.transition(from: .idle,
                                            event: .startStop,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 0,
                                            preset: preset), .work)
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .pauseResume,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .workPaused)
        XCTAssertEqual(TimerCore.transition(from: .workPaused,
                                            event: .pauseResume,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .work)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .startStop,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .idle)
    }

    func testRestoreDecisionForRunningPausedExpiredAndInvalidSessions() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let runningWork = session(state: .work,
                                  kind: .work,
                                  startedAt: now.addingTimeInterval(-100),
                                  finishAt: now.addingTimeInterval(200),
                                  plannedDuration: 300)
        XCTAssertEqual(TimerCore.restoreDecision(for: runningWork,
                                                 now: now,
                                                 settings: TimerCoreSettings()),
                       TimerRestoreDecision(state: .work, action: .running(remaining: 200)))

        let pausedRest = session(state: .restPaused,
                                 kind: .shortRest,
                                 startedAt: now.addingTimeInterval(-50),
                                 finishAt: now.addingTimeInterval(250),
                                 plannedDuration: 300,
                                 pausedTimeRemaining: 180,
                                 pausedDuration: 20,
                                 pauseStartedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(TimerCore.restoreDecision(for: pausedRest,
                                                 now: now,
                                                 settings: TimerCoreSettings()),
                       TimerRestoreDecision(state: .restPaused, action: .paused(remaining: 180)))
        XCTAssertEqual(TimerCore.restoredPausedDuration(for: pausedRest, now: now), 30)

        let expiredWork = session(state: .work,
                                  kind: .work,
                                  startedAt: now.addingTimeInterval(-300),
                                  finishAt: now,
                                  plannedDuration: 300)
        XCTAssertEqual(TimerCore.restoreDecision(for: expiredWork,
                                                 now: now,
                                                 settings: TimerCoreSettings(extendWorkAfterFinish: true)),
                       TimerRestoreDecision(state: .work, action: .extendExpiredWork))
        XCTAssertEqual(TimerCore.restoreDecision(for: expiredWork,
                                                 now: now,
                                                 settings: TimerCoreSettings()),
                       TimerRestoreDecision(state: .work, action: .fireExpired))

        let invalidMismatch = session(state: .work,
                                      kind: .shortRest,
                                      startedAt: now.addingTimeInterval(-100),
                                      finishAt: now.addingTimeInterval(200),
                                      plannedDuration: 300)
        XCTAssertFalse(TimerCore.isValidPersistedSession(invalidMismatch, now: now))
        XCTAssertEqual(TimerCore.restoreDecision(for: invalidMismatch,
                                                 now: now,
                                                 settings: TimerCoreSettings()).action, .discard)
    }

    func testPresetClampingAndLongRestDetection() {
        let unclamped = TimerPreset(workIntervalLength: 0,
                                    shortRestIntervalLength: 999,
                                    longRestIntervalLength: -10,
                                    workIntervalsInSet: 999)
        XCTAssertEqual(unclamped.clamped(),
                       TimerPreset(workIntervalLength: 1,
                                   shortRestIntervalLength: 120,
                                   longRestIntervalLength: 1,
                                   workIntervalsInSet: 10))
        XCTAssertFalse(TimerCore.isCurrentRestLongRest(currentWorkInterval: 3, preset: preset))
        XCTAssertTrue(TimerCore.isCurrentRestLongRest(currentWorkInterval: 4, preset: preset))
    }

    private func session(state: TBStateMachineStates,
                         kind: TBStatsIntervalKind,
                         startedAt: Date,
                         finishAt: Date,
                         plannedDuration: TimeInterval,
                         pausedTimeRemaining: TimeInterval = 0,
                         pausedDuration: TimeInterval = 0,
                         pauseStartedAt: Date? = nil) -> PersistedTimerSession {
        PersistedTimerSession(state: state,
                              preset: preset,
                              currentWorkInterval: 1,
                              kind: kind,
                              plannedDuration: plannedDuration,
                              startedAt: startedAt,
                              finishAt: finishAt,
                              pauseStartedAt: pauseStartedAt,
                              pausedTimeRemaining: pausedTimeRemaining,
                              pausedDuration: pausedDuration,
                              workExtensionActive: false,
                              workLimitNotificationSent: false,
                              restPresentationPending: false)
    }
}

import XCTest

final class TimerCoreTests: XCTestCase {
    private let preset = TimerPreset(workIntervalLength: 25,
                                     shortRestIntervalLength: 5,
                                     longRestIntervalLength: 15,
                                     workIntervalsInSet: 4)

    func testPauseAfterWorkIsIgnoredButPauseAfterRestStillPauses() {
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .timerFired,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .rest)

        let restPause = TimerCoreSettings(pauseAfterRestFinish: true)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .timerFired,
                                            settings: restPause,
                                            currentWorkInterval: 1,
                                            preset: preset), .workPaused)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .timerFired,
                                            settings: restPause,
                                            currentWorkInterval: 4,
                                            preset: preset), .idle)
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
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .timerFired,
                                            settings: settings,
                                            currentWorkInterval: 4,
                                            preset: preset), .idle)
    }

    func testSkipFollowsPresetRestBoundaries() {
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .rest)
        XCTAssertEqual(TimerCore.transition(from: .workPaused,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .rest)
        XCTAssertEqual(TimerCore.transition(from: .rest,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .work)
        XCTAssertEqual(TimerCore.transition(from: .restPaused,
                                            event: .skipEvent,
                                            settings: TimerCoreSettings(),
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
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .timerFired,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset), .rest)
        XCTAssertNil(TimerCore.transition(from: .work,
                                           event: .timerFired,
                                           settings: TimerCoreSettings(),
                                           currentWorkInterval: 1,
                                           preset: preset,
                                           workFinishedPendingBreak: true))
        XCTAssertNil(TimerCore.transition(from: .work,
                                           event: .startBreak,
                                           settings: TimerCoreSettings(),
                                           currentWorkInterval: 1,
                                           preset: preset))
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .startBreak,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset,
                                            workExtensionActive: true), .rest)
        XCTAssertEqual(TimerCore.transition(from: .work,
                                            event: .startBreak,
                                            settings: TimerCoreSettings(),
                                            currentWorkInterval: 1,
                                            preset: preset,
                                            workFinishedPendingBreak: true), .rest)
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
                       TimerRestoreDecision(state: .work, action: .workFinishedBoundary))
        XCTAssertEqual(TimerCore.restoreDecision(for: expiredWork,
                                                 now: now,
                                                 settings: TimerCoreSettings()),
                       TimerRestoreDecision(state: .work, action: .fireExpired))

        let restoredFinishedBoundary = session(state: .work,
                                               kind: .work,
                                               startedAt: now.addingTimeInterval(-3_600),
                                               finishAt: now,
                                               plannedDuration: 300,
                                               workFinishedPendingBreak: true)
        XCTAssertTrue(TimerCore.isValidPersistedSession(restoredFinishedBoundary, now: now))
        XCTAssertEqual(TimerCore.restoreDecision(for: restoredFinishedBoundary,
                                                 now: now,
                                                 settings: TimerCoreSettings()),
                       TimerRestoreDecision(state: .work, action: .workFinishedBoundary))

        let legacyExtensionBoundary = session(state: .work,
                                              kind: .work,
                                              startedAt: now.addingTimeInterval(-3_600),
                                              finishAt: now,
                                              plannedDuration: 300,
                                              workExtensionActive: true)
        XCTAssertTrue(TimerCore.isValidPersistedSession(legacyExtensionBoundary, now: now))
        XCTAssertEqual(TimerCore.restoreDecision(for: legacyExtensionBoundary,
                                                 now: now,
                                                 settings: TimerCoreSettings()),
                       TimerRestoreDecision(state: .work, action: .workFinishedBoundary))

        let invalidFutureBoundary = session(state: .work,
                                            kind: .work,
                                            startedAt: now.addingTimeInterval(-100),
                                            finishAt: now.addingTimeInterval(200),
                                            plannedDuration: 300,
                                            workFinishedPendingBreak: true)
        XCTAssertFalse(TimerCore.isValidPersistedSession(invalidFutureBoundary, now: now))
        XCTAssertEqual(TimerCore.restoreDecision(for: invalidFutureBoundary,
                                                 now: now,
                                                 settings: TimerCoreSettings()).action, .discard)

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

    func testFirstStartupDefaultPresetUsesThirtyFiveIntervals() {
        XCTAssertEqual(TimerPreset.firstStartupDefault,
                       TimerPreset(workIntervalLength: 30,
                                   shortRestIntervalLength: 5,
                                   longRestIntervalLength: 15,
                                   workIntervalsInSet: 4))
    }

    func testNamedPresetClampsStoredPresetValues() {
        let named = NamedTimerPreset(name: "Deep Work",
                                    preset: TimerPreset(workIntervalLength: 999,
                                                        shortRestIntervalLength: 0,
                                                        longRestIntervalLength: -1,
                                                        workIntervalsInSet: 99))

        XCTAssertEqual(named.name, "Deep Work")
        XCTAssertEqual(named.preset,
                       TimerPreset(workIntervalLength: 120,
                                   shortRestIntervalLength: 1,
                                   longRestIntervalLength: 1,
                                   workIntervalsInSet: 10))
    }

    func testControlModesDescribePopoverButtonStates() {
        XCTAssertEqual(TimerCore.controlMode(timerActive: false,
                                             state: .idle,
                                             paused: false,
                                             workExtensionActive: false,
                                             workStartPending: false,
                                             workFinishedPendingBreak: false), .inactive)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .work,
                                             paused: false,
                                             workExtensionActive: false,
                                             workStartPending: false,
                                             workFinishedPendingBreak: false), .workRunning)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .workPaused,
                                             paused: true,
                                             workExtensionActive: false,
                                             workStartPending: false,
                                             workFinishedPendingBreak: false), .workPaused)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .work,
                                             paused: false,
                                             workExtensionActive: true,
                                             workStartPending: false,
                                             workFinishedPendingBreak: false), .workExtended)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .work,
                                             paused: false,
                                             workExtensionActive: false,
                                             workStartPending: false,
                                             workFinishedPendingBreak: true), .workFinishedPendingBreak)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .rest,
                                             paused: false,
                                             workExtensionActive: false,
                                             workStartPending: false,
                                             workFinishedPendingBreak: false), .restRunning)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .restPaused,
                                             paused: true,
                                             workExtensionActive: false,
                                             workStartPending: false,
                                             workFinishedPendingBreak: false), .restPaused)
        XCTAssertEqual(TimerCore.controlMode(timerActive: true,
                                             state: .workPaused,
                                             paused: true,
                                             workExtensionActive: false,
                                             workStartPending: true,
                                             workFinishedPendingBreak: false), .workStartPending)
    }

    func testClockFormattingSupportsOvertimeCountUp() {
        XCTAssertEqual(TimerCore.clockString(from: 72), "01:12")
        XCTAssertEqual(TimerCore.overtimeClockString(from: 72), "+01:12")
        XCTAssertEqual(TimerCore.overtimeClockString(from: 3_661), "+1:01:01")
    }

    private func session(state: TBStateMachineStates,
                         kind: TBStatsIntervalKind,
                         startedAt: Date,
                         finishAt: Date,
                         plannedDuration: TimeInterval,
                         pausedTimeRemaining: TimeInterval = 0,
                         pausedDuration: TimeInterval = 0,
                         pauseStartedAt: Date? = nil,
                         workExtensionActive: Bool = false,
                         workFinishedPendingBreak: Bool = false) -> PersistedTimerSession {
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
                              workExtensionActive: workExtensionActive,
                              workLimitNotificationSent: false,
                              restPresentationPending: false,
                              workFinishedPendingBreak: workFinishedPendingBreak)
    }
}

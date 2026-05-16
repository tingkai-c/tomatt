import KeyboardShortcuts
import SwiftState
import SwiftUI

class TBTimer: ObservableObject {
    @AppStorage("showTimerInMenuBar") var showTimerInMenuBar = true
    @AppStorage("showFullScreenMask") var showFullScreenMask = false
    @AppStorage("strictFullScreenMask") var strictFullScreenMask = false
    @AppStorage("strictFullScreenMaskPresentationLock") var strictFullScreenMaskPresentationLock = true
    @AppStorage("pauseAfterRestFinish") var pauseAfterRestFinish = false
    @AppStorage("extendWorkAfterFinish") var extendWorkAfterFinish = false
    @AppStorage("currentPreset") private var currentPreset = 0
    @AppStorage("timerPresets") private var timerPresetsData = ""
    @AppStorage("activeTimerSession") private var activeTimerSessionData = ""

    // Legacy preferences seed the first preset.
    @AppStorage("workIntervalLength") private var legacyWorkIntervalLength = 25
    @AppStorage("shortRestIntervalLength") private var legacyShortRestIntervalLength = 5
    @AppStorage("longRestIntervalLength") private var legacyLongRestIntervalLength = 15
    @AppStorage("workIntervalsInSet") private var legacyWorkIntervalsInSet = 4
    private var stateMachine = TBStateMachine(state: .idle)
    public let player = TBPlayer()
    public private(set) var currentWorkInterval: Int = 0
    private var activePreset: TimerPreset?
    private var notificationCenter = TBNotificationCenter()
    private var finishTime: Date!
    private var pausedTimeRemaining: TimeInterval = 0
    private var activeIconName = NSImage.Name.idle
    private let statsStore = TBStatsStore.shared
    private var activeStatsInterval: TBActiveStatsInterval?
    private var pendingStatsCompletion: TBStatsCompletion?
    private var workExtensionActive = false
    private var workStartPending = false
    private var workLimitNotificationSent = false
    private var restPresentationPending = false
    private var workFinishedPendingBreak = false
    @Published var paused: Bool = false
    @Published var timeLeftString: String = ""
    @Published var timer: DispatchSourceTimer?
    @Published private(set) var remainingTimeProgress: Double = 1
    @Published private(set) var controlMode: TimerControlMode = .inactive
    @Published private(set) var strictFullScreenMaskActive = false
    @Published private(set) var strictFullScreenMaskShortcutBlockingUnavailable = false

    var selectedPresetIndex: Int {
        get { clampedPresetIndex(currentPreset) }
        set {
            let index = clampedPresetIndex(newValue)
            guard index != currentPreset else { return }
            objectWillChange.send()
            currentPreset = index
        }
    }

    var currentPresetInstance: TimerPreset {
        get { presets[selectedPresetIndex] }
        set {
            var updatedPresets = presets
            updatedPresets[selectedPresetIndex] = newValue.clamped()
            presets = updatedPresets
        }
    }

    var sessionPresetInstance: TimerPreset {
        timerPreset
    }

    private var timerPreset: TimerPreset {
        activePreset ?? currentPresetInstance
    }

    private var presets: [TimerPreset] {
        get { normalizedPresets() }
        set {
            let normalized = normalizePresets(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let rawValue = String(data: data, encoding: .utf8) {
                objectWillChange.send()
                timerPresetsData = rawValue
            }
        }
    }

    init() {
        /*
         * State diagram
         *
         *                 start/stop
         *       +--------------+-------------+
         *       |              |             |
         *       |  start/stop  |  timerFired |
         *       V    |         |    |        |
         * +--------+ |  +--------+  | +--------+
         * | idle   |--->| work   |--->| rest   |
         * +--------+    +--------+    +--------+
         *   A             |  A        |   A  |
         *   | pauseResume |  |        |   |  | pauseResume
         *   |             V  |        V   |  |
         *   |         +------------+ +------------+
         *   |         | workPaused | | restPaused |
         *   |         +------------+ +------------+
         *   |                  A        |    |
         *   |                  +--------+    |
         *   |      short rest timerFired/skip |
         *   |              skip              |
         *   |                                |
         *   +--------------------------------+
         *      long rest timerFired/skip
         *
         */
        stateMachine.addRoutes(event: .startStop, transitions: [
            .idle => .work, .work => .idle, .rest => .idle,
            .workPaused => .idle, .restPaused => .idle,
        ])
        stateMachine.addRoutes(event: .pauseResume, transitions: [
            .work => .workPaused, .rest => .restPaused,
            .workPaused => .work, .restPaused => .rest,
        ])
        stateMachine.addRoutes(event: .restoreWork, transitions: [.idle => .work])
        stateMachine.addRoutes(event: .restoreRest, transitions: [.idle => .rest])
        stateMachine.addRoutes(event: .restoreWorkPaused, transitions: [.idle => .workPaused])
        stateMachine.addRoutes(event: .restoreRestPaused, transitions: [.idle => .restPaused])
        stateMachine.addRoutes(event: .timerFired, transitions: [.work => .rest]) { _ in
            self.coreTransition(from: .work, event: .timerFired) == .rest
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.work => .rest, .workPaused => .rest]) { _ in
            self.coreTransition(from: .work, event: .skipEvent) == .rest
        }
        stateMachine.addRoutes(event: .startBreak, transitions: [.work => .rest, .workPaused => .rest]) { _ in
            self.coreTransition(from: .work, event: .startBreak) == .rest
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .idle]) { _ in
            self.coreTransition(from: .rest, event: .timerFired) == .idle
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .workPaused]) { _ in
            self.coreTransition(from: .rest, event: .timerFired) == .workPaused
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .work]) { _ in
            self.coreTransition(from: .rest, event: .timerFired) == .work
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.rest => .idle, .restPaused => .idle]) { _ in
            self.coreTransition(from: .rest, event: .skipEvent) == .idle
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.rest => .work, .restPaused => .work]) { _ in
            self.coreTransition(from: .rest, event: .skipEvent) == .work
        }

        /*
         * "Finish" handlers are called when time interval ended
         * "End"    handlers are called when time interval ended, skipped, or was cancelled
         * Pause/resume are explicit state-machine transitions but do not end the active interval.
         */
        stateMachine.addHandler(event: .startStop) { ctx in
            guard ctx.fromState == .idle, ctx.toState == .work else { return }
            self.onWorkStart(context: ctx)
        }
        stateMachine.addAnyHandler(.work => .workPaused, handler: onTimerPause)
        stateMachine.addAnyHandler(.rest => .restPaused, handler: onTimerPause)
        stateMachine.addAnyHandler(.workPaused => .work, handler: onTimerResume)
        stateMachine.addAnyHandler(.restPaused => .rest, handler: onTimerResume)
        stateMachine.addAnyHandler(.work => .rest, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .restPaused, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .idle, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.workPaused => .rest, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.workPaused => .idle, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .any, order: 1, handler: onWorkEnd)
        stateMachine.addAnyHandler(.workPaused => .any, order: 1, handler: onWorkEnd)
        stateMachine.addAnyHandler(.work => .rest, order: 2, handler: onRestStart)
        stateMachine.addAnyHandler(.workPaused => .rest, order: 2, handler: onRestStart)
        stateMachine.addAnyHandler(.work => .restPaused, order: 2, handler: onRestStartPaused)
        stateMachine.addAnyHandler(.rest => .work, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.rest => .workPaused, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.rest => .idle, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.restPaused => .work, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.restPaused => .idle, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.rest => .work, order: 1, handler: onRestFinish)
        stateMachine.addAnyHandler(.rest => .workPaused, order: 1, handler: onRestFinish)
        stateMachine.addAnyHandler(.restPaused => .work, order: 1, handler: onRestFinish)
        stateMachine.addAnyHandler(.rest => .work, order: 2, handler: onWorkStart)
        stateMachine.addAnyHandler(.restPaused => .work, order: 2, handler: onWorkStart)
        stateMachine.addAnyHandler(.rest => .workPaused, order: 2, handler: onWorkStartPaused)
        stateMachine.addAnyHandler(.any => .idle, handler: onIdleStart)
        stateMachine.addAnyHandler(.any => .any, handler: { ctx in
            logger.append(event: TBLogEventTransition(fromContext: ctx))
        })

        stateMachine.addErrorHandler { ctx in fatalError("state machine context: <\(ctx)>") }

        KeyboardShortcuts.onKeyUp(for: .startStopTimer, action: startStop)
        KeyboardShortcuts.onKeyUp(for: .pauseResumeTimer, action: pauseResume)
        KeyboardShortcuts.onKeyUp(for: .skipTimer, action: skip)
        notificationCenter.setActionHandler(handler: onNotificationAction)

        let aem: NSAppleEventManager = NSAppleEventManager.shared()
        aem.setEventHandler(self,
                            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
                            forEventClass: AEEventClass(kInternetEventClass),
                            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                 withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.forKeyword(AEKeyword(keyDirectObject))?.stringValue else {
            print("url handling error: cannot get url")
            return
        }
        let url = URL(string: urlString)
        guard url != nil,
              let scheme = url!.scheme,
              let host = url!.host else {
            print("url handling error: cannot parse url")
            return
        }
        guard scheme.caseInsensitiveCompare("tomatt") == .orderedSame else {
            print("url handling error: unknown scheme \(scheme)")
            return
        }
        switch host.lowercased() {
        case "startstop":
            startStop()
        case "pauseresume":
            pauseResume()
        case "skip":
            skip()
        default:
            print("url handling error: unknown command \(host)")
            return
        }
    }

    func startStop() {
        guard !strictFullScreenMaskBlocksRestControls else { return }
        stateMachine <-! .startStop
    }

    func skip() {
        guard timer != nil else { return }
        guard !strictFullScreenMaskBlocksRestControls else { return }
        guard !workExtensionActive, !workStartPending, !workFinishedPendingBreak else {
            return
        }
        paused = false
        stateMachine <-! .skipEvent
    }

    func setStrictFullScreenMask(_ enabled: Bool) {
        strictFullScreenMask = enabled
        strictFullScreenMaskShortcutBlockingUnavailable = enabled && !MaskHelper.shared.requestStrictKeyboardCaptureAccessIfNeeded()
    }

    func startBreak() {
        guard timer != nil,
              stateMachine.state == .work || stateMachine.state == .workPaused,
              workExtensionActive || workFinishedPendingBreak else {
            return
        }
        pendingStatsCompletion = .completed
        paused = false
        stateMachine <-! .startBreak
    }

    func startWork() {
        guard timer != nil,
              stateMachine.state == .workPaused,
              workStartPending else {
            return
        }
        stateMachine <-! .pauseResume
    }

    func pauseResume() {
        guard timer != nil else { return }
        guard !strictFullScreenMaskBlocksRestControls else { return }
        guard !workExtensionActive, !workStartPending, !workFinishedPendingBreak else { return }
        stateMachine <-! .pauseResume
    }

    func updateTimeLeft() {
        guard timer != nil else {
            timeLeftString = ""
            remainingTimeProgress = 1
            TBStatusItem.shared.setTitle(title: nil)
            updateControlMode()
            return
        }

        let timeLeft: TimeInterval
        if workFinishedPendingBreak, stateMachine.state == .work {
            timeLeft = 0
            timeLeftString = TimerCore.clockString(from: 0)
        } else if workExtensionActive, stateMachine.state == .work {
            timeLeft = 0
            timeLeftString = TimerCore.overtimeClockString(from: Date().timeIntervalSince(finishTime))
        } else {
            timeLeft = max(0, paused ? pausedTimeRemaining : finishTime.timeIntervalSince(Date()))
            timeLeftString = TimerCore.clockString(from: timeLeft)
        }
        remainingTimeProgress = remainingProgress(for: timeLeft)

        updateControlMode()
        if !paused, showTimerInMenuBar {
            TBStatusItem.shared.setTitle(title: timeLeftString)
        } else {
            TBStatusItem.shared.setTitle(title: nil)
        }
    }

    private func remainingProgress(for timeLeft: TimeInterval) -> Double {
        guard let plannedDuration = activeStatsInterval?.plannedDuration,
              plannedDuration > 0 else {
            return 0
        }

        return min(max(timeLeft / plannedDuration, 0), 1)
    }

    private func startTimer(seconds: Int) {
        startTimer(until: Date().addingTimeInterval(TimeInterval(seconds)))
    }

    private func startTimer(until date: Date) {
        finishTime = date

        let queue = DispatchQueue(label: "Timer")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer!.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        timer!.setEventHandler(handler: onTimerTick)
        timer!.setCancelHandler(handler: onTimerCancel)
        timer!.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func startPausedTimer(seconds: Int) {
        startTimer(seconds: seconds)
        paused = true
        pausedTimeRemaining = TimeInterval(seconds)
        finishTime = Date.distantFuture
        activeStatsInterval?.pause(at: Date())
        TBStatusItem.shared.setIcon(name: .pause)
        updateTimeLeft()
    }

    private func onTimerTick() {
        /* Cannot publish updates from background thread */
        DispatchQueue.main.async { [self] in
            guard !paused else { return }
            updateTimeLeft()
            let timeLeft = finishTime.timeIntervalSince(Date())
            if timeLeft <= 0 {
                if stateMachine.state == .work, workExtensionActive || workFinishedPendingBreak {
                    return
                }
                if stateMachine.state == .work && shouldExtendWorkSessionAtLimit() {
                    extendWorkSessionAtLimit()
                    return
                }
                stateMachine <-! .timerFired
            }
        }
    }

    private func onTimerCancel() {
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
        }
    }

    private func onNotificationAction(action: TBNotification.Action) {
        if action == .skipRest, stateMachine.state == .rest || stateMachine.state == .restPaused {
            skip()
        }
    }

    private func onWorkStart(context ctx: TBStateMachine.Context) {
        if ctx.fromState == .idle || activePreset == nil {
            activePreset = currentPresetInstance
        }
        if currentWorkInterval >= timerPreset.workIntervalsInSet {
            currentWorkInterval = 1
        } else {
            currentWorkInterval += 1
        }
        setActiveIcon(name: .work)
        paused = false
        workExtensionActive = false
        workStartPending = false
        workFinishedPendingBreak = false
        workLimitNotificationSent = false
        player.playWindup()
        player.startTicking()
        startStatsInterval(kind: .work,
                           plannedDuration: TimeInterval(timerPreset.workIntervalLength * 60))
        startTimer(seconds: timerPreset.workIntervalLength * 60)
        persistActiveTimerSession()
    }

    private func onWorkFinish(context ctx: TBStateMachine.Context) {
        if ctx.event == .timerFired {
            player.playDing()
        }
    }

    private func onWorkEnd(context ctx: TBStateMachine.Context) {
        // Pause/resume keeps the current interval alive; onTimerPause/onTimerResume own ticking state.
        guard ctx.event != .pauseResume else { return }
        closeStatsInterval(context: ctx)
        player.stopTicking()
    }

    private func onWorkStartPaused(context ctx: TBStateMachine.Context) {
        if ctx.fromState == .idle || activePreset == nil {
            activePreset = currentPresetInstance
        }
        if currentWorkInterval >= timerPreset.workIntervalsInSet {
            currentWorkInterval = 1
        } else {
            currentWorkInterval += 1
        }
        setActiveIcon(name: .work)
        workExtensionActive = false
        workStartPending = true
        workFinishedPendingBreak = false
        workLimitNotificationSent = false
        startStatsInterval(kind: .work,
                           plannedDuration: TimeInterval(timerPreset.workIntervalLength * 60))
        startPausedTimer(seconds: timerPreset.workIntervalLength * 60)
        persistActiveTimerSession()
    }

    private func onTimerPause(context ctx: TBStateMachine.Context) {
        paused = true
        workStartPending = false
        pausedTimeRemaining = max(0, finishTime.timeIntervalSince(Date()))
        finishTime = Date.distantFuture
        activeStatsInterval?.pause(at: Date())
        if ctx.fromState == .work {
            player.stopTicking()
        }
        TBStatusItem.shared.setIcon(name: .pause)
        updateTimeLeft()
        persistActiveTimerSession()
    }

    private func onTimerResume(context ctx: TBStateMachine.Context) {
        paused = false
        activeStatsInterval?.resume(at: Date())
        finishTime = Date().addingTimeInterval(pausedTimeRemaining)
        if ctx.toState == .work {
            workStartPending = false
            player.startTicking()
        } else if ctx.toState == .rest, restPresentationPending {
            showCurrentRestMaskIfNeeded()
            restPresentationPending = false
        }
        TBStatusItem.shared.setIcon(name: activeIconName)
        updateTimeLeft()
        persistActiveTimerSession()
    }

    private func onRestStart(context ctx: TBStateMachine.Context) {
        var body = NSLocalizedString("TBTimer.onRestStart.short.body", comment: "Short break body")
        var length = timerPreset.shortRestIntervalLength
        var imgName = NSImage.Name.shortRest
        if isCurrentRestLongRest() {
            body = NSLocalizedString("TBTimer.onRestStart.long.body", comment: "Long break body")
            length = timerPreset.longRestIntervalLength
            imgName = .longRest
        }
        paused = false
        workStartPending = false
        workFinishedPendingBreak = false
        if showFullScreenMask {
            showRestMask(desc: body)
        } else if ctx.event == .timerFired {
            notificationCenter.send(
                title: NSLocalizedString("TBTimer.onRestStart.title", comment: "Time's up title"),
                body: body,
                category: .restStarted
            )
        }
        setActiveIcon(name: imgName)
        restPresentationPending = false
        startStatsInterval(kind: imgName == .longRest ? .longRest : .shortRest,
                           plannedDuration: TimeInterval(length * 60))
        startTimer(seconds: length * 60)
        persistActiveTimerSession()
    }

    private func onRestStartPaused(context _: TBStateMachine.Context) {
        var length = timerPreset.shortRestIntervalLength
        var imgName = NSImage.Name.shortRest
        if isCurrentRestLongRest() {
            length = timerPreset.longRestIntervalLength
            imgName = .longRest
        }
        setActiveIcon(name: imgName)
        restPresentationPending = true
        startStatsInterval(kind: imgName == .longRest ? .longRest : .shortRest,
                           plannedDuration: TimeInterval(length * 60))
        startPausedTimer(seconds: length * 60)
        persistActiveTimerSession()
        sendWorkFinishedNotification()
    }

    private func onRestEnd(context ctx: TBStateMachine.Context) {
        closeStatsInterval(context: ctx)
        hideRestMask()
        if isCurrentRestLongRest() {
            currentWorkInterval = 0
        }
    }

    private func onRestFinish(context ctx: TBStateMachine.Context) {
        if ctx.event == .skipEvent {
            return
        }
        hideRestMask()
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestFinish.title", comment: "Break is over title"),
            body: NSLocalizedString("TBTimer.onRestFinish.body", comment: "Break is over body"),
            category: .restFinished
        )
    }

    private func onIdleStart(context _: TBStateMachine.Context) {
        stopTimer()
        hideRestMask()
        paused = false
        setActiveIcon(name: .idle)
        currentWorkInterval = 0
        pausedTimeRemaining = 0
        pendingStatsCompletion = nil
        activePreset = nil
        workExtensionActive = false
        workStartPending = false
        workFinishedPendingBreak = false
        workLimitNotificationSent = false
        restPresentationPending = false
        clearPersistedTimerSession()
    }

    private func setActiveIcon(name: NSImage.Name) {
        activeIconName = name
        if !paused {
            TBStatusItem.shared.setIcon(name: name)
        }
    }

    private func updateControlMode() {
        controlMode = TimerCore.controlMode(timerActive: timer != nil,
                                            state: stateMachine.state,
                                            paused: paused,
                                            workExtensionActive: workExtensionActive,
                                            workStartPending: workStartPending,
                                            workFinishedPendingBreak: workFinishedPendingBreak)
    }

    private func isCurrentRestLongRest() -> Bool {
        TimerCore.isCurrentRestLongRest(currentWorkInterval: currentWorkInterval,
                                        preset: timerPreset)
    }

    private func showCurrentRestMaskIfNeeded() {
        guard showFullScreenMask else { return }
        let body = isCurrentRestLongRest()
            ? NSLocalizedString("TBTimer.onRestStart.long.body", comment: "Long break body")
            : NSLocalizedString("TBTimer.onRestStart.short.body", comment: "Short break body")
        showRestMask(desc: body)
    }

    private func showRestMask(desc: String) {
        let strictRequested = strictFullScreenMask
        strictFullScreenMaskActive = MaskHelper.shared.showMaskWindow(
            desc: desc,
            strict: strictRequested,
            presentationLock: strictRequested && strictFullScreenMaskPresentationLock
        ) { [weak self] in
            self?.skip()
        }
        strictFullScreenMaskShortcutBlockingUnavailable = strictRequested && !MaskHelper.shared.strictKeyboardCaptureActive
        updateControlMode()
    }

    private func hideRestMask() {
        strictFullScreenMaskActive = false
        MaskHelper.shared.hideMaskWindow(animated: false)
        updateControlMode()
    }

    private var strictFullScreenMaskBlocksRestControls: Bool {
        strictFullScreenMaskActive && (stateMachine.state == .rest || stateMachine.state == .restPaused)
    }

    private func shouldExtendWorkSessionAtLimit() -> Bool {
        TimerCore.shouldExtendWorkSessionAtLimit(extendWorkAfterFinish: effectiveExtendWorkAfterFinish)
    }

    private var coreSettings: TimerCoreSettings {
        TimerCoreSettings(pauseAfterRestFinish: effectivePauseAfterRestFinish,
                          extendWorkAfterFinish: effectiveExtendWorkAfterFinish)
    }

    private func coreTransition(from state: TBStateMachineStates,
                                event: TBStateMachineEvents) -> TBStateMachineStates? {
        TimerCore.transition(from: state,
                             event: event,
                             settings: coreSettings,
                             currentWorkInterval: currentWorkInterval,
                             preset: timerPreset,
                             workExtensionActive: workExtensionActive,
                             workFinishedPendingBreak: workFinishedPendingBreak)
    }

    private var effectivePauseAfterRestFinish: Bool {
        pauseAfterRestFinish
    }

    private var effectiveExtendWorkAfterFinish: Bool {
        extendWorkAfterFinish
    }

    private func extendWorkSessionAtLimit() {
        guard !workExtensionActive else { return }
        workExtensionActive = true
        workFinishedPendingBreak = false
        finishTime = Date()
        updateTimeLeft()
        sendWorkFinishedNotification()
        persistActiveTimerSession()
    }

    private func sendWorkFinishedNotification() {
        guard !workLimitNotificationSent else { return }
        workLimitNotificationSent = true
        persistActiveTimerSession()
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onWorkFinish.title", comment: "Work finished title"),
            body: NSLocalizedString("TBTimer.onWorkFinish.body", comment: "Work finished body"),
            category: .workFinished
        )
    }

    func restoreTimerIfNeeded() {
        guard timer == nil,
              stateMachine.state == .idle,
              !activeTimerSessionData.isEmpty else {
            return
        }
        guard let data = activeTimerSessionData.data(using: .utf8),
              let session = try? JSONDecoder().decode(PersistedTimerSession.self, from: data),
              session.schemaVersion == 1,
              isValidPersistedSession(session) else {
            discardPersistedTimerSession()
            return
        }

        activePreset = session.preset.clamped()
        currentWorkInterval = session.currentWorkInterval
        activeStatsInterval = restoredStatsInterval(from: session)
        workExtensionActive = session.workExtensionActive
        workStartPending = session.workStartPending ?? false
        workFinishedPendingBreak = session.workFinishedPendingBreak ?? false
        workLimitNotificationSent = session.workLimitNotificationSent
        restPresentationPending = session.restPresentationPending

        restoreValidatedSession(session)
    }

    private func restoreValidatedSession(_ session: PersistedTimerSession) {
        switch session.state {
        case .work:
            restoreWorkSession(session)
        case .rest:
            restoreRestSession(session)
        case .workPaused:
            restorePausedSession(session, event: .restoreWorkPaused, iconName: .work)
        case .restPaused:
            restorePausedSession(session,
                                 event: .restoreRestPaused,
                                 iconName: session.kind == .longRest ? .longRest : .shortRest)
        case .idle:
            discardPersistedTimerSession()
        }
    }

    private func isValidPersistedSession(_ session: PersistedTimerSession) -> Bool {
        TimerCore.isValidPersistedSession(session, now: Date())
    }

    private func restoreWorkSession(_ session: PersistedTimerSession) {
        stateMachine <-! .restoreWork

        switch TimerCore.restoreDecision(for: session, now: Date(), settings: coreSettings).action {
        case let .running(remaining):
            restoreRunningSession(session, remaining: remaining, iconName: .work)
            player.startTicking()
        case .workFinishedBoundary:
            restoreWorkFinishedBoundary(session)
        case .fireExpired:
            setActiveIcon(name: .work)
            paused = false
            pausedTimeRemaining = 0
            startTimer(until: Date())
            stateMachine <-! .timerFired
        case .discard, .paused:
            discardPersistedTimerSession()
        }
    }

    private func restoreWorkFinishedBoundary(_ session: PersistedTimerSession) {
        setActiveIcon(name: .work)
        paused = false
        pausedTimeRemaining = 0
        workExtensionActive = false
        workStartPending = false
        workFinishedPendingBreak = true
        workLimitNotificationSent = session.workLimitNotificationSent
        restPresentationPending = session.restPresentationPending
        startTimer(until: Date())
        updateTimeLeft()
        sendWorkFinishedNotification()
        persistActiveTimerSession()
    }

    private func restoreRestSession(_ session: PersistedTimerSession) {
        stateMachine <-! .restoreRest

        let remaining = session.finishAt.timeIntervalSince(Date())
        if remaining > 0 {
            restoreRunningSession(session,
                                  remaining: remaining,
                                  iconName: session.kind == .longRest ? .longRest : .shortRest)
            restoreRunningRestPresentationIfNeeded()
            return
        }

        setActiveIcon(name: session.kind == .longRest ? .longRest : .shortRest)
        paused = false
        pausedTimeRemaining = 0
        startTimer(until: Date())
        stateMachine <-! .timerFired
    }

    private func restoreRunningRestPresentationIfNeeded() {
        guard showFullScreenMask else {
            restPresentationPending = false
            persistActiveTimerSession()
            return
        }

        showCurrentRestMaskIfNeeded()
        restPresentationPending = false
        persistActiveTimerSession()
    }

    private func restoreRunningSession(_ session: PersistedTimerSession,
                                       remaining: TimeInterval,
                                       iconName: NSImage.Name) {
        setActiveIcon(name: iconName)
        paused = false
        pausedTimeRemaining = 0
        workExtensionActive = session.workExtensionActive
        workStartPending = session.workStartPending ?? false
        workFinishedPendingBreak = session.workFinishedPendingBreak ?? false
        workLimitNotificationSent = session.workLimitNotificationSent
        restPresentationPending = session.restPresentationPending
        startTimer(until: Date().addingTimeInterval(remaining))
        updateTimeLeft()
        persistActiveTimerSession()
    }

    private func restorePausedSession(_ session: PersistedTimerSession,
                                      event: TBStateMachineEvents,
                                      iconName: NSImage.Name) {
        stateMachine <-! event
        workStartPending = session.workStartPending ?? false
        activeIconName = iconName
        startTimer(until: Date().addingTimeInterval(max(0, session.pausedTimeRemaining)))
        paused = true
        pausedTimeRemaining = max(0, session.pausedTimeRemaining)
        finishTime = Date.distantFuture
        activeStatsInterval?.pauseStartedAt = Date()
        TBStatusItem.shared.setIcon(name: .pause)
        updateTimeLeft()
        persistActiveTimerSession()
    }

    private func restoredStatsInterval(from session: PersistedTimerSession) -> TBActiveStatsInterval {
        let pausedDuration = restoredPausedDuration(for: session)
        return TBActiveStatsInterval(id: UUID(),
                                     kind: session.kind,
                                     startedAt: session.startedAt,
                                     plannedDuration: session.plannedDuration,
                                     preset: TimerPresetSnapshot(preset: session.preset),
                                     workIntervalIndex: session.currentWorkInterval,
                                     pausedDuration: pausedDuration,
                                     pauseStartedAt: nil)
    }

    private func restoredPausedDuration(for session: PersistedTimerSession) -> TimeInterval {
        TimerCore.restoredPausedDuration(for: session, now: Date())
    }

    private func persistActiveTimerSession() {
        guard timer != nil,
              stateMachine.state != .idle,
              let activeStatsInterval = activeStatsInterval else {
            return
        }

        let remaining = max(0, paused ? pausedTimeRemaining : finishTime.timeIntervalSince(Date()))
        let finishAt = paused ? Date().addingTimeInterval(remaining) : finishTime!
        let session = PersistedTimerSession(
            state: stateMachine.state,
            preset: timerPreset,
            currentWorkInterval: currentWorkInterval,
            kind: activeStatsInterval.kind,
            plannedDuration: activeStatsInterval.plannedDuration,
            startedAt: activeStatsInterval.startedAt,
            finishAt: finishAt,
            pauseStartedAt: activeStatsInterval.pauseStartedAt,
            pausedTimeRemaining: remaining,
            pausedDuration: activeStatsInterval.pausedDuration,
            workExtensionActive: workExtensionActive,
            workLimitNotificationSent: workLimitNotificationSent,
            restPresentationPending: restPresentationPending,
            workStartPending: workStartPending,
            workFinishedPendingBreak: workFinishedPendingBreak
        )

        guard let data = try? JSONEncoder().encode(session),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        activeTimerSessionData = rawValue
    }

    private func clearPersistedTimerSession() {
        activeTimerSessionData = ""
    }

    private func discardPersistedTimerSession() {
        clearPersistedTimerSession()
        activePreset = nil
        activeStatsInterval = nil
        currentWorkInterval = 0
        paused = false
        pausedTimeRemaining = 0
        workExtensionActive = false
        workStartPending = false
        workFinishedPendingBreak = false
        workLimitNotificationSent = false
        restPresentationPending = false
    }

    private func startStatsInterval(kind: TBStatsIntervalKind, plannedDuration: TimeInterval) {
        activeStatsInterval = TBActiveStatsInterval(id: UUID(),
                                                    kind: kind,
                                                    startedAt: Date(),
                                                    plannedDuration: plannedDuration,
                                                    preset: TimerPresetSnapshot(preset: timerPreset),
                                                    workIntervalIndex: currentWorkInterval)
    }

    private func closeStatsInterval(context ctx: TBStateMachine.Context) {
        // Closing on pause would drop activeStatsInterval, which also drives circular progress.
        guard ctx.event != .pauseResume else { return }
        guard var interval = activeStatsInterval else { return }
        activeStatsInterval = nil

        let completion = pendingStatsCompletion ?? statsCompletion(for: ctx)
        pendingStatsCompletion = nil
        let record = interval.record(completion: completion, at: Date())
        statsStore.append(record)
    }

    private func statsCompletion(for ctx: TBStateMachine.Context) -> TBStatsCompletion {
        switch ctx.event {
        case .timerFired?:
            return .completed
        case .skipEvent?:
            return .skipped
        case .startStop?:
            return .stopped
        default:
            return .stopped
        }
    }


    private func normalizedPresets() -> [TimerPreset] {
        guard !timerPresetsData.isEmpty,
              let data = timerPresetsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TimerPreset].self, from: data) else {
            return defaultPresets()
        }
        return normalizePresets(decoded)
    }

    private func defaultPresets() -> [TimerPreset] {
        var defaults = Array(repeating: TimerPreset(), count: 4)
        defaults[0] = TimerPreset(workIntervalLength: legacyWorkIntervalLength,
                                  shortRestIntervalLength: legacyShortRestIntervalLength,
                                  longRestIntervalLength: legacyLongRestIntervalLength,
                                  workIntervalsInSet: legacyWorkIntervalsInSet).clamped()
        return defaults
    }

    private func normalizePresets(_ source: [TimerPreset]) -> [TimerPreset] {
        var normalized = source.prefix(4).map { $0.clamped() }
        while normalized.count < 4 {
            normalized.append(TimerPreset())
        }
        return normalized
    }

    private func clampedPresetIndex(_ index: Int) -> Int {
        min(max(index, 0), 3)
    }
}

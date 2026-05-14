import KeyboardShortcuts
import SwiftState
import SwiftUI

enum StopAfterOption: String, CaseIterable {
    case disabled, work, rest, set
}

struct TimerPreset: Codable, Equatable {
    var workIntervalLength = 25
    var shortRestIntervalLength = 5
    var longRestIntervalLength = 15
    var workIntervalsInSet = 4
}

class TBTimer: ObservableObject {
    @AppStorage("stopAfter") var stopAfter = StopAfterOption.disabled
    @AppStorage("showTimerInMenuBar") var showTimerInMenuBar = true
    @AppStorage("showFullScreenMask") var showFullScreenMask = false
    @AppStorage("currentPreset") private var currentPreset = 0
    @AppStorage("timerPresets") private var timerPresetsData = ""

    // Legacy preferences seed/migrate the first preset and previous stop-after-break behavior.
    @AppStorage("workIntervalLength") private var legacyWorkIntervalLength = 25
    @AppStorage("shortRestIntervalLength") private var legacyShortRestIntervalLength = 5
    @AppStorage("longRestIntervalLength") private var legacyLongRestIntervalLength = 15
    @AppStorage("workIntervalsInSet") private var legacyWorkIntervalsInSet = 4
    @AppStorage("stopAfterBreak") private var legacyStopAfterBreak = false
    @AppStorage("stopAfterBreakMigratedToStopAfter") private var stopAfterBreakMigrated = false
    // This preference is "hidden"
    @AppStorage("overrunTimeLimit") var overrunTimeLimit = -60.0

    private var stateMachine = TBStateMachine(state: .idle)
    public let player = TBPlayer()
    public private(set) var currentWorkInterval: Int = 0
    private var activePreset: TimerPreset?
    private var notificationCenter = TBNotificationCenter()
    private var finishTime: Date!
    private var timerFormatter = DateComponentsFormatter()
    private var pausedTimeRemaining: TimeInterval = 0
    private var activeIconName = NSImage.Name.idle
    private let statsStore = TBStatsStore.shared
    private var activeStatsInterval: TBActiveStatsInterval?
    private var pendingStatsCompletion: TBStatsCompletion?
    @Published var paused: Bool = false
    @Published var timeLeftString: String = ""
    @Published var timer: DispatchSourceTimer?

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
        migrateLegacyPreferences()
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
         *   |  timerFired/skip (!stopAfter)  |
         *   |             skip               |
         *   |                                |
         *   +--------------------------------+
         *      timerFired/skip (stopAfter)
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
        stateMachine.addRoutes(event: .timerFired, transitions: [.work => .idle]) { _ in
            self.stopAfter == .work
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.work => .rest]) { _ in
            self.stopAfter != .work
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.work => .idle, .workPaused => .idle]) { _ in
            self.stopAfter == .work
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.work => .rest, .workPaused => .rest]) { _ in
            self.stopAfter != .work
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .idle]) { _ in
            self.shouldStopAfterRest()
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .work]) { _ in
            !self.shouldStopAfterRest()
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.rest => .idle, .restPaused => .idle]) { _ in
            self.shouldStopAfterRest()
        }
        stateMachine.addRoutes(event: .skipEvent, transitions: [.rest => .work, .restPaused => .work]) { _ in
            !self.shouldStopAfterRest()
        }

        /*
         * "Finish" handlers are called when time interval ended
         * "End"    handlers are called when time interval ended, skipped, or was cancelled
         * Pause/resume are explicit state-machine transitions but do not end the active interval.
         */
        stateMachine.addAnyHandler(.idle => .work, handler: onWorkStart)
        stateMachine.addAnyHandler(.work => .workPaused, handler: onTimerPause)
        stateMachine.addAnyHandler(.rest => .restPaused, handler: onTimerPause)
        stateMachine.addAnyHandler(.workPaused => .work, handler: onTimerResume)
        stateMachine.addAnyHandler(.restPaused => .rest, handler: onTimerResume)
        stateMachine.addAnyHandler(.work => .rest, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .idle, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.workPaused => .rest, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.workPaused => .idle, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .any, order: 1, handler: onWorkEnd)
        stateMachine.addAnyHandler(.workPaused => .any, order: 1, handler: onWorkEnd)
        stateMachine.addAnyHandler(.work => .rest, order: 2, handler: onRestStart)
        stateMachine.addAnyHandler(.workPaused => .rest, order: 2, handler: onRestStart)
        stateMachine.addAnyHandler(.rest => .work, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.rest => .idle, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.restPaused => .work, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.restPaused => .idle, order: 0, handler: onRestEnd)
        stateMachine.addAnyHandler(.rest => .work, order: 1, handler: onRestFinish)
        stateMachine.addAnyHandler(.restPaused => .work, order: 1, handler: onRestFinish)
        stateMachine.addAnyHandler(.rest => .work, order: 2, handler: onWorkStart)
        stateMachine.addAnyHandler(.restPaused => .work, order: 2, handler: onWorkStart)
        stateMachine.addAnyHandler(.any => .idle, handler: onIdleStart)
        stateMachine.addAnyHandler(.any => .any, handler: { ctx in
            logger.append(event: TBLogEventTransition(fromContext: ctx))
        })

        stateMachine.addErrorHandler { ctx in fatalError("state machine context: <\(ctx)>") }

        timerFormatter.unitsStyle = .positional

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
        stateMachine <-! .startStop
    }

    func skip() {
        guard timer != nil else { return }
        paused = false
        stateMachine <-! .skipEvent
    }

    func pauseResume() {
        guard timer != nil else { return }
        stateMachine <-! .pauseResume
    }

    func updateTimeLeft() {
        guard timer != nil else {
            timeLeftString = ""
            TBStatusItem.shared.setTitle(title: nil)
            return
        }

        let timeLeft = max(0, paused ? pausedTimeRemaining : finishTime.timeIntervalSince(Date()))
        if timeLeft >= 3600 {
            timerFormatter.allowedUnits = [.hour, .minute, .second]
            timerFormatter.zeroFormattingBehavior = .dropLeading
        } else {
            timerFormatter.allowedUnits = [.minute, .second]
            timerFormatter.zeroFormattingBehavior = .pad
        }

        timeLeftString = timerFormatter.string(from: timeLeft) ?? ""
        if !paused, showTimerInMenuBar {
            TBStatusItem.shared.setTitle(title: timeLeftString)
        } else {
            TBStatusItem.shared.setTitle(title: nil)
        }
    }

    private func startTimer(seconds: Int) {
        finishTime = Date().addingTimeInterval(TimeInterval(seconds))

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

    private func onTimerTick() {
        /* Cannot publish updates from background thread */
        DispatchQueue.main.async { [self] in
            guard !paused else { return }
            updateTimeLeft()
            let timeLeft = finishTime.timeIntervalSince(Date())
            if timeLeft <= 0 {
                /*
                 Ticks can be missed during the machine sleep.
                Stop the timer if it goes beyond an overrun time limit.
                 */
                if timeLeft < overrunTimeLimit {
                    pendingStatsCompletion = .abandoned
                    stateMachine <-! .startStop
                } else {
                    stateMachine <-! .timerFired
                }
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
        player.playWindup()
        player.startTicking()
        startStatsInterval(kind: .work,
                           plannedDuration: TimeInterval(timerPreset.workIntervalLength * 60))
        startTimer(seconds: timerPreset.workIntervalLength * 60)
    }

    private func onWorkFinish(context ctx: TBStateMachine.Context) {
        if ctx.event == .timerFired {
            player.playDing()
        }
    }

    private func onWorkEnd(context ctx: TBStateMachine.Context) {
        closeStatsInterval(context: ctx)
        player.stopTicking()
    }

    private func onTimerPause(context ctx: TBStateMachine.Context) {
        paused = true
        pausedTimeRemaining = max(0, finishTime.timeIntervalSince(Date()))
        finishTime = Date.distantFuture
        activeStatsInterval?.pause(at: Date())
        if ctx.fromState == .work {
            player.stopTicking()
        }
        TBStatusItem.shared.setIcon(name: .pause)
        updateTimeLeft()
    }

    private func onTimerResume(context ctx: TBStateMachine.Context) {
        paused = false
        activeStatsInterval?.resume(at: Date())
        finishTime = Date().addingTimeInterval(pausedTimeRemaining)
        if ctx.toState == .work {
            player.startTicking()
        }
        TBStatusItem.shared.setIcon(name: activeIconName)
        updateTimeLeft()
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
        if showFullScreenMask {
            MaskHelper.shared.showMaskWindow(desc: body) { [weak self] in
                self?.skip()
            }
        } else if ctx.event == .timerFired {
            notificationCenter.send(
                title: NSLocalizedString("TBTimer.onRestStart.title", comment: "Time's up title"),
                body: body,
                category: .restStarted
            )
        }
        setActiveIcon(name: imgName)
        startStatsInterval(kind: imgName == .longRest ? .longRest : .shortRest,
                           plannedDuration: TimeInterval(length * 60))
        startTimer(seconds: length * 60)
    }

    private func onRestEnd(context ctx: TBStateMachine.Context) {
        closeStatsInterval(context: ctx)
        MaskHelper.shared.hideMaskWindow()
        if isCurrentRestLongRest() {
            currentWorkInterval = 0
        }
    }

    private func onRestFinish(context ctx: TBStateMachine.Context) {
        if ctx.event == .skipEvent {
            return
        }
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestFinish.title", comment: "Break is over title"),
            body: NSLocalizedString("TBTimer.onRestFinish.body", comment: "Break is over body"),
            category: .restFinished
        )
    }

    private func onIdleStart(context _: TBStateMachine.Context) {
        stopTimer()
        MaskHelper.shared.hideMaskWindow()
        paused = false
        setActiveIcon(name: .idle)
        currentWorkInterval = 0
        pausedTimeRemaining = 0
        pendingStatsCompletion = nil
        activePreset = nil
    }

    private func setActiveIcon(name: NSImage.Name) {
        activeIconName = name
        if !paused {
            TBStatusItem.shared.setIcon(name: name)
        }
    }

    private func shouldStopAfterRest() -> Bool {
        stopAfter == .rest || (stopAfter == .set && isCurrentRestLongRest())
    }

    private func isCurrentRestLongRest() -> Bool {
        currentWorkInterval >= timerPreset.workIntervalsInSet
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

    private func migrateLegacyPreferences() {
        guard !stopAfterBreakMigrated else { return }
        if stopAfter == .disabled, legacyStopAfterBreak {
            stopAfter = .rest
        }
        stopAfterBreakMigrated = true
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

private extension TimerPreset {
    func clamped() -> TimerPreset {
        TimerPreset(workIntervalLength: workIntervalLength.clamped(to: 1 ... 120),
                    shortRestIntervalLength: shortRestIntervalLength.clamped(to: 1 ... 120),
                    longRestIntervalLength: longRestIntervalLength.clamped(to: 1 ... 120),
                    workIntervalsInSet: workIntervalsInSet.clamped(to: 1 ... 10))
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

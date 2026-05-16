import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

extension KeyboardShortcuts.Name {
    static let startStopTimer = Self("startStopTimer")
    static let pauseResumeTimer = Self("pauseResumeTimer")
    static let skipTimer = Self("skipTimer")
}

protocol DropdownDescribable: RawRepresentable {
    var localizedDescription: String { get }
}

extension TBAppearanceMode: DropdownDescribable {
    var localizedDescription: String {
        switch self {
        case .system:
            return NSLocalizedString("SettingsView.appearance.system.label",
                                     comment: "System appearance label")
        case .light:
            return NSLocalizedString("SettingsView.appearance.light.label",
                                     comment: "Light appearance label")
        case .dark:
            return NSLocalizedString("SettingsView.appearance.dark.label",
                                     comment: "Dark appearance label")
        }
    }
}

private struct SegmentedDropdown<E: CaseIterable & Hashable & DropdownDescribable>: View
    where E.RawValue == String, E.AllCases: RandomAccessCollection {
    @Binding var value: E

    var body: some View {
        Picker("", selection: $value) {
            ForEach(E.allCases, id: \.self) { value in
                Text(value.localizedDescription).tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}

enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    static let windowHeight: CGFloat = 490
    static let panePadding: CGFloat = 24
    static let rowLabelWidth: CGFloat = 220
    static let rowControlWidth: CGFloat = 230
    static let contentWidth: CGFloat = 460
    static let soundSliderWidth: CGFloat = 140
}

private struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(SettingsLayout.panePadding)
        .frame(width: SettingsLayout.contentWidth, alignment: .topLeading)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .frame(width: SettingsLayout.rowLabelWidth, alignment: .trailing)
            content
                .frame(maxWidth: SettingsLayout.rowControlWidth, alignment: .leading)
        }
    }
}

private struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: SettingsLayout.contentWidth, alignment: .leading)
            .padding(.top, 4)
    }
}

private struct AppearancePickerView: View {
    @ObservedObject var appearanceController: TBAppearanceController

    var body: some View {
        SegmentedDropdown(value: appearanceBinding)
    }

    private var appearanceBinding: Binding<TBAppearanceMode> {
        Binding(
            get: { appearanceController.mode },
            set: { appearanceController.mode = $0 }
        )
    }
}

private struct OpenSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
        }
        .tbIconButton()
        .controlSize(.small)
    }
}

private struct OpenStatsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chart.bar")
        }
        .tbIconButton()
        .controlSize(.small)
    }
}

private enum PopoverLayout {
    static let width: CGFloat = 284
    static let height: CGFloat = 338
    static let timerCircleDiameter: CGFloat = 204
    static let timerTitleOffset: CGFloat = -58
    static let timerDetailOffset: CGFloat = 54
    static let navigationHorizontalPadding: CGFloat = 10
    static let navigationTopPadding: CGFloat = 6
}

private struct CircularTimerFace<Title: View>: View {
    let diameter: CGFloat
    let time: String
    let detail: String?
    let progress: Double
    let isPaused: Bool
    let title: Title

    init(diameter: CGFloat,
         time: String,
         detail: String? = nil,
         progress: Double,
         isPaused: Bool = false,
         @ViewBuilder title: () -> Title) {
        self.diameter = diameter
        self.time = time
        self.detail = detail
        self.progress = progress.clamped(to: 0 ... 1)
        self.isPaused = isPaused
        self.title = title()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(TBDesignTokens.ColorToken.timerTrackShadow, lineWidth: 10)
                .frame(width: diameter - 8, height: diameter - 8)
            Circle()
                .stroke(TBDesignTokens.ColorToken.timerTrack, lineWidth: 4)
                .frame(width: diameter - 14, height: diameter - 14)
            Circle()
                .trim(from: progress >= 1 ? 0 : 1 - progress, to: 1)
                .stroke(progressColor,
                        style: StrokeStyle(lineWidth: 5,
                                           lineCap: .round,
                                           lineJoin: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter - 14, height: diameter - 14)
                .animation(TBDesignTokens.Animation.smooth, value: progress)
                .animation(TBDesignTokens.Animation.smooth, value: isPaused)

            VStack(spacing: 8) {
                title
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .offset(y: PopoverLayout.timerTitleOffset)

            Text(time)
                .font(.system(size: 43,
                              weight: .regular,
                              design: .rounded)
                    .monospacedDigit())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .padding(.horizontal, 18)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .offset(y: PopoverLayout.timerDetailOffset)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: diameter, height: diameter)
        .tbTimerFaceSurface()
        .animation(TBDesignTokens.Animation.smooth, value: detail ?? "")
    }

    private var progressColor: Color {
        isPaused ? TBDesignTokens.ColorToken.subduedText.opacity(0.65) : TBDesignTokens.ColorToken.accent
    }
}

private struct PresetPickerView: View {
    @ObservedObject var timer: TBTimer

    var body: some View {
        HStack {
            Text(NSLocalizedString("IntervalsView.presets.label", comment: "Presets label"))
                .frame(alignment: .leading)
            Spacer()
            Picker("", selection: presetIndexBinding) {
                Text("1").tag(0)
                Text("2").tag(1)
                Text("3").tag(2)
                Text("4").tag(3)
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .pickerStyle(.segmented)
        }
    }

    private var presetIndexBinding: Binding<Int> {
        Binding(
            get: { timer.selectedPresetIndex },
            set: { timer.selectedPresetIndex = $0 }
        )
    }
}

struct IntervalsView: View {
    @EnvironmentObject var timer: TBTimer
    private var minStr = NSLocalizedString("IntervalsView.min",
                                            comment: "Minute unit suffix. The number is shown separately.")

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 12) {
                intervalStepper(title: NSLocalizedString("IntervalsView.workIntervalLength.label",
                                                         comment: "Work interval label"),
                                value: presetBinding(\.workIntervalLength, range: 1 ... 120),
                                range: 1 ... 120,
                                suffix: minStr)
                intervalStepper(title: NSLocalizedString("IntervalsView.shortRestIntervalLength.label",
                                                         comment: "Short rest interval label"),
                                value: presetBinding(\.shortRestIntervalLength, range: 1 ... 120),
                                range: 1 ... 120,
                                suffix: minStr)
                intervalStepper(title: NSLocalizedString("IntervalsView.longRestIntervalLength.label",
                                                         comment: "Long rest interval label"),
                                value: presetBinding(\.longRestIntervalLength, range: 1 ... 120),
                                range: 1 ... 120,
                                suffix: minStr)
                    .help(NSLocalizedString("IntervalsView.longRestIntervalLength.help",
                                            comment: "Long rest interval hint"))
                intervalStepper(title: NSLocalizedString("IntervalsView.workIntervalsInSet.label",
                                                         comment: "Work intervals in a set label"),
                                value: presetBinding(\.workIntervalsInSet, range: 1 ... 10),
                                range: 1 ... 10)
                    .help(NSLocalizedString("IntervalsView.workIntervalsInSet.help",
                                            comment: "Work intervals in set hint"))
            }
            .frame(maxWidth: SettingsLayout.contentWidth)

            Divider()
                .frame(maxWidth: SettingsLayout.contentWidth)

            PresetPickerView(timer: timer)
                .frame(maxWidth: SettingsLayout.contentWidth)
        }
    }

    private func presetBinding(_ keyPath: WritableKeyPath<TimerPreset, Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { timer.currentPresetInstance[keyPath: keyPath] },
            set: { newValue in
                var preset = timer.currentPresetInstance
                preset[keyPath: keyPath] = newValue.clamped(to: range)
                timer.currentPresetInstance = preset
            }
        )
    }

    private func intervalStepper(title: String,
                                 value: Binding<Int>,
                                 range: ClosedRange<Int>,
                                 suffix: String? = nil) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("", value: value, formatter: clampedNumberFormatter(range: range))
                    .frame(width: 42, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                if let suffix = suffix {
                    Text(suffix)
                }
            }
        }
    }

    private func clampedNumberFormatter(range: ClosedRange<Int>) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.generatesDecimalNumbers = false
        formatter.maximumFractionDigits = 0
        return formatter
    }
}

struct TimerSettingsView: View {
    @ObservedObject var timer: TBTimer

    var body: some View {
        SettingsPane {
            SettingsRow(title: NSLocalizedString("SettingsView.showTimerInMenuBar.label",
                                                 comment: "Show timer in menu bar label")) {
                Toggle("", isOn: $timer.showTimerInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: timer.showTimerInMenuBar) { _ in
                        timer.updateTimeLeft()
                    }
            }
            SettingsSectionTitle(title: NSLocalizedString("SettingsView.fullScreenMask.section",
                                                            comment: "Full screen mask settings section"))
            SettingsRow(title: NSLocalizedString("SettingsView.showFullScreenMask.label",
                                                 comment: "show full screen mask on rest")) {
                Toggle("", isOn: $timer.showFullScreenMask)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(NSLocalizedString("SettingsView.showFullScreenMask.help",
                                            comment: "show full screen mask hint"))
                    .onChange(of: timer.showFullScreenMask) { enabled in
                        if !enabled {
                            timer.setStrictFullScreenMask(false)
                        }
                    }
            }
            SettingsRow(title: NSLocalizedString("SettingsView.strictFullScreenMask.label",
                                                 comment: "strict full screen mask on rest")) {
                Toggle("", isOn: Binding(get: {
                    timer.strictFullScreenMask
                }, set: { enabled in
                    timer.setStrictFullScreenMask(enabled)
                }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!timer.showFullScreenMask)
                    .help(NSLocalizedString("SettingsView.strictFullScreenMask.help",
                                            comment: "strict full screen mask hint"))
            }
            if timer.strictFullScreenMaskShortcutBlockingUnavailable {
                Text(NSLocalizedString("SettingsView.strictFullScreenMask.shortcutBlockingUnavailable",
                                       comment: "strict full screen mask shortcut blocking unavailable"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow(title: NSLocalizedString("SettingsView.strictFullScreenMaskPresentationLock.label",
                                                 comment: "strict full screen mask presentation lock label")) {
                Toggle("", isOn: $timer.strictFullScreenMaskPresentationLock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!timer.showFullScreenMask || !timer.strictFullScreenMask)
                    .help(NSLocalizedString("SettingsView.strictFullScreenMaskPresentationLock.help",
                                            comment: "strict full screen mask presentation lock hint"))
            }
            SettingsRow(title: NSLocalizedString("SettingsView.pauseAfterRestFinish.label",
                                                 comment: "Pause after rest finish label")) {
                Toggle("", isOn: $timer.pauseAfterRestFinish)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(NSLocalizedString("SettingsView.pauseAfterRestFinish.help",
                                            comment: "Pause after rest finish hint"))
            }
            SettingsRow(title: NSLocalizedString("SettingsView.extendWorkAfterFinish.label",
                                                 comment: "Extend work after finish label")) {
                Toggle("", isOn: $timer.extendWorkAfterFinish)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(NSLocalizedString("SettingsView.extendWorkAfterFinish.help",
                                            comment: "Extend work after finish hint"))
            }
        }
    }
}

struct ShortcutSettingsView: View {
    var body: some View {
        SettingsPane {
            SettingsRow(title: NSLocalizedString("SettingsView.shortcut.label",
                                                 comment: "Shortcut label")) {
                KeyboardShortcuts.Recorder(for: .startStopTimer) {
                    EmptyView()
                }
            }
            SettingsRow(title: NSLocalizedString("SettingsView.pauseShortcut.label",
                                                 comment: "Pause shortcut label")) {
                KeyboardShortcuts.Recorder(for: .pauseResumeTimer) {
                    EmptyView()
                }
            }
            SettingsRow(title: NSLocalizedString("SettingsView.skipShortcut.label",
                                                 comment: "Skip shortcut label")) {
                KeyboardShortcuts.Recorder(for: .skipTimer) {
                    EmptyView()
                }
            }
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var appearanceController: TBAppearanceController
    @ObservedObject private var launchAtLogin = LaunchAtLogin.observable

    var body: some View {
        SettingsPane {
            SettingsRow(title: NSLocalizedString("SettingsView.appearance.label",
                                                 comment: "Appearance setting label")) {
                AppearancePickerView(appearanceController: appearanceController)
            }
            SettingsRow(title: NSLocalizedString("SettingsView.launchAtLogin.label",
                                                 comment: "Launch at login label")) {
                Toggle("", isOn: $launchAtLogin.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

private struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        Slider(value: $volume, in: 0...2) {
            Text(String(format: "%.1f", volume))
        }.gesture(TapGesture(count: 2).onEnded({
            volume = 1.0
        }))
    }
}

struct SoundsView: View {
    @ObservedObject var player: TBPlayer

    init(player: TBPlayer) {
        self.player = player
    }

    private var columns = [
        GridItem(.flexible()),
        GridItem(.fixed(SettingsLayout.soundSliderWidth))
    ]

    var body: some View {
        SettingsPane {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("SoundsView.isWindupEnabled.label",
                                       comment: "Windup label"))
                VolumeSlider(volume: $player.windupVolume)
                Text(NSLocalizedString("SoundsView.isDingEnabled.label",
                                       comment: "Ding label"))
                VolumeSlider(volume: $player.dingVolume)
                Text(NSLocalizedString("SoundsView.isTickingEnabled.label",
                                       comment: "Ticking label"))
                VolumeSlider(volume: $player.tickingVolume)
            }
            .frame(maxWidth: SettingsLayout.contentWidth)
        }
    }
}

struct TBPopoverView: View {
    @ObservedObject var timer: TBTimer
    let openSettingsWindow: () -> Void
    let openStatsWindow: () -> Void
    let closePopover: () -> Void

    init(timer: TBTimer,
         openSettingsWindow: @escaping () -> Void,
         openStatsWindow: @escaping () -> Void,
         closePopover: @escaping () -> Void) {
        self.timer = timer
        self.openSettingsWindow = openSettingsWindow
        self.openStatsWindow = openStatsWindow
        self.closePopover = closePopover
    }

    private var focusLabel = NSLocalizedString("TBPopoverView.focus.label", comment: "Focus timer title")
    private var breakLabel = NSLocalizedString("TBPopoverView.break.label", comment: "Break timer title")
    private var presetFormat = NSLocalizedString("TBPopoverView.preset.format", comment: "Preset menu item format")
    private var presetMenuHelp = NSLocalizedString("TBPopoverView.presetMenu.help", comment: "Preset menu help")
    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")
    private var leaveLabel = NSLocalizedString("TBPopoverView.leave.label", comment: "Leave active timer label")
    private var pauseLabel = NSLocalizedString("TBPopoverView.pause.help", comment: "Pause hint")
    private var resumeLabel = NSLocalizedString("TBPopoverView.resume.help", comment: "Resume hint")
    private var skipLabel = NSLocalizedString("TBPopoverView.skip.help", comment: "Skip hint")
    private var startBreakLabel = NSLocalizedString("TBPopoverView.startBreak.label", comment: "Start break label")
    private var startWorkLabel = NSLocalizedString("TBPopoverView.startWork.label", comment: "Start work label")

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 3) {
                primaryContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                utilityFooter
            }

            popoverNavigationButtons
                .padding(.horizontal, PopoverLayout.navigationHorizontalPadding)
                .padding(.top, PopoverLayout.navigationTopPadding)
        }
        #if DEBUG
            /*
             After several hours of Googling and trying various StackOverflow
             recipes I still haven't figured a reliable way to auto resize
             popover to fit all it's contents (pull requests are welcome!).
             The following code block is used to determine the optimal
             geometry of the popover.
             */
            .overlay(
                GeometryReader { proxy in
                    debugSize(proxy: proxy)
                }
            )
        #endif
            .frame(width: PopoverLayout.width, height: PopoverLayout.height)
            .fixedSize()
            .padding(12)
            .tbGlassPopoverBackground()
            .background(
                Button("") { closePopover() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            )
    }

    @ViewBuilder
    private var primaryContent: some View {
        timerContent(time: timerFaceTime,
                     detail: timerFaceDetail,
                     progress: timerFaceProgress,
                     isPaused: timer.paused) {
            timerFaceTitle
        } controls: {
            timerFaceControls
        }
    }

    @ViewBuilder
    private var timerFaceTitle: some View {
        if timer.controlMode == .inactive {
            inactivePresetMenu
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            timerTitleText(activeTimerTitle)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private func timerContent<Title: View, Controls: View>(time: String,
                                                           detail: String?,
                                                           progress: Double,
                                                           isPaused: Bool,
                                                           @ViewBuilder title: () -> Title,
                                                           @ViewBuilder controls: () -> Controls) -> some View {
        VStack(spacing: 16) {
            CircularTimerFace(diameter: PopoverLayout.timerCircleDiameter,
                              time: time,
                              detail: detail,
                              progress: progress,
                              isPaused: isPaused) {
                title()
            }
            controls()

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .animation(TBDesignTokens.Animation.smooth, value: timer.controlMode)
        .animation(TBDesignTokens.Animation.smooth, value: timer.timeLeftString)
        .animation(TBDesignTokens.Animation.smooth, value: timerFaceDetail ?? "")
    }

    private var popoverNavigationButtons: some View {
        HStack(alignment: .center) {
            OpenStatsButton(action: openStatsWindow)
                .help(NSLocalizedString("TBPopoverView.stats.help", comment: "Stats button help"))
                .accessibilityLabel(Text(NSLocalizedString("TBPopoverView.stats.help",
                                                           comment: "Stats button accessibility label")))
            Spacer()
            OpenSettingsButton(action: openSettingsWindow)
                .help(NSLocalizedString("TBPopoverView.settings.help", comment: "Settings button help"))
                .accessibilityLabel(Text(NSLocalizedString("TBPopoverView.settings.help",
                                                           comment: "Settings button accessibility label")))
        }
    }

    private var inactivePresetMenu: some View {
        Menu {
            ForEach(0..<4, id: \.self) { index in
                Button {
                    timer.selectedPresetIndex = index
                } label: {
                    if index == timer.selectedPresetIndex {
                        Label(presetName(for: index), systemImage: "checkmark")
                    } else {
                        Text(presetName(for: index))
                    }
                }
            }
        } label: {
            inactiveTimerTitle
        }
        .menuStyle(BorderlessButtonMenuStyle(showsMenuIndicator: false))
        .fixedSize()
        .help(presetMenuHelp)
        .accessibilityLabel(Text(presetMenuHelp))
    }

    private var inactiveTimerTitle: some View {
        timerTitleText(focusLabel)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
                    .offset(x: 19)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                    .accessibilityHidden(true)
            }
            .animation(TBDesignTokens.Animation.smooth, value: timer.controlMode)
    }

    private func timerTitleText(_ title: String) -> some View {
        Text(title)
            .foregroundColor(.primary)
    }

    private var utilityFooter: some View {
        HStack(spacing: 16) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel()
            } label: {
                Text(NSLocalizedString("TBPopoverView.about.label",
                                       comment: "About label"))
            }
            .tbGlassCapsuleButton(horizontalPadding: 9, verticalPadding: 4)

            Button {
                NSApplication.shared.terminate(self)
            } label: {
                Text(NSLocalizedString("TBPopoverView.quit.label",
                                       comment: "Quit label"))
            }
            .tbGlassCapsuleButton(horizontalPadding: 9, verticalPadding: 4)
            .disabled(timer.strictFullScreenMaskActive)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var activeActionBar: some View {
        HStack(spacing: 12) {
            timerControlButtons
        }
    }

    @ViewBuilder
    private var timerFaceControls: some View {
        if timer.controlMode == .inactive {
            startButton(minWidth: 108)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            activeActionBar
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private var timerFaceTime: String {
        timer.controlMode == .inactive ? inactiveDurationString : timer.timeLeftString
    }

    private var timerFaceProgress: Double {
        timer.controlMode == .inactive ? 1 : timer.remainingTimeProgress
    }

    private var timerFaceDetail: String? {
        timer.controlMode == .inactive ? nil : activeIntervalDetail
    }

    private var activeIntervalDetail: String? {
        if timer.sessionPresetInstance.workIntervalsInSet > 1 {
            return "\(timer.currentWorkInterval)/\(timer.sessionPresetInstance.workIntervalsInSet)"
        }
        return nil
    }

    private var inactiveDurationString: String {
        TimerCore.clockString(from: TimeInterval(timer.currentPresetInstance.workIntervalLength * 60))
    }

    private var activeTimerTitle: String {
        switch timer.controlMode {
        case .restRunning, .restPaused:
            return breakLabel
        case .inactive, .workRunning, .workPaused, .workExtended, .workFinishedPendingBreak, .workStartPending:
            return focusLabel
        }
    }

    private func presetName(for index: Int) -> String {
        String(format: presetFormat, index + 1)
    }

    @ViewBuilder
    private var timerControlButtons: some View {
        if timer.strictFullScreenMaskActive {
            EmptyView()
        } else {
            switch timer.controlMode {
            case .inactive:
                startButton()
            case .workExtended, .workFinishedPendingBreak:
                stopButton
                startBreakButton
            case .workStartPending:
                stopButton
                startWorkButton
            case .workRunning, .workPaused, .restRunning, .restPaused:
                stopButton
                pauseResumeButton
                skipButton
            }
        }
    }

    private func startButton(minWidth: CGFloat = 88) -> some View {
        Button {
            timer.startStop()
        } label: {
            Text(startLabel)
        }
        .popoverActionStyle(role: .primary, minWidth: minWidth)
        .keyboardShortcut(.defaultAction)
    }

    private var stopButton: some View {
        Button {
            timer.startStop()
        } label: {
            Text(leaveLabel)
        }
        .popoverActionStyle(role: .destructiveQuiet, minWidth: 62)
        .help(stopLabel)
    }

    private var startBreakButton: some View {
        Button {
            timer.startBreak()
        } label: {
            Text(startBreakLabel)
        }
        .popoverActionStyle(role: .primary, minWidth: 118)
        .keyboardShortcut(.defaultAction)
    }

    private var startWorkButton: some View {
        Button {
            timer.startWork()
        } label: {
            Text(startWorkLabel)
        }
        .popoverActionStyle(role: .primary, minWidth: 112)
        .keyboardShortcut(.defaultAction)
    }

    private var skipButton: some View {
        Button {
            timer.skip()
        } label: {
            Image(systemName: "forward.fill")
                .frame(width: 20)
        }
        .popoverActionStyle(role: .secondary, minWidth: 48)
        .help(skipLabel)
        .accessibilityLabel(Text(skipLabel))
    }

    private var pauseResumeButton: some View {
        Button {
            timer.pauseResume()
        } label: {
            Image(systemName: timer.paused ? "play.fill" : "pause.fill")
                .frame(width: 20)
        }
        .popoverActionStyle(role: .secondary, minWidth: 48)
        .help(timer.paused ? resumeLabel : pauseLabel)
        .accessibilityLabel(Text(timer.paused ? resumeLabel : pauseLabel))
    }
}

private extension View {
    func popoverActionStyle(role: TBPopoverButtonRole = .secondary,
                            minWidth: CGFloat) -> some View {
        tbPopoverButton(role: role, minWidth: minWidth)
            .controlSize(.regular)
    }
}

#if DEBUG
    func debugSize(proxy: GeometryProxy) -> some View {
        print("Optimal popover size:", proxy.size)
        return Color.clear
    }
#endif

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

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

extension StopAfterOption: DropdownDescribable {
    var localizedDescription: String {
        switch self {
        case .disabled:
            return NSLocalizedString("SettingsView.dropdownDisabled.label", comment: "Disabled label")
        case .work:
            return NSLocalizedString("SettingsView.dropdownWork.label", comment: "Work label")
        case .rest:
            return NSLocalizedString("SettingsView.dropdownBreak.label", comment: "Break label")
        case .set:
            return NSLocalizedString("SettingsView.dropdownSet.label", comment: "Set label")
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
    static let windowHeight: CGFloat = 460
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
    }
}

private struct OpenStatsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chart.bar")
        }
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
            SettingsRow(title: NSLocalizedString("SettingsView.stopAfter.label",
                                                 comment: "Stop after label")) {
                SegmentedDropdown(value: $timer.stopAfter)
            }
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
            if timer.strictFullScreenMaskPermissionRequired {
                Text(NSLocalizedString("SettingsView.strictFullScreenMask.permissionRequired",
                                       comment: "strict full screen mask permission required"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    init(timer: TBTimer,
         openSettingsWindow: @escaping () -> Void,
         openStatsWindow: @escaping () -> Void) {
        self.timer = timer
        self.openSettingsWindow = openSettingsWindow
        self.openStatsWindow = openStatsWindow
    }

    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")
    private var pauseLabel = NSLocalizedString("TBPopoverView.pause.help", comment: "Pause hint")
    private var resumeLabel = NSLocalizedString("TBPopoverView.resume.help", comment: "Resume hint")
    private var skipLabel = NSLocalizedString("TBPopoverView.skip.help", comment: "Skip hint")
    private var startBreakLabel = NSLocalizedString("TBPopoverView.startBreak.label", comment: "Start break label")
    private var startWorkLabel = NSLocalizedString("TBPopoverView.startWork.label", comment: "Start work label")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 4) {
                timerControlButtons

                OpenStatsButton(action: openStatsWindow)
                    .controlSize(.large)
                    .help(NSLocalizedString("TBPopoverView.stats.help", comment: "Stats button help"))

                OpenSettingsButton(action: openSettingsWindow)
                    .controlSize(.large)
                    .help(NSLocalizedString("TBPopoverView.settings.help", comment: "Settings button help"))
            }

            if timer.controlMode != .inactive {
                Text(timerDisplayString())
                    .font(.system(.body).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            PresetPickerView(timer: timer)

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel()
            } label: {
                Text(NSLocalizedString("TBPopoverView.about.label",
                                       comment: "About label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                NSApplication.shared.terminate(self)
            } label: {
                Text(NSLocalizedString("TBPopoverView.quit.label",
                                       comment: "Quit label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(timer.strictFullScreenMaskActive)
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
            .frame(width: 255)
            .fixedSize()
            .padding(12)
    }

    private func timerDisplayString() -> String {
        var result = timer.timeLeftString
        if timer.sessionPresetInstance.workIntervalsInSet > 1,
           timer.stopAfter == .disabled || timer.stopAfter == .set {
            result += " (\(timer.currentWorkInterval)/\(timer.sessionPresetInstance.workIntervalsInSet))"
        }
        return result
    }

    @ViewBuilder
    private var timerControlButtons: some View {
        if timer.strictFullScreenMaskActive {
            EmptyView()
        } else {
            switch timer.controlMode {
            case .inactive:
                startButton
            case .workExtended:
                stopButton
                startBreakButton
            case .workStartPending:
                stopButton
                startWorkButton
            case .workRunning, .workPaused, .restRunning, .restPaused:
                stopButton
                skipButton
                pauseResumeButton
            }
        }
    }

    private var startButton: some View {
        Button {
            timer.startStop()
        } label: {
            Text(startLabel)
                .foregroundColor(Color.white)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private var stopButton: some View {
        Button {
            timer.startStop()
        } label: {
            Text(stopLabel)
                .foregroundColor(Color.white)
        }
        .controlSize(.large)
    }

    private var startBreakButton: some View {
        Button {
            timer.startBreak()
        } label: {
            Text(startBreakLabel)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private var startWorkButton: some View {
        Button {
            timer.startWork()
        } label: {
            Text(startWorkLabel)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private var skipButton: some View {
        Button {
            timer.skip()
        } label: {
            Image(systemName: "forward.circle.fill")
        }
        .controlSize(.large)
        .help(skipLabel)
    }

    private var pauseResumeButton: some View {
        Button {
            timer.pauseResume()
        } label: {
            Image(systemName: timer.paused ? "play.circle.fill" : "pause.circle.fill")
        }
        .controlSize(.large)
        .help(timer.paused ? resumeLabel : pauseLabel)
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

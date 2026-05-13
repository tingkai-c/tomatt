import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

extension KeyboardShortcuts.Name {
    static let startStopTimer = Self("startStopTimer")
    static let pauseResumeTimer = Self("pauseResumeTimer")
    static let skipTimer = Self("skipTimer")
}

private protocol DropdownDescribable: RawRepresentable where RawValue == String { }

extension StopAfterOption: DropdownDescribable { }

private extension DropdownDescribable {
    var description: String {
        switch rawValue {
        case "disabled":
            return NSLocalizedString("SettingsView.dropdownDisabled.label", comment: "Disabled label")
        case "work":
            return NSLocalizedString("SettingsView.dropdownWork.label", comment: "Work label")
        case "rest":
            return NSLocalizedString("SettingsView.dropdownBreak.label", comment: "Break label")
        case "set":
            return NSLocalizedString("SettingsView.dropdownSet.label", comment: "Set label")
        default:
            return rawValue
        }
    }
}

private struct SegmentedDropdown<E: CaseIterable & Hashable & DropdownDescribable>: View where E.RawValue == String, E.AllCases: RandomAccessCollection {
    @Binding var value: E

    var body: some View {
        Picker("", selection: $value) {
            ForEach(E.allCases, id: \.self) { option in
                Text(option.description).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}

private struct IntervalsView: View {
    @EnvironmentObject var timer: TBTimer
    private var minStr = NSLocalizedString("IntervalsView.min", comment: "Minute unit suffix. The number is shown separately.")

    var body: some View {
        VStack {
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
            Spacer().frame(minHeight: 0)
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
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }

    private var presetIndexBinding: Binding<Int> {
        Binding(
            get: { timer.selectedPresetIndex },
            set: { timer.selectedPresetIndex = $0 }
        )
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

private struct SettingsView: View {
    @EnvironmentObject var timer: TBTimer
    @ObservedObject private var launchAtLogin = LaunchAtLogin.observable

    var body: some View {
        VStack {
            KeyboardShortcuts.Recorder(for: .startStopTimer) {
                Text(NSLocalizedString("SettingsView.shortcut.label",
                                       comment: "Shortcut label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            KeyboardShortcuts.Recorder(for: .pauseResumeTimer) {
                Text(NSLocalizedString("SettingsView.pauseShortcut.label",
                                       comment: "Pause shortcut label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            KeyboardShortcuts.Recorder(for: .skipTimer) {
                Text(NSLocalizedString("SettingsView.skipShortcut.label",
                                       comment: "Skip shortcut label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(NSLocalizedString("SettingsView.stopAfter.label",
                                       comment: "Stop after label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                SegmentedDropdown(value: $timer.stopAfter)
            }
            Toggle(isOn: $timer.showTimerInMenuBar) {
                Text(NSLocalizedString("SettingsView.showTimerInMenuBar.label",
                                       comment: "Show timer in menu bar label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
                .onChange(of: timer.showTimerInMenuBar) { _ in
                    timer.updateTimeLeft()
                }
            Toggle(isOn: $timer.showFullScreenMask) {
                Text(NSLocalizedString("SettingsView.showFullScreenMask.label",
                                       comment: "show full screen mask on rest"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
                .help(NSLocalizedString("SettingsView.showFullScreenMask.help",
                                        comment: "show full screen mask hint"))
            Toggle(isOn: $launchAtLogin.isEnabled) {
                Text(NSLocalizedString("SettingsView.launchAtLogin.label",
                                       comment: "Launch at login label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Spacer().frame(minHeight: 0)
            Divider()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel()
            } label: {
                Text(NSLocalizedString("TBPopoverView.about.label",
                                       comment: "About label"))
                Spacer()
                Text("⌘ A").foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a")
            Button {
                NSApplication.shared.terminate(self)
            } label: {
                Text(NSLocalizedString("TBPopoverView.quit.label",
                                       comment: "Quit label"))
                Spacer()
                Text("⌘ Q").foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(4)
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

private struct SoundsView: View {
    @EnvironmentObject var player: TBPlayer

    private var columns = [
        GridItem(.flexible()),
        GridItem(.fixed(110))
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("SoundsView.isWindupEnabled.label",
                                   comment: "Windup label"))
            VolumeSlider(volume: $player.windupVolume)
            Text(NSLocalizedString("SoundsView.isDingEnabled.label",
                                   comment: "Ding label"))
            VolumeSlider(volume: $player.dingVolume)
            Text(NSLocalizedString("SoundsView.isTickingEnabled.label",
                                   comment: "Ticking label"))
            VolumeSlider(volume: $player.tickingVolume)
        }.padding(4)
        Spacer().frame(minHeight: 0)
    }
}

private enum ChildView {
    case intervals, settings, sounds
}

struct TBPopoverView: View {
    @ObservedObject var timer = TBTimer()
    @State private var buttonHovered = false
    @State private var activeChildView = ChildView.intervals

    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")
    private var pauseLabel = NSLocalizedString("TBPopoverView.pause.help", comment: "Pause hint")
    private var resumeLabel = NSLocalizedString("TBPopoverView.resume.help", comment: "Resume hint")
    private var skipLabel = NSLocalizedString("TBPopoverView.skip.help", comment: "Skip hint")
    private let childViewMinHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    timer.startStop()
                    TBStatusItem.shared.closePopover(nil)
                } label: {
                    Text(timer.timer != nil ?
                         (buttonHovered ? stopLabel : timerDisplayString()) :
                            startLabel)
                        /*
                          When appearance is set to "Dark" and accent color is set to "Graphite"
                          "defaultAction" button label's color is set to the same color as the
                          button, making the button look blank. #24
                         */
                        .foregroundColor(Color.white)
                        .font(.system(.body).monospacedDigit())
                        .frame(maxWidth: .infinity)
                }
                .onHover { over in
                    buttonHovered = over
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                if timer.timer != nil {
                    Button {
                        timer.pauseResume()
                        TBStatusItem.shared.closePopover(nil)
                    } label: {
                        Image(systemName: timer.paused ? "play.circle.fill" : "pause.circle.fill")
                    }
                    .controlSize(.large)
                    .help(timer.paused ? resumeLabel : pauseLabel)

                    Button {
                        timer.skip()
                        TBStatusItem.shared.closePopover(nil)
                    } label: {
                        Image(systemName: "forward.circle.fill")
                    }
                    .controlSize(.large)
                    .help(skipLabel)
                }
            }

            Picker("", selection: $activeChildView) {
                Text(NSLocalizedString("TBPopoverView.intervals.label",
                                       comment: "Intervals label")).tag(ChildView.intervals)
                Text(NSLocalizedString("TBPopoverView.settings.label",
                                       comment: "Settings label")).tag(ChildView.settings)
                Text(NSLocalizedString("TBPopoverView.sounds.label",
                                       comment: "Sounds label")).tag(ChildView.sounds)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .pickerStyle(.segmented)

            GroupBox {
                switch activeChildView {
                case .intervals:
                    IntervalsView().environmentObject(timer)
                case .settings:
                    SettingsView().environmentObject(timer)
                case .sounds:
                    SoundsView().environmentObject(timer.player)
                }
            }
            .frame(minHeight: childViewMinHeight, alignment: .top)

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

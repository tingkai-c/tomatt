import SwiftUI
import LaunchAtLogin
import Settings

extension NSImage.Name {
    static let idle = Self("BarIconIdle")
    static let work = Self("BarIconWork")
    static let shortRest = Self("BarIconShortRest")
    static let longRest = Self("BarIconLongRest")
    static let pause = Self("BarIconPause")
}

private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)

enum TBAppearanceMode: String, CaseIterable, Codable {
    case system, light, dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

final class TBAppearanceController: ObservableObject {
    private let managedWindows = NSHashTable<NSWindow>.weakObjects()

    @AppStorage("appearanceMode") private var storedMode = TBAppearanceMode.system.rawValue

    var mode: TBAppearanceMode {
        get { TBAppearanceMode(rawValue: storedMode) ?? .system }
        set {
            guard newValue != mode else { return }
            objectWillChange.send()
            storedMode = newValue.rawValue
            applyToManagedWindows()
        }
    }

    func registerManagedWindow(_ window: NSWindow?) {
        guard let window = window else { return }
        // Register app-owned windows here instead of using global app/window
        // sweeps or status-bar button appearance. Break-mask overlay windows
        // and standard AppKit panels are intentionally unmanaged.
        managedWindows.add(window)
        apply(to: window)
    }

    private func applyToManagedWindows() {
        managedWindows.allObjects.forEach { apply(to: $0) }
    }

    private func apply(to window: NSWindow) {
        window.appearance = mode.nsAppearance
    }
}

@main
struct TBApp: App {
    @NSApplicationDelegateAdaptor(TBStatusItem.self) var appDelegate

    init() {
        TBStatusItem.shared = appDelegate
        LaunchAtLogin.migrateIfNeeded()
        logger.append(event: TBLogEventAppStart())
    }

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("TBPopoverView.settings.label",
                                         comment: "Settings menu item")) {
                    TBStatusItem.shared.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private extension AppSettings.PaneIdentifier {
    static let timer = Self("timer")
    static let presets = Self("presets")
    static let sounds = Self("sounds")
    static let shortcuts = Self("shortcuts")
    static let general = Self("general")
}

class TBStatusItem: NSObject, NSApplicationDelegate {
    let timer = TBTimer()
    let appearanceController = TBAppearanceController()
    private var popover = NSPopover()
    private var statusBarItem: NSStatusItem?
    private var statsWindowController: NSWindowController?
    private var settingsWindowController: SettingsWindowController?
    static var shared: TBStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        let view = TBPopoverView(timer: timer,
                                 openSettingsWindow: { [weak self] in
                                     self?.openSettingsWindow()
                                 },
                                 openStatsWindow: { [weak self] in
                                     self?.openStatsWindow()
                                 })

        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSHostingView(rootView: view)
        if let contentViewController = popover.contentViewController {
            popover.contentSize.height = contentViewController.view.intrinsicContentSize.height
            popover.contentSize.width = contentViewController.view.intrinsicContentSize.width
        }

        statusBarItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusBarItem?.button?.imagePosition = .imageLeft
        setIcon(name: .idle)
        statusBarItem?.button?.action = #selector(TBStatusItem.togglePopover(_:))
        timer.restoreTimerIfNeeded()
    }

    func setTitle(title: String?) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 0.9
        paragraphStyle.alignment = NSTextAlignment.center

        let attributedTitle = NSAttributedString(
            string: title != nil ? " \(title!)" : "",
            attributes: [
                NSAttributedString.Key.font: digitFont,
                NSAttributedString.Key.paragraphStyle: paragraphStyle
            ]
        )
        statusBarItem?.button?.attributedTitle = attributedTitle
    }

    func setIcon(name: NSImage.Name) {
        statusBarItem?.button?.image = NSImage(named: name)
    }

    func showPopover(_: AnyObject?) {
        if let button = statusBarItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            appearanceController.registerManagedWindow(popover.contentViewController?.view.window)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func openSettingsWindow() {
        closePopover(nil)

        // Closing an NSPopover from inside one of its button actions can briefly
        // consume the current activation event. Present Settings on the next run
        // loop so the LSUIElement app can activate and order a real window front.
        DispatchQueue.main.async { [weak self] in
            self?.presentSettingsWindow()
        }
    }

    private func presentSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }

        settingsWindowController?.show()
        if let window = settingsWindowController?.window {
            appearanceController.registerManagedWindow(window)
            window.orderFrontRegardless()
        } else {
            logger.append(event: TBLogEventSettingsOpenFailed())
        }
    }

    private func makeSettingsWindowController() -> SettingsWindowController {
        SettingsWindowController(
            panes: [
                AppSettings.Pane(
                    identifier: .timer,
                    title: NSLocalizedString("SettingsWindow.timer.tab", comment: "Timer settings tab"),
                    toolbarIcon: toolbarIcon(systemName: "timer")
                ) {
                    TimerSettingsView(timer: timer)
                },
                AppSettings.Pane(
                    identifier: .presets,
                    title: NSLocalizedString("SettingsWindow.presets.tab", comment: "Presets settings tab"),
                    toolbarIcon: toolbarIcon(systemName: "slider.horizontal.3")
                ) {
                    IntervalsView()
                        .environmentObject(timer)
                },
                AppSettings.Pane(
                    identifier: .sounds,
                    title: NSLocalizedString("SettingsWindow.sounds.tab", comment: "Sounds settings tab"),
                    toolbarIcon: toolbarIcon(systemName: "speaker.wave.2")
                ) {
                    SoundsView(player: timer.player)
                },
                AppSettings.Pane(
                    identifier: .shortcuts,
                    title: NSLocalizedString("SettingsWindow.shortcuts.tab", comment: "Shortcuts settings tab"),
                    toolbarIcon: toolbarIcon(systemName: "keyboard")
                ) {
                    ShortcutSettingsView()
                },
                AppSettings.Pane(
                    identifier: .general,
                    title: NSLocalizedString("SettingsWindow.general.tab", comment: "General settings tab"),
                    toolbarIcon: toolbarIcon(systemName: "gearshape")
                ) {
                    GeneralSettingsView(appearanceController: appearanceController)
                }
            ],
            style: .toolbarItems
        )
    }

    private func toolbarIcon(systemName: String) -> NSImage {
        NSImage(systemSymbolName: systemName, accessibilityDescription: systemName) ?? NSImage()
    }

    func openStatsWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = statsWindowController?.window {
            appearanceController.registerManagedWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = TBStatsWindowView(store: TBStatsStore.shared)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = NSLocalizedString("StatsWindow.title", comment: "Stats window title")
        window.contentView = NSHostingView(rootView: view)
        appearanceController.registerManagedWindow(window)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        statsWindowController = controller
        controller.showWindow(nil)
    }

    func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }
}

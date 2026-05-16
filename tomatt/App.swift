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
    private var popupController: TBMenuBarPopupController?
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
                                 },
                                 closePopover: { [weak self] in
                                     self?.closePopover(nil)
                                 })

        popupController = TBMenuBarPopupController(rootView: view,
                                                   appearanceController: appearanceController)

        statusBarItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusBarItem?.button?.imagePosition = .imageLeft
        setIcon(name: .idle)
        statusBarItem?.button?.action = #selector(TBStatusItem.togglePopover(_:))
        if timer.strictFullScreenMask {
            _ = MaskHelper.shared.requestStrictKeyboardCaptureAccessIfNeeded()
        }
        timer.restoreTimerIfNeeded()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        timer.strictFullScreenMaskActive ? .terminateCancel : .terminateNow
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
        guard let button = statusBarItem?.button else { return }
        popupController?.show(relativeTo: button)
    }

    func openSettingsWindow() {
        closePopover(nil)

        // Present Settings on the next run loop so the LSUIElement app can
        // activate and order a real window front after an in-popup click.
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
        popupController?.close()
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popupController?.isShown == true {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }
}

private final class TBMenuBarPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TBMenuBarPopupController {
    private let hostingView: NSHostingView<AnyView>
    private weak var appearanceController: TBAppearanceController?
    private var panel: TBMenuBarPopupPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appDeactivateObserver: NSObjectProtocol?
    private weak var statusButton: NSStatusBarButton?
    private var statusButtonScreenFrame: NSRect = .zero

    var isShown: Bool {
        panel?.isVisible == true
    }

    init<Content: View>(rootView: Content, appearanceController: TBAppearanceController) {
        self.hostingView = NSHostingView(rootView: AnyView(rootView))
        self.appearanceController = appearanceController
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        if isShown {
            close()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let panel = makePanelIfNeeded()
        statusButton = button
        button.highlight(true)
        statusButtonScreenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let contentSize = NSSize(width: max(fittingSize.width, 1),
                                 height: max(fittingSize.height, 1))
        panel.setContentSize(contentSize)
        panel.setFrameOrigin(origin(for: panel.frame.size,
                                    anchoredTo: statusButtonScreenFrame,
                                    on: buttonWindow.screen))
        appearanceController?.registerManagedWindow(panel)

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        installDismissHandlers()
    }

    func close() {
        removeDismissHandlers()
        statusButton?.highlight(false)
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> TBMenuBarPopupPanel {
        if let panel {
            return panel
        }

        let panel = TBMenuBarPopupPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.contentView = hostingView
        panel.title = "tomatt"
        self.panel = panel
        return panel
    }

    private func origin(for panelSize: NSSize,
                        anchoredTo buttonFrame: NSRect,
                        on screen: NSScreen?) -> NSPoint {
        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferredX = buttonFrame.midX - (panelSize.width / 2)
        let preferredY = buttonFrame.minY - panelSize.height - 6
        let maxX = screenFrame.maxX - panelSize.width - 6
        let minX = screenFrame.minX + 6
        let minY = screenFrame.minY + 6

        return NSPoint(x: min(max(preferredX, minX), maxX),
                       y: max(preferredY, minY))
    }

    private func installDismissHandlers() {
        removeDismissHandlers()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let location = NSEvent.mouseLocation

            if panel.frame.contains(location) || self.statusButtonScreenFrame.contains(location) {
                return event
            }

            self.close()
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.close()
            }
        }

        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func removeDismissHandlers() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let appDeactivateObserver {
            NotificationCenter.default.removeObserver(appDeactivateObserver)
            self.appDeactivateObserver = nil
        }
    }

    deinit {
        removeDismissHandlers()
    }
}

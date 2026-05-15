import Cocoa

final class MaskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MaskHelper {
    static let shared = MaskHelper()

    private var windowControllers = [NSWindowController]()
    private var skipHandler: (() -> Void)?
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var strictKeyboardMonitor: Any?
    private var strictKeyboardEventTap: CFMachPort?
    private var strictKeyboardEventTapRunLoopSource: CFRunLoopSource?

    private init() {}

    var hasStrictKeyboardCaptureAccess: Bool {
        let hasListenAccess: Bool
        if #available(macOS 10.15, *) {
            hasListenAccess = CGPreflightListenEventAccess()
        } else {
            hasListenAccess = true
        }
        return hasListenAccess && AXIsProcessTrusted()
    }

    @discardableResult
    func requestStrictKeyboardCaptureAccessIfNeeded() -> Bool {
        if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }

        let accessibilityOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(accessibilityOptions)
        return hasStrictKeyboardCaptureAccess
    }

    @discardableResult
    func showMaskWindow(desc: String, strict: Bool = false, skipHandler: (() -> Void)? = nil) -> Bool {
        hideMaskWindow(animated: false)
        let effectiveStrict: Bool
        if strict {
            effectiveStrict = installStrictKeyboardCapture()
            if effectiveStrict {
                applyStrictPresentationLock()
            } else {
                NSLog("tomatt strict keyboard capture failed")
            }
        } else {
            effectiveStrict = false
        }
        self.skipHandler = effectiveStrict ? nil : skipHandler

        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let window = MaskWindow(contentRect: screen.frame,
                                    styleMask: .borderless,
                                    backing: .buffered,
                                    defer: false)
            configureMaskWindow(window, for: screen)

            let maskFrame = NSRect(origin: .zero, size: screen.frame.size)
            let maskView = MaskView(desc: desc, frame: maskFrame, strict: effectiveStrict) { [weak self] shouldSkip in
                if shouldSkip {
                    self?.consumeSkipHandler()
                }
                self?.hideMaskWindow()
            }
            window.contentView = maskView

            let windowController = NSWindowController(window: window)
            windowControllers.append(windowController)
            windowController.showWindow(nil)
            window.orderFrontRegardless()
            maskView.show()
        }

        focusFrontmostMaskWindow()
        return effectiveStrict
    }

    func hideMaskWindow(animated: Bool = true) {
        skipHandler = nil
        removeStrictKeyboardCapture()
        restorePresentationOptions()
        let controllers = windowControllers
        windowControllers.removeAll()
        for controller in controllers {
            guard animated, let mask = controller.window?.contentView as? MaskView else {
                controller.close()
                continue
            }
            mask.hide { controller.close() }
        }
    }

    private func configureMaskWindow(_ window: NSWindow, for screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
    }

    private func focusFrontmostMaskWindow() {
        guard let keyWindow = windowControllers.first?.window else { return }
        keyWindow.makeKeyAndOrderFront(nil)
        keyWindow.makeFirstResponder(keyWindow.contentView)
        windowControllers.dropFirst().forEach { $0.window?.orderFrontRegardless() }
    }

    private func installStrictKeyboardCapture() -> Bool {
        guard installStrictKeyboardEventTapIfPossible() else { return false }

        guard strictKeyboardMonitor == nil else { return true }
        strictKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in
            nil
        }
        return true
    }

    private func installStrictKeyboardEventTapIfPossible() -> Bool {
        guard strictKeyboardEventTap == nil else { return true }

        let eventMask = [CGEventType.keyDown, .keyUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        for tapLocation in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            guard let eventTap = CGEvent.tapCreate(tap: tapLocation,
                                                   place: .headInsertEventTap,
                                                   options: .defaultTap,
                                                   eventsOfInterest: eventMask,
                                                   callback: strictKeyboardEventTapCallback,
                                                   userInfo: userInfo),
                  let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
                continue
            }
            strictKeyboardEventTap = eventTap
            strictKeyboardEventTapRunLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        return false
    }

    fileprivate func reenableStrictKeyboardEventTap() {
        guard let strictKeyboardEventTap else { return }
        CGEvent.tapEnable(tap: strictKeyboardEventTap, enable: true)
    }

    private func removeStrictKeyboardCapture() {
        if let strictKeyboardMonitor {
            NSEvent.removeMonitor(strictKeyboardMonitor)
            self.strictKeyboardMonitor = nil
        }
        if let strictKeyboardEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), strictKeyboardEventTapRunLoopSource, .commonModes)
            self.strictKeyboardEventTapRunLoopSource = nil
        }
        if let strictKeyboardEventTap {
            CFMachPortInvalidate(strictKeyboardEventTap)
            self.strictKeyboardEventTap = nil
        }
    }

    private func applyStrictPresentationLock() {
        guard previousPresentationOptions == nil else { return }
        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = NSApp.presentationOptions.union([
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication
        ])
    }

    private func restorePresentationOptions() {
        guard let previousPresentationOptions else { return }
        NSApp.presentationOptions = previousPresentationOptions
        self.previousPresentationOptions = nil
    }

    private func consumeSkipHandler() {
        let handler = skipHandler
        skipHandler = nil
        handler?()
    }
}


private let strictKeyboardEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon {
            Unmanaged<MaskHelper>.fromOpaque(refcon).takeUnretainedValue().reenableStrictKeyboardEventTap()
        }
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown, .keyUp, .flagsChanged:
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

final class MaskView: NSView {
    private let actionHandler: (Bool) -> Void
    private let strict: Bool
    private var clickTimer: Timer?
    private var hideCompletion: (() -> Void)?

    private lazy var blurEffect: NSVisualEffectView = {
        let blurEffect = NSVisualEffectView(frame: bounds)
        blurEffect.autoresizingMask = [.width, .height]
        blurEffect.alphaValue = 0.9
        // The break mask is a dimming overlay and intentionally remains dark
        // regardless of the app appearance preference.
        blurEffect.appearance = NSAppearance(named: .vibrantDark)
        blurEffect.blendingMode = .behindWindow
        blurEffect.state = .inactive
        return blurEffect
    }()

    private lazy var titleLabel: NSTextField = {
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.textColor = .white.withAlphaComponent(0.8)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 28)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        return titleLabel
    }()

    private lazy var tipLabel: NSTextField = {
        let key = strict ? "TBMask.strict.label" : "TBMask.skip.label"
        let tipLabel = NSTextField(labelWithString: NSLocalizedString(key, comment: "Mask instruction label"))
        tipLabel.textColor = .white.withAlphaComponent(0.8)
        tipLabel.font = NSFont.systemFont(ofSize: 18)
        tipLabel.alignment = .center
        tipLabel.translatesAutoresizingMaskIntoConstraints = false
        return tipLabel
    }()

    init(desc: String, frame: NSRect, strict: Bool, actionHandler: @escaping (Bool) -> Void) {
        self.actionHandler = actionHandler
        self.strict = strict
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        titleLabel.stringValue = desc
        setupSubviews()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        addSubview(blurEffect)
        addSubview(titleLabel)
        addSubview(tipLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            titleLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9),
            tipLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            tipLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            tipLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9)
        ])
    }

    override func keyDown(with event: NSEvent) {}

    override func keyUp(with event: NSEvent) {}

    override func flagsChanged(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard !strict else { return }
        if event.clickCount == 1 {
            clickTimer?.invalidate()
            clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                self?.actionHandler(false)
            }
        } else if event.clickCount == 2 {
            clickTimer?.invalidate()
            actionHandler(true)
        }
    }

    func show() {
        layer?.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 1.0
        layer?.add(animation, forKey: "opacity")
    }

    func hide(completion: (() -> Void)? = nil) {
        hideCompletion = completion
        layer?.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.25
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        animation.delegate = self
        layer?.add(animation, forKey: "opacity")
    }
}

extension MaskView: CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        hideCompletion?()
        hideCompletion = nil
    }
}

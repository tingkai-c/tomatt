import Cocoa

final class MaskHelper {
    static let shared = MaskHelper()

    private var windowControllers = [NSWindowController]()
    private var skipHandler: (() -> Void)?
    private var previousPresentationOptions: NSApplication.PresentationOptions?

    private init() {}

    func showMaskWindow(desc: String, strict: Bool = false, skipHandler: (() -> Void)? = nil) {
        hideMaskWindow()
        self.skipHandler = strict ? nil : skipHandler

        NSApp.activate(ignoringOtherApps: true)
        if strict {
            applyStrictPresentationLock()
        }

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: .borderless,
                                  backing: .buffered,
                                  defer: false)
            configureMaskWindow(window, for: screen)

            let maskFrame = NSRect(origin: .zero, size: screen.frame.size)
            let maskView = MaskView(desc: desc, frame: maskFrame, strict: strict) { [weak self] shouldSkip in
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

    }

    func hideMaskWindow() {
        skipHandler = nil
        restorePresentationOptions()
        let controllers = windowControllers
        windowControllers.removeAll()
        for controller in controllers {
            if let mask = controller.window?.contentView as? MaskView {
                mask.hide { controller.close() }
            } else {
                controller.close()
            }
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

    private func applyStrictPresentationLock() {
        guard previousPresentationOptions == nil else { return }
        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = NSApp.presentationOptions.union([
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
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

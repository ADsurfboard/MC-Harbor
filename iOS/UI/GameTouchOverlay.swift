import UIKit
import HarborCore

/// Native UIKit touch overlay. Camera, inventory pointer and hotbar gestures outside
/// the controls pass through to the engine's GameSurfaceView; no full-screen web layer.
@MainActor @objc(HarborGameTouchOverlay) public final class HarborGameTouchOverlay: UIView {
    private weak var services: (any HarborNativeServices)?
    private var configuration: TouchLayout
    private var router = TouchInputRouter()
    private enum Role { case joystick; case button(TouchButton) }
    private struct Capture { let owner: UUID; let role: Role }
    private var captures: [ObjectIdentifier: Capture] = [:]
    private var buttons: [UUID: UILabel] = [:]
    private var joystick = UIView()
    private var thumb = UIView()
    private let keyboard = UIButton(type: .system)
    private var joystickOwner: UUID?
    private var floatingCenter: CGPoint?
    private var previousSize: CGSize = .zero
    private var currentJoystickFrame: CGRect = .zero
    private var appInactiveObserver: NSObjectProtocol?
    private var currentButtonFrames: [UUID: CGRect] = [:]

    public init(frame: CGRect, configuration: TouchLayout, services: HarborNativeServices) {
        self.configuration = configuration; self.services = services
        super.init(frame: frame)
        isMultipleTouchEnabled = true; backgroundColor = .clear
        joystick.isUserInteractionEnabled = false; joystick.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        thumb.isUserInteractionEnabled = false; thumb.backgroundColor = UIColor.white.withAlphaComponent(0.42)
        addSubview(joystick); joystick.addSubview(thumb)
        for button in configuration.buttons where button.visible {
            let label = UILabel(); label.isUserInteractionEnabled = false
            label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .white
            label.numberOfLines = 2; label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.7
            label.text = button.customKey == nil && button.customLabel == nil ? Self.shortName(button.action) : button.displayName; label.clipsToBounds = true
            label.backgroundColor = UIColor.black.withAlphaComponent(0.30)
            label.alpha = button.opacity; buttons[button.id] = label; addSubview(label)
        }
        var keyboardConfiguration = UIButton.Configuration.tinted()
        keyboardConfiguration.image = UIImage(systemName: "keyboard")
        keyboardConfiguration.baseForegroundColor = .white
        keyboardConfiguration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.36)
        keyboard.configuration = keyboardConfiguration
        keyboard.accessibilityLabel = "显示或隐藏软键盘"; keyboard.accessibilityIdentifier = "game.keyboard"
        keyboard.addTarget(self, action: #selector(showKeyboard), for: .touchUpInside); addSubview(keyboard)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use the configuration initializer") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelAllInputs()
            if let observer = appInactiveObserver { NotificationCenter.default.removeObserver(observer); appInactiveObserver = nil }
        } else if appInactiveObserver == nil {
            appInactiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAllInputs() }
            }
        }
    }
    public override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { cancelAllInputs(); previousSize = bounds.size }
        let safe = bounds.inset(by: safeAreaInsets)
        let diameter = CGFloat(min(configuration.settings.joystickDiameter, max(88,Double(safe.height)*0.42), Double(min(safe.width, safe.height))))
        let center = floatingCenter ?? CGPoint(x: safe.minX + CGFloat(configuration.settings.joystickCenter.x) * safe.width, y: safe.minY + CGFloat(configuration.settings.joystickCenter.y) * safe.height)
        currentJoystickFrame = CGRect(x: min(max(safe.minX, center.x-diameter/2), max(safe.minX,safe.maxX-diameter)), y: min(max(safe.minY,center.y-diameter/2), max(safe.minY,safe.maxY-diameter)), width: diameter, height: diameter)
        joystick.frame = currentJoystickFrame; joystick.layer.cornerRadius = diameter/2
        let thumbSize = diameter * 0.42
        thumb.bounds.size = CGSize(width: thumbSize, height: thumbSize); thumb.layer.cornerRadius = thumbSize/2
        if joystickOwner == nil { thumb.center = CGPoint(x: diameter/2, y: diameter/2) }
        for button in configuration.buttons where button.visible {
            let fitted = ControlFrame.fit(center: button.center, diameter: button.diameter, availableWidth: Double(safe.width), availableHeight: Double(safe.height))
            let frame = CGRect(x: safe.minX + CGFloat(fitted.x), y: safe.minY + CGFloat(fitted.y), width: CGFloat(fitted.width), height: CGFloat(fitted.height))
            currentButtonFrames[button.id] = frame
            buttons[button.id]?.frame = frame; buttons[button.id]?.layer.cornerRadius = frame.width/2
        }
        keyboard.frame = CGRect(x: safe.midX-22, y: safe.minY+4, width: 44, height: 44)
        updateAccessibility()
    }
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        if keyboard.frame.contains(point) { return keyboard.hitTest(convert(point, to: keyboard), with: event) }
        let grabbed = services?.isPointerGrabbed() == true
        for button in configuration.buttons where button.visible && (grabbed || button.action == .pause) {
            if currentButtonFrames[button.id]?.contains(point) == true { return self }
        }
        guard grabbed else { return nil }
        if currentJoystickFrame.contains(point) { return self }
        if configuration.settings.floatingJoystick && point.x < bounds.width * 0.38 && point.y > bounds.height * 0.32 { return self }
        return nil
    }
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let grabbed = services?.isPointerGrabbed() == true
        for touch in touches {
            let position = touch.location(in: self), owner = UUID(), key = ObjectIdentifier(touch)
            if let button = configuration.buttons.last(where: { $0.visible && (grabbed || $0.action == .pause) && currentButtonFrames[$0.id]?.contains(position) == true }) {
                captures[key] = Capture(owner: owner, role: .button(button))
                dispatch(router.press(button: button, touch: owner)); haptic()
            } else if grabbed && joystickOwner == nil {
                joystickOwner = owner; captures[key] = Capture(owner: owner, role: .joystick)
                if configuration.settings.floatingJoystick { floatingCenter = position; setNeedsLayout(); layoutIfNeeded() }
                moveJoystick(owner: owner, point: position)
            }
        }
        refreshAppearance()
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let capture = captures[ObjectIdentifier(touch)] else { continue }
            if case .joystick = capture.role { moveJoystick(owner: capture.owner, point: touch.location(in: self)) }
        }
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let capture = captures[ObjectIdentifier(touch)], case .button(let button) = capture.role { dispatch(router.cancel(buttonID: button.id)) }
        }
        finish(touches)
    }
    @objc public func updateGrabState(_ grabbed: Bool) {
        cancelAllInputs(); joystick.isHidden = !grabbed
        for button in configuration.buttons { buttons[button.id]?.isHidden = !grabbed && button.action != .pause }
    }
    @objc public func cancelAllInputs() {
        dispatch(router.releaseAll()); captures.removeAll(); joystickOwner = nil; floatingCenter = nil
        thumb.center = CGPoint(x: joystick.bounds.midX, y: joystick.bounds.midY); refreshAppearance()
    }
    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let capture = captures.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            dispatch(router.release(owner: capture.owner))
            if joystickOwner == capture.owner {
                joystickOwner = nil; floatingCenter = nil
                thumb.center = CGPoint(x: joystick.bounds.midX, y: joystick.bounds.midY); setNeedsLayout()
            }
        }
        refreshAppearance()
    }
    private func moveJoystick(owner: UUID, point: CGPoint) {
        let radius = max(1,currentJoystickFrame.width/2)
        var dx = (point.x-currentJoystickFrame.midX)/radius, dy = (point.y-currentJoystickFrame.midY)/radius
        let length = hypot(dx,dy)
        if length > 1 { dx /= length; dy /= length }
        thumb.center = CGPoint(x: radius+dx*radius*0.55, y: radius+dy*radius*0.55)
        dispatch(router.moveJoystick(owner: owner, x: Double(dx), y: Double(dy), settings: configuration.settings))
    }
    private func dispatch(_ events: [GameInputEvent]) {
        for event in events {
            switch event {
            case .press(.key(let key)): services?.sendKey(Int32(key), pressed: true)
            case .release(.key(let key)): services?.sendKey(Int32(key), pressed: false)
            case .press(.mouseButton(let button)): services?.sendMouseButton(Int32(button), pressed: true)
            case .release(.mouseButton(let button)): services?.sendMouseButton(Int32(button), pressed: false)
            case .look, .scroll, .cursor: break // The native game surface owns these gestures.
            }
        }
    }
    private func refreshAppearance() {
        for button in configuration.buttons where button.visible {
            let active = router.heldInputs.contains(TouchInputRouter.binding(button))
            buttons[button.id]?.backgroundColor = active ? UIColor.systemGreen.withAlphaComponent(0.55) : UIColor.black.withAlphaComponent(0.30)
        }
    }
    private func updateAccessibility() {
        var elements: [Any] = [keyboard]
        for button in configuration.buttons where button.visible {
            let element = TouchAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = button.displayName; element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = currentButtonFrames[button.id] ?? .zero
            element.activate = { [weak self] in
                guard let self else { return false }; let owner = UUID()
                self.dispatch(self.router.press(button: button, touch: owner)); self.dispatch(self.router.release(owner: owner)); self.refreshAppearance(); return true
            }
            elements.append(element)
        }
        accessibilityElements = elements
    }
    private func haptic() { if configuration.settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45) } }
    @objc private func showKeyboard() { cancelAllInputs(); services?.showGameKeyboard() }
    private static func shortName(_ action: ControlAction) -> String {
        switch action { case .attack: "挖掘"; case .use: "使用"; case .swapHands: "副手"; case .perspective: "视角"; case .playerList: "玩家"; default: String(action.chineseName.prefix(3)) }
    }
}

@MainActor private final class TouchAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

import Foundation

public enum GameInput: Hashable, Sendable { case key(Int), mouseButton(Int) }
public enum GameInputEvent: Equatable, Sendable {
    case press(GameInput), release(GameInput), look(Double, Double), scroll(Double), cursor(Double, Double)
}

/// Input ownership is independent of the view hierarchy. A cancelled touch, rotation,
/// background transition or overlay dismissal releases every key it owns.
public struct TouchInputRouter: Sendable {
    public private(set) var held: [GameInput: Set<UUID>] = [:]
    private var ownerInputs: [UUID: Set<GameInput>] = [:]
    private var toggledButtons: [UUID: UUID] = [:]
    public init() {}
    public var heldInputs: Set<GameInput> { Set(held.keys) }

    public mutating func replace(owner: UUID, inputs: Set<GameInput>) -> [GameInputEvent] {
        let previous = ownerInputs[owner] ?? []
        var events: [GameInputEvent] = []
        for input in (previous.subtracting(inputs)).sorted(by: Self.ordered) {
            held[input]?.remove(owner)
            if held[input]?.isEmpty == true { held.removeValue(forKey: input); events.append(.release(input)) }
        }
        for input in (inputs.subtracting(previous)).sorted(by: Self.ordered) {
            if held[input] == nil { events.append(.press(input)) }
            held[input, default: []].insert(owner)
        }
        if inputs.isEmpty { ownerInputs.removeValue(forKey: owner) } else { ownerInputs[owner] = inputs }
        return events
    }
    public mutating func release(owner: UUID) -> [GameInputEvent] { replace(owner: owner, inputs: []) }
    public mutating func cancel(buttonID: UUID) -> [GameInputEvent] {
        guard let owner = toggledButtons.removeValue(forKey: buttonID) else { return [] }
        return release(owner: owner)
    }
    public mutating func releaseAll() -> [GameInputEvent] {
        let events = held.keys.sorted(by: Self.ordered).map { GameInputEvent.release($0) }
        held.removeAll(keepingCapacity: true); ownerInputs.removeAll(keepingCapacity: true); toggledButtons.removeAll()
        return events
    }
    public mutating func press(button: TouchButton, touch: UUID) -> [GameInputEvent] {
        guard button.visible else { return [] }
        if button.toggle {
            if let owner = toggledButtons.removeValue(forKey: button.id) { return release(owner: owner) }
            let owner = UUID(); toggledButtons[button.id] = owner
            return replace(owner: owner, inputs: [Self.binding(button)])
        }
        return replace(owner: touch, inputs: [Self.binding(button)])
    }
    public mutating func moveJoystick(owner: UUID, x: Double, y: Double, settings raw: TouchSettings) -> [GameInputEvent] {
        var settings = raw; settings.sanitize()
        guard x.isFinite && y.isFinite else { return release(owner: owner) }
        let length = hypot(x, y)
        guard length > settings.joystickDeadZone else { return release(owner: owner) }
        let nx = x / length, ny = y / length
        var keys: Set<GameInput> = []
        let diagonalThreshold = sin(Double.pi / 8)
        if nx < -diagonalThreshold { keys.insert(.key(65)) }
        if nx > diagonalThreshold { keys.insert(.key(68)) }
        if ny < -diagonalThreshold { keys.insert(.key(87)) }
        if ny > diagonalThreshold { keys.insert(.key(83)) }
        if settings.autoSprint && length >= 0.85 && ny < -0.7 { keys.insert(.key(341)) }
        return replace(owner: owner, inputs: keys)
    }
    public static func look(dx: Double, dy: Double, settings raw: TouchSettings) -> [GameInputEvent] {
        guard dx.isFinite && dy.isFinite else { return [] }
        var settings = raw; settings.sanitize()
        // A single coalesced event cannot jump across many rotations after suspension.
        let x = min(600, max(-600, dx)) * settings.cameraSensitivity * (settings.invertCameraX ? -1 : 1)
        let y = min(600, max(-600, dy)) * settings.cameraSensitivity * (settings.invertCameraY ? -1 : 1)
        return [.look(x, y)]
    }
    public static func binding(_ action: ControlAction) -> GameInput {
        switch action {
        case .jump: .key(32)
        case .sneak: .key(340)
        case .sprint: .key(341)
        case .attack: .mouseButton(0)
        case .use: .mouseButton(1)
        case .middleClick: .mouseButton(2)
        case .inventory: .key(69)
        case .chat: .key(84)
        case .pause: .key(256)
        case .drop: .key(81)
        case .swapHands: .key(70)
        case .perspective: .key(294)
        case .playerList: .key(258)
        default: .key(48 + (Int(action.rawValue.suffix(1)) ?? 1))
        }
    }
    public static func binding(_ button: TouchButton) -> GameInput {
        if let key = button.customKey, TouchButton.validKeyboardKey(key) { return .key(key) }
        return binding(button.action)
    }
    private static func ordered(_ lhs: GameInput, _ rhs: GameInput) -> Bool {
        func value(_ input: GameInput) -> Int { switch input { case .key(let code): code; case .mouseButton(let button): 10000 + button } }
        return value(lhs) < value(rhs)
    }
}

import Foundation

public enum ControlAction: String, Codable, CaseIterable, Sendable {
    case jump, sneak, sprint, attack, use, middleClick, inventory, chat, pause, drop, swapHands, perspective, playerList
    case hotbar1, hotbar2, hotbar3, hotbar4, hotbar5, hotbar6, hotbar7, hotbar8, hotbar9
    public var chineseName: String {
        switch self {
        case .jump: "跳跃"
        case .sneak: "潜行"
        case .sprint: "疾跑"
        case .attack: "攻击 / 挖掘"
        case .use: "使用 / 放置"
        case .middleClick: "鼠标中键"
        case .inventory: "背包"
        case .chat: "聊天"
        case .pause: "暂停"
        case .drop: "丢弃"
        case .swapHands: "切换副手"
        case .perspective: "切换视角"
        case .playerList: "玩家列表"
        default: "快捷栏 " + String(rawValue.suffix(1))
        }
    }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = Self.unit(x); self.y = Self.unit(y)
    }
    public static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
}

public struct TouchButton: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var action: ControlAction
    public var center: NormalizedPoint
    public var diameter: Double
    public var opacity: Double
    public var visible: Bool
    public var toggle: Bool
    public var customKey: Int? = nil
    public var customLabel: String? = nil
    public init(id: UUID = UUID(), action: ControlAction, x: Double, y: Double, diameter: Double = 58, opacity: Double = 0.65, visible: Bool = true, toggle: Bool = false) {
        self.id = id; self.action = action; center = .init(x: x, y: y)
        self.diameter = diameter; self.opacity = opacity; self.visible = visible; self.toggle = toggle
    }
    public var displayName: String {
        if let label = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return String(label.prefix(24)) }
        if let customKey { return "按键 " + (customKey >= 65 && customKey <= 90 ? String(UnicodeScalar(customKey)!) : String(customKey)) }
        return action.chineseName
    }
    public mutating func sanitize() throws {
        if action == .pause { customKey = nil; toggle = false }
        if let key = customKey, !Self.validKeyboardKey(key) { throw TouchLayoutError.invalidKeyBinding(key) }
        if let label = customLabel { customLabel = String(label.prefix(24)) }
        center = .init(x: center.x, y: center.y)
        diameter = diameter.isFinite ? min(160, max(44, diameter)) : 58
        opacity = opacity.isFinite ? min(1, max(0.1, opacity)) : 0.65
    }
    public static func validKeyboardKey(_ key: Int) -> Bool {
        (32...96).contains(key) || (161...162).contains(key) || (256...269).contains(key) ||
        (280...284).contains(key) || (290...314).contains(key) || (320...336).contains(key) || (340...348).contains(key)
    }
}

public struct TouchSettings: Codable, Equatable, Sendable {
    public var joystickDiameter: Double = 132
    public var joystickDeadZone: Double = 0.16
    public var joystickCenter = NormalizedPoint(x: 0.14, y: 0.70)
    public var floatingJoystick = false
    public var cameraSensitivity: Double = 1.0
    public var invertCameraX = false
    public var invertCameraY = false
    public var autoSprint = true
    public var gyroEnabled = false
    public var gyroSensitivity: Double = 0.7
    public var haptics = true
    public var hotbarVisible = true
    public var hotbarScale: Double = 1
    public var showTouchFeedback = false
    public init() {}
    public mutating func sanitize() {
        func clamp(_ value: Double, _ lower: Double, _ upper: Double, _ fallback: Double) -> Double {
            value.isFinite ? min(upper, max(lower, value)) : fallback
        }
        joystickDiameter = clamp(joystickDiameter, 88, 240, 132)
        joystickDeadZone = clamp(joystickDeadZone, 0.04, 0.5, 0.16)
        joystickCenter = .init(x: joystickCenter.x, y: joystickCenter.y)
        cameraSensitivity = clamp(cameraSensitivity, 0.1, 4, 1)
        gyroSensitivity = clamp(gyroSensitivity, 0.05, 3, 0.7)
        hotbarScale = clamp(hotbarScale, 0.7, 2, 1)
    }
}

public struct TouchLayout: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var name: String
    public var settings: TouchSettings
    public var buttons: [TouchButton]
    public init(id: UUID = UUID(), name: String, settings: TouchSettings = .init(), buttons: [TouchButton]) {
        self.id = id; self.name = name; self.settings = settings; self.buttons = buttons
    }
    public static func standard() -> Self {
        .init(name: "经典触控", buttons: [
            .init(action: .attack, x: 0.86, y: 0.50, diameter: 66),
            .init(action: .use, x: 0.94, y: 0.67, diameter: 66),
            .init(action: .jump, x: 0.83, y: 0.79, diameter: 62),
            .init(action: .sneak, x: 0.70, y: 0.80, toggle: true),
            .init(action: .sprint, x: 0.27, y: 0.58, toggle: true),
            .init(action: .inventory, x: 0.71, y: 0.12, diameter: 44),
            .init(action: .chat, x: 0.81, y: 0.12, diameter: 44),
            .init(action: .pause, x: 0.92, y: 0.12, diameter: 44),
            .init(action: .drop, x: 0.60, y: 0.12, diameter: 44, visible: false),
            .init(action: .swapHands, x: 0.51, y: 0.12, diameter: 44, visible: false),
            .init(action: .perspective, x: 0.42, y: 0.12, diameter: 44, visible: false),
            .init(action: .playerList, x: 0.33, y: 0.12, diameter: 44, visible: false)
        ])
    }
    public mutating func sanitize() throws {
        guard schemaVersion == 1 else { throw TouchLayoutError.unsupportedVersion(schemaVersion) }
        guard buttons.count <= 96 else { throw TouchLayoutError.tooManyButtons }
        guard Set(buttons.map(\.id)).count == buttons.count else { throw TouchLayoutError.duplicateIdentifiers }
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if name.isEmpty { name = "我的触控布局" }
        settings.sanitize()
        for index in buttons.indices { try buttons[index].sanitize() }
        if !buttons.contains(where: { $0.action == .pause && $0.visible }) {
            guard buttons.count < 96 else { throw TouchLayoutError.tooManyButtons }
            buttons.append(.init(action: .pause, x: 0.92, y: 0.12, diameter: 44))
        }
    }
    public mutating func mirrorHorizontally() {
        settings.joystickCenter.x = 1 - settings.joystickCenter.x
        for i in buttons.indices { buttons[i].center.x = 1 - buttons[i].center.x }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw TouchLayoutError.tooLarge }
        var layout = try JSONDecoder().decode(Self.self, from: data)
        try layout.sanitize()
        return layout
    }
}

public enum TouchLayoutError: Error, Equatable { case unsupportedVersion(Int), tooManyButtons, duplicateIdentifiers, tooLarge, invalidKeyBinding(Int) }

public struct ControlFrame: Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public static func fit(center: NormalizedPoint, diameter: Double, availableWidth: Double, availableHeight: Double) -> Self {
        let width = max(0, availableWidth), height = max(0, availableHeight)
        let size = min(max(44, diameter.isFinite ? diameter : 44), width, height)
        return .init(x: min(max(0, center.x * width - size / 2), max(0, width - size)),
                     y: min(max(0, center.y * height - size / 2), max(0, height - size)), width: size, height: size)
    }
}

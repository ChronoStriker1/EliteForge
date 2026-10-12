import Foundation

/// Live controller state decoded from GIP input reports.
public struct InputState: Hashable, Codable, Sendable {
    public var buttons: Set<InputButton> = []
    /// 0-1023.
    public var leftTrigger: UInt16 = 0
    public var rightTrigger: UInt16 = 0
    public var leftStickX: Int16 = 0
    public var leftStickY: Int16 = 0
    public var rightStickX: Int16 = 0
    public var rightStickY: Int16 = 0
    /// Active hardware profile slot, 0-3.
    public var activeSlot: Int?
    /// Positions of the hair trigger lock switches on the back. The controller
    /// reported them on the Default profile; on custom profiles the byte read 0.
    public var leftTriggerStop: TriggerStop?
    public var rightTriggerStop: TriggerStop?

    public init() {}

    /// Applies a 0x20 input report. Paddles are only present in the
    /// extended report that the init sequence turns on.
    public mutating func apply(input payload: [UInt8]) {
        guard payload.count >= 14 else { return }
        let guide = buttons.contains(.guide)
        buttons = Self.decodeButtons(payload[0], payload[1])
        if guide { buttons.insert(.guide) }
        if payload.count >= 15 { buttons.formUnion(Self.decodePaddles(payload[14])) }
        leftTrigger = UInt16(payload[2]) | UInt16(payload[3]) << 8
        rightTrigger = UInt16(payload[4]) | UInt16(payload[5]) << 8
        leftStickX = Int16(bitPattern: UInt16(payload[6]) | UInt16(payload[7]) << 8)
        leftStickY = Int16(bitPattern: UInt16(payload[8]) | UInt16(payload[9]) << 8)
        rightStickX = Int16(bitPattern: UInt16(payload[10]) | UInt16(payload[11]) << 8)
        rightStickY = Int16(bitPattern: UInt16(payload[12]) | UInt16(payload[13]) << 8)
    }

    /// Applies a 0x0C Elite report, which carries the active profile slot.
    public mutating func apply(elite payload: [UInt8]) {
        guard payload.count >= 16 else { return }
        activeSlot = Int(payload[15] & 0x03)
        if payload.count >= 17 {
            leftTriggerStop = TriggerStop(rawValue: payload[16] & 0x03)
            rightTriggerStop = TriggerStop(rawValue: payload[16] >> 2 & 0x03)
        }
    }

    public mutating func apply(guide payload: [UInt8]) {
        guard let state = payload.first else { return }
        if state & 0x01 != 0 { buttons.insert(.guide) } else { buttons.remove(.guide) }
    }

    static func decodeButtons(_ b0: UInt8, _ b1: UInt8) -> Set<InputButton> {
        var set: Set<InputButton> = []
        let first: [(UInt8, InputButton)] = [(0x04, .menu), (0x08, .view), (0x10, .a), (0x20, .b), (0x40, .x), (0x80, .y)]
        let second: [(UInt8, InputButton)] = [
            (0x01, .dpadUp), (0x02, .dpadDown), (0x04, .dpadLeft), (0x08, .dpadRight),
            (0x10, .leftBumper), (0x20, .rightBumper), (0x40, .leftStick), (0x80, .rightStick),
        ]
        for (mask, button) in first where b0 & mask != 0 { set.insert(button) }
        for (mask, button) in second where b1 & mask != 0 { set.insert(button) }
        return set
    }

    static func decodePaddles(_ mask: UInt8) -> Set<InputButton> {
        var set: Set<InputButton> = []
        if mask & 0x01 != 0 { set.insert(.paddleUpperRight) }
        if mask & 0x02 != 0 { set.insert(.paddleLowerRight) }
        if mask & 0x04 != 0 { set.insert(.paddleUpperLeft) }
        if mask & 0x08 != 0 { set.insert(.paddleLowerLeft) }
        return set
    }
}

public enum InputButton: String, CaseIterable, Codable, Sendable {
    case a, b, x, y
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftBumper, rightBumper, leftStick, rightStick
    case view, menu, guide
    case paddleUpperRight, paddleLowerRight, paddleUpperLeft, paddleLowerLeft

    public var shortLabel: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .dpadUp: "↑"
        case .dpadDown: "↓"
        case .dpadLeft: "←"
        case .dpadRight: "→"
        case .leftBumper: "LB"
        case .rightBumper: "RB"
        case .leftStick: "LS"
        case .rightStick: "RS"
        case .view: "View"
        case .menu: "Menu"
        case .guide: "Xbox"
        case .paddleUpperRight: "P1"
        case .paddleLowerRight: "P2"
        case .paddleUpperLeft: "P3"
        case .paddleLowerLeft: "P4"
        }
    }
}

/// Identity and firmware details from the controller's HELLO (announce) frame.
public struct DeviceInfo: Hashable, Codable, Sendable {
    public var deviceID: String
    public var vendorID: UInt16
    public var productID: UInt16
    public var firmware: String
    public var hardware: String

    public init?(hello payload: [UInt8]) {
        guard payload.count >= 28 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(payload[i]) | UInt16(payload[i + 1]) << 8 }
        deviceID = payload[0..<8].reversed().map { String(format: "%02X", $0) }.joined()
        vendorID = u16(8)
        productID = u16(10)
        firmware = "\(u16(12)).\(u16(14)).\(u16(16)).\(u16(18))"
        hardware = "\(u16(20)).\(u16(22)).\(u16(24)).\(u16(26))"
    }
}

/// Battery report from the 0x03 status frame.
public struct BatteryStatus: Hashable, Codable, Sendable {
    public enum Level: Int, Codable, Sendable { case critical, low, medium, full }
    public var level: Level

    public init?(status payload: [UInt8]) {
        guard let byte = payload.first else { return nil }
        level = Level(rawValue: Int(byte & 0x03)) ?? .full
    }

    public var label: String {
        switch level {
        case .critical: "Critical"
        case .low: "Low"
        case .medium: "Medium"
        case .full: "Full"
        }
    }
}

/// Position of a hair trigger lock, Microsoft's name for the switch on the
/// back that limits trigger travel. Microsoft doesn't name the three
/// positions, so the labels describe the travel. The switch is physical; it
/// can be read but not set.
public enum TriggerStop: UInt8, Hashable, Codable, Sendable, CaseIterable {
    case full = 0
    case mid = 1
    case short = 2

    public var label: String {
        switch self {
        case .full: "Full"
        case .mid: "Half"
        case .short: "Short"
        }
    }
}

import Foundation

/// One 56-byte mapping page as typed values: what each input does in one
/// layer, and the settings the page carries for the whole profile. Bytes it
/// doesn't model, such as the version and the LED channels at 49-51, stay
/// as they were in the page it was read from.
public struct MappingPage: Hashable, Sendable {
    /// Inputs that don't do their standard job in this layer.
    public var assignments: [RemappableControl: Assignment]
    public var vibration: VibrationSettings
    public var leftTrigger: TriggerLockPairs
    public var rightTrigger: TriggerLockPairs
    public var light: LightSettings
    private let base: [UInt8]

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == MappingLayout.size)
        base = bytes
        let keyboard = bytes[MappingLayout.keyboardFlags] & MappingLayout.keyboardFlagValue != 0
        var assignments: [RemappableControl: Assignment] = [:]
        for control in RemappableControl.allCases {
            let code = bytes[control.mappingOffset]
            if code == Self.standardCode(control) { continue }
            assignments[control] = control.isTrigger && keyboard ? .key(KeyboardKey(usage: code)) : Self.assignment(forCode: code)
        }
        self.assignments = assignments
        let rumble = MappingLayout.rumbleIntensity
        vibration = VibrationSettings(leftGrip: bytes[rumble + 1], rightGrip: bytes[rumble], leftTrigger: bytes[rumble + 3], rightTrigger: bytes[rumble + 2])
        func pairs(_ offset: Int) -> TriggerLockPairs {
            func pair(_ index: Int) -> TriggerPair { TriggerPair(max: bytes[offset + index * 2], min: bytes[offset + index * 2 + 1]) }
            return TriggerLockPairs(full: pair(0), half: pair(1), short: pair(2))
        }
        leftTrigger = pairs(MappingLayout.triggerPairs)
        rightTrigger = pairs(MappingLayout.triggerPairs + 6)
        light = LightSettings(brightness: bytes[MappingLayout.brightness])
        if bytes[MappingLayout.colorFlag] != 0xFF {
            let c = MappingLayout.color
            light.color = RGBColor(red: bytes[c], green: bytes[c + 1], blue: bytes[c + 2])
        }
    }

    public var bytes: [UInt8] {
        var page = base
        var usesKeyboard = false
        for control in RemappableControl.allCases {
            let assignment = assignments[control] ?? .standard
            if control.isTrigger, case .key = assignment { usesKeyboard = true }
            page[control.mappingOffset] = Self.code(for: assignment, control: control)
        }
        if usesKeyboard {
            page[MappingLayout.keyboardFlags] |= MappingLayout.keyboardFlagValue
        } else {
            page[MappingLayout.keyboardFlags] &= ~MappingLayout.keyboardFlagValue
        }

        let rumble = MappingLayout.rumbleIntensity
        page[rumble] = min(vibration.rightGrip, 100)
        page[rumble + 1] = min(vibration.leftGrip, 100)
        page[rumble + 2] = min(vibration.rightTrigger, 100)
        page[rumble + 3] = min(vibration.leftTrigger, 100)

        for (pairs, offset) in [(leftTrigger, MappingLayout.triggerPairs), (rightTrigger, MappingLayout.triggerPairs + 6)] {
            page.replaceSubrange(offset..<offset + 6, with: [pairs.full, pairs.half, pairs.short].flatMap { [$0.max, $0.min] })
        }

        page[MappingLayout.brightness] = min(light.brightness, 100)
        let c = MappingLayout.color
        if let color = light.color {
            page[MappingLayout.colorFlag] = 0x00
            page[c] = color.red
            page[c + 1] = color.green
            page[c + 2] = color.blue
        } else {
            page[MappingLayout.colorFlag] = 0xFF
            page[c] = 0
            page[c + 1] = 0
            page[c + 2] = 0
        }
        return page
    }

    private static func standardCode(_ control: RemappableControl) -> UInt8 {
        control.standardOutput?.rawValue ?? 0x00
    }

    private static func assignment(forCode code: UInt8) -> Assignment {
        switch code {
        case MappingLayout.codeDisabled: return .disabled
        case MappingLayout.codeShift: return .shift
        default:
            if let button = GamepadButton(rawValue: code) { return .button(button) }
            return .key(KeyboardKey(usage: code))
        }
    }

    private static func code(for assignment: Assignment, control: RemappableControl) -> UInt8 {
        switch assignment {
        case .standard: return standardCode(control)
        case .disabled: return MappingLayout.codeDisabled
        case .shift: return MappingLayout.codeShift
        case .button(let button): return button.rawValue
        case .key(let key): return key.usage
        }
    }
}

/// A trigger's (max, min) bytes for one hair trigger lock position, as stored.
public struct TriggerPair: Hashable, Sendable {
    public var max: UInt8
    public var min: UInt8

    public init(max: UInt8, min: UInt8) {
        self.max = max
        self.min = min
    }
}

/// One trigger's pairs, which the firmware picks by the hair trigger lock's position.
public struct TriggerLockPairs: Hashable, Sendable {
    public var full: TriggerPair
    public var half: TriggerPair
    public var short: TriggerPair

    public init(full: TriggerPair, half: TriggerPair, short: TriggerPair) {
        self.full = full
        self.half = half
        self.short = short
    }

    /// What the Accessories app writes (0x180e9d0b4): the range for the full
    /// and half positions, and (0, 0) for short, which the firmware turns
    /// into an on/off switch.
    public init(_ settings: TriggerSettings) {
        let pair = TriggerPair(max: settings.range, min: settings.deadZone)
        self.init(full: pair, half: pair, short: TriggerPair(max: 0, min: 0))
    }

    /// The range EliteForge edits: the full position's.
    public var settings: TriggerSettings { TriggerSettings(range: full.max, deadZone: full.min) }
}

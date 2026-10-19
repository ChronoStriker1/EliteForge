import Foundation

/// One 56-byte mapping page as typed values: what each input does in one
/// layer, and the settings the page carries for the whole profile. Bytes it
/// doesn't model, such as the version, the LED channels at 49-50 and byte
/// 51, stay as they were in the page it was read from.
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
        let flags = Self.flags(bytes)
        var assignments: [RemappableControl: Assignment] = [:]
        for control in RemappableControl.allCases {
            let code = bytes[control.mappingOffset]
            if flags & Self.keyboardFlag(control) != 0 {
                let (index, shift) = Self.modifierNibble(control)
                assignments[control] = .key(KeyCombination(KeyboardKey(usage: code), modifiers: KeyModifiers(rawValue: bytes[index] >> shift & 0x0F)))
            } else if code != Self.standardCode(control) {
                assignments[control] = Self.assignment(forCode: code)
            }
        }
        if flags & MappingLayout.swapTriggers != 0 {
            assignments.merge(Assignment.swappedTriggers) { _, swapped in swapped }
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
        var flags = Self.flags(base)
        // Swapped triggers are the flag alone; their own bytes say "keep the trigger".
        let swapped = RemappableControl.triggers.allSatisfy { assignments[$0] == Assignment.swappedTriggers[$0] }
        flags = swapped ? flags | MappingLayout.swapTriggers : flags & ~MappingLayout.swapTriggers
        let written = swapped ? assignments.filter { !$0.key.isTrigger } : assignments
        for control in RemappableControl.allCases {
            var modifiers = KeyModifiers()
            if case .key(let key) = written[control] {
                page[control.mappingOffset] = key.key.usage
                flags |= Self.keyboardFlag(control)
                modifiers = key.modifiers
            } else {
                page[control.mappingOffset] = Self.code(for: written[control] ?? .standard, control: control)
                flags &= ~Self.keyboardFlag(control)
            }
            let (index, shift) = Self.modifierNibble(control)
            page[index] = page[index] & ~(0x0F << shift) | (modifiers.rawValue & 0x0F) << shift
        }
        page.replaceSubrange(MappingLayout.flags..<MappingLayout.flags + 4, with: (0..<4).map { UInt8(truncatingIfNeeded: flags >> ($0 * 8)) })

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

    private static func flags(_ bytes: [UInt8]) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[MappingLayout.flags + $1]) << ($1 * 8) }
    }

    /// Input byte n's keyboard flag is bit 14 + (n - 1) of the flag word.
    private static func keyboardFlag(_ control: RemappableControl) -> UInt32 {
        1 << (14 + control.mappingOffset - 1)
    }

    /// The byte and bit shift of input byte n's modifier nibble: two inputs
    /// per byte from 19, the first of the pair in the low nibble.
    private static func modifierNibble(_ control: RemappableControl) -> (index: Int, shift: UInt8) {
        let input = control.mappingOffset - 1
        return (MappingLayout.modifiers + input / 2, input % 2 == 0 ? 0 : 4)
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
            return .code(code)
        }
    }

    private static func code(for assignment: Assignment, control: RemappableControl) -> UInt8 {
        switch assignment {
        case .standard: return standardCode(control)
        case .disabled: return MappingLayout.codeDisabled
        case .shift: return MappingLayout.codeShift
        case .button(let button): return button.rawValue
        case .code(let code): return code
        case .key(let key): return key.key.usage
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

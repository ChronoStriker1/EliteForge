import Foundation

/// One 56-byte mapping page as typed values: what each input does in one
/// layer, and the settings the page carries for the whole profile. Bytes it
/// doesn't model, such as the version and the LED channels at 49-51, stay
/// as they were in the page it was read from.
public struct MappingPage: Hashable, Sendable {
    /// Inputs that don't do their standard job in this layer.
    public var assignments: [RemappableControl: Assignment]
    public var vibration: VibrationSettings
    public var leftTriggerRange: UInt8
    public var rightTriggerRange: UInt8
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
        leftTriggerRange = bytes[MappingLayout.leftTriggerRange]
        rightTriggerRange = bytes[MappingLayout.rightTriggerRange]
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

        page[MappingLayout.leftTriggerRange] = leftTriggerRange
        page[MappingLayout.leftTriggerRange + 1] = 0
        page[MappingLayout.rightTriggerRange] = rightTriggerRange
        page[MappingLayout.rightTriggerRange + 1] = 0

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

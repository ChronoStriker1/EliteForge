import Foundation

/// What a control can be remapped to, as encoded in a profile mapping page:
/// the 12 buttons and the two triggers, which the firmware pulls all the
/// way. These are the 14 the Accessories app offers. The codes differ from
/// the bit positions in input reports.
public enum GamepadButton: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case a = 0x04
    case b = 0x05
    case x = 0x06
    case y = 0x07
    case dpadUp = 0x08
    case dpadDown = 0x09
    case dpadLeft = 0x0A
    case dpadRight = 0x0B
    case leftBumper = 0x0C
    case rightBumper = 0x0D
    case leftStick = 0x0E
    case rightStick = 0x0F
    case leftTrigger = 0x10
    case rightTrigger = 0x11

    public var id: UInt8 { rawValue }

    public var label: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .dpadUp: "D-pad up"
        case .dpadDown: "D-pad down"
        case .dpadLeft: "D-pad left"
        case .dpadRight: "D-pad right"
        case .leftBumper: "Left bumper"
        case .rightBumper: "Right bumper"
        case .leftStick: "Left stick click"
        case .rightStick: "Right stick click"
        case .leftTrigger: "Left trigger"
        case .rightTrigger: "Right trigger"
        }
    }

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
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        }
    }
}

/// Every physical control the Accessories app lets you reassign.
public enum RemappableControl: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable, Identifiable {
    case a, b, x, y
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftBumper, rightBumper
    case leftStick, rightStick
    case leftTrigger, rightTrigger
    case paddleUpperRight, paddleLowerRight, paddleUpperLeft, paddleLowerLeft

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .leftTrigger: "Left trigger"
        case .rightTrigger: "Right trigger"
        case .paddleUpperRight: "P1 (upper right paddle)"
        case .paddleLowerRight: "P2 (lower right paddle)"
        case .paddleUpperLeft: "P3 (upper left paddle)"
        case .paddleLowerLeft: "P4 (lower left paddle)"
        default: nativeButton!.label
        }
    }

    public var shortLabel: String {
        switch self {
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .paddleUpperRight: "P1"
        case .paddleLowerRight: "P2"
        case .paddleUpperLeft: "P3"
        case .paddleLowerLeft: "P4"
        default: nativeButton!.shortLabel
        }
    }

    /// The button this control produces when nothing is remapped, if it is a button.
    public var nativeButton: GamepadButton? {
        switch self {
        case .a: .a
        case .b: .b
        case .x: .x
        case .y: .y
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .leftBumper: .leftBumper
        case .rightBumper: .rightBumper
        case .leftStick: .leftStick
        case .rightStick: .rightStick
        default: nil
        }
    }

    /// This control's bit in input reports. Triggers are analog and have none.
    public var inputButton: InputButton? {
        switch self {
        case .a: .a
        case .b: .b
        case .x: .x
        case .y: .y
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .leftBumper: .leftBumper
        case .rightBumper: .rightBumper
        case .leftStick: .leftStick
        case .rightStick: .rightStick
        case .paddleUpperRight: .paddleUpperRight
        case .paddleLowerRight: .paddleLowerRight
        case .paddleUpperLeft: .paddleUpperLeft
        case .paddleLowerLeft: .paddleLowerLeft
        case .leftTrigger, .rightTrigger: nil
        }
    }

    /// The button this control produces when it isn't remapped: its own
    /// button, or for a paddle the Accessories default. nil for triggers.
    public var standardOutput: GamepadButton? {
        if let index = Self.paddles.firstIndex(of: self) { return GamepadButton(rawValue: MappingLayout.defaultPaddleOutputs[index]) }
        return nativeButton
    }

    public var isPaddle: Bool {
        switch self {
        case .paddleUpperRight, .paddleLowerRight, .paddleUpperLeft, .paddleLowerLeft: true
        default: false
        }
    }

    public var isTrigger: Bool { self == .leftTrigger || self == .rightTrigger }

    /// What the Accessories app lets this control send. A trigger's own
    /// output is its default, and it can only get the other trigger's by
    /// swapping the triggers.
    public var targets: [GamepadButton] {
        isTrigger ? GamepadButton.allCases.filter { $0 != .leftTrigger && $0 != .rightTrigger } : GamepadButton.allCases
    }

    /// Byte offset of this control's output in the 56-byte mapping page.
    public var mappingOffset: Int {
        switch self {
        case .paddleUpperRight: MappingLayout.paddleOffsets[0]
        case .paddleLowerRight: MappingLayout.paddleOffsets[1]
        case .paddleUpperLeft: MappingLayout.paddleOffsets[2]
        case .paddleLowerLeft: MappingLayout.paddleOffsets[3]
        case .a: 5
        case .b: 6
        case .x: 7
        case .y: 8
        case .dpadUp: 9
        case .dpadDown: 10
        case .dpadLeft: 11
        case .dpadRight: 12
        case .leftBumper: 13
        case .rightBumper: 14
        case .leftStick: 15
        case .rightStick: 16
        case .leftTrigger: 17
        case .rightTrigger: 18
        }
    }

    public static let buttons: [RemappableControl] = [.a, .b, .x, .y, .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .leftBumper, .rightBumper, .leftStick, .rightStick]
    public static let paddles: [RemappableControl] = [.paddleUpperRight, .paddleLowerRight, .paddleUpperLeft, .paddleLowerLeft]
    public static let triggers: [RemappableControl] = [.leftTrigger, .rightTrigger]
}

/// What a control does in one layer (normal or shift) of a profile.
public enum Assignment: Hashable, Codable, Sendable {
    /// The control keeps its own function. For paddles this means the
    /// Accessories default (see `MappingLayout.defaultPaddleOutputs`).
    case standard
    /// The control does nothing.
    case disabled
    /// Holding the control activates the shift layer.
    case shift
    /// The control acts as another gamepad button.
    case button(GamepadButton)
    /// The control sends a keyboard key (HID usage) with modifiers. Only
    /// works on Xbox and Windows, where the system driver turns it into a
    /// key press.
    case key(KeyCombination)
    /// An output the Accessories app doesn't offer on the Elite 2, such as
    /// Menu (0x02), a stick direction (0x12-0x19) or a paddle (0x1A-0x1D),
    /// kept as read.
    case code(UInt8)

    public var label: String {
        switch self {
        case .standard: "Default"
        case .disabled: "Unmapped"
        case .shift: "Shift"
        case .button(let button): button.label
        case .key(let key): "Key: \(key.label)"
        case .code(let code): String(format: "Output 0x%02X", code)
        }
    }
}

/// Byte layout of the mapping page. Offsets that are still guesses are marked.
public enum MappingLayout {
    public static let size = 56

    /// Mapping-page offsets for [P1 upper right, P2 lower right, P3 upper left, P4 lower left].
    /// Same order as the paddle bits in input reports (verified on hardware).
    public static let paddleOffsets = [1, 2, 3, 4]

    /// What the Accessories app writes for paddles when it restores a profile
    /// to default (bytes 1-4 = 05 07 04 06): P1 B, P2 Y, P3 A, P4 X.
    public static let defaultPaddleOutputs: [UInt8] = [0x05, 0x07, 0x04, 0x06]

    public static let codeDisabled: UInt8 = 0x00
    public static let codeShift: UInt8 = 0x01

    /// Keyboard modifier nibbles: input byte n's at byte 19 + (n - 1) / 2,
    /// the odd byte's input in the low nibble.
    public static let modifiers = 19
    public static let rumbleIntensity = 28 // [weak, strong, right trigger, left trigger], 0-100
    /// (max, min) pairs per hair trigger lock position (full, half, short): LT 32-37, RT 38-43.
    public static let triggerPairs = 32
    public static let brightness = 44
    public static let colorFlag = 45 // 0xFF = default white, 0x00 = custom colour
    public static let color = 46 // R, G, B
    /// A u32 LE flag word. Bit 14 + (n - 1) is set when input byte n holds
    /// a HID keyboard usage instead of a code: bit 30 (0x40 in byte 55) is
    /// LT, bit 31 (0x80) RT. Bits 0-13 are kept as read.
    public static let flags = 52

    /// The page the Accessories app writes when restoring a profile to default.
    public static let defaultPage: [UInt8] = [UInt8](hexString:
        "11 05 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 " +
        "ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 ff 00 00 00 30 30 00 00 00 00 00")!
}

/// Byte layout of the curves page: 43 bytes, or 28 in format 1.0.
public enum CurvesLayout {
    /// Six bytes per axis: three (x, y) control points. Axis order LX, LY, RX, RY.
    public static let curveOffsets = [1, 7, 13, 19]
    /// Bit 0 inverts the left stick Y axis, bit 1 the right stick Y axis.
    public static let inversion = 27

    public static let defaultPage: [UInt8] = [UInt8](hexString:
        "11 2b 2b 7f 7f bf bf 2b 2b 7f 7f bf bf 2b 2b 7f 7f bf bf 2b 2b 7f 7f bf bf 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")!
}

/// Page addresses for the three configurable slots. Slot 0 ("Default") has
/// no pages and can't be changed, the same as in the Accessories app.
public enum ProfilePages {
    public struct Addresses: Sendable, Equatable {
        public let normalMapping: UInt8
        public let normalCurves: UInt8
        public let shiftMapping: UInt8
        public let shiftCurves: UInt8
    }

    public static func addresses(slot: Int) -> Addresses? {
        guard (1...3).contains(slot) else { return nil }
        let base = UInt8(0x20 + (slot - 1) * 2)
        return Addresses(normalMapping: base, normalCurves: base + 1, shiftMapping: base + 6, shiftCurves: base + 7)
    }
}

import Foundation

/// What a 0x1E calibration request applies to. The values are the bits the
/// Accessories app sends.
public enum CalibrationTarget: UInt8, Codable, Sendable, CaseIterable, Identifiable {
    case leftStick = 0x01
    case rightStick = 0x02
    case leftTrigger = 0x04
    case rightTrigger = 0x08

    public var id: UInt8 { rawValue }

    public var isTrigger: Bool { self == .leftTrigger || self == .rightTrigger }

    public var shortLabel: String {
        switch self {
        case .leftStick: "LS"
        case .rightStick: "RS"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        }
    }

    public var label: String {
        switch self {
        case .leftStick: "left stick"
        case .rightStick: "right stick"
        case .leftTrigger: "left trigger"
        case .rightTrigger: "right trigger"
        }
    }
}

/// 0x1E sub-commands, from Windows captures of the Accessories app's
/// thumbstick and trigger calibration (firmware 5.22.16.0).
public enum CalibrationCommand {
    /// `0f <target>`: the calibration values. Before a calibration starts
    /// they're the stored ones; after it, the newly collected ones.
    public static let read: UInt8 = 0x0F
    /// `10 <target>`: starts collecting. The controller records the
    /// movement until it has seen the Accessories app's whole sequence;
    /// the first read after that ends the calibration and stores it.
    public static let start: UInt8 = 0x10
}

/// One target's calibration as the controller reports it, in raw 12-bit
/// sensor units (0-4095).
public struct CalibrationReading: Codable, Equatable, Sendable {
    public var target: CalibrationTarget
    public var state: State
    /// Sticks: X minimum, X maximum, Y minimum, Y maximum. Triggers: the
    /// sensor reading at rest and at the end of the pull for each hair
    /// trigger lock (short, half, full), lowest first. All zero for the
    /// target being calibrated until it finishes.
    public var values: [UInt16]

    /// The reply's state byte, which describes the controller rather than
    /// the target read.
    public enum State: Codable, Equatable, Sendable {
        /// 0x00: no calibration running.
        case idle
        /// The targets (bits) being calibrated. The controller keeps
        /// collecting until it has seen the whole movement sequence.
        case collecting(UInt8)
        /// 0x10: the read that ended a finished calibration, which stores it.
        case finished

        init(_ byte: UInt8) {
            switch byte {
            case 0x00: self = .idle
            case 0x10: self = .finished
            default: self = .collecting(byte)
            }
        }
    }

    public init(target: CalibrationTarget, state: State, values: [UInt16]) {
        self.target = target
        self.state = state
        self.values = values
    }

    /// Parses a read reply payload: `0f <status> <state> <target>`, then for
    /// a trigger a point count, then the values as little-endian u16.
    public init?(reply: [UInt8]) {
        guard reply.count >= 4, reply[0] == CalibrationCommand.read,
              let target = CalibrationTarget(rawValue: reply[3]) else { return nil }
        var rest = Array(reply.dropFirst(4))
        if target.isTrigger {
            guard let count = rest.first else { return nil }
            rest = Array(rest.dropFirst().prefix(Int(count) * 2))
        }
        guard rest.count >= 2 else { return nil }
        self.target = target
        state = State(reply[2])
        values = stride(from: 0, to: rest.count - 1, by: 2).map { UInt16(rest[$0]) | UInt16(rest[$0 + 1]) << 8 }
    }

    /// Whether this target is still being calibrated.
    public var isCollecting: Bool {
        if case .collecting(let mask) = state { return mask & target.rawValue != 0 }
        return false
    }
}

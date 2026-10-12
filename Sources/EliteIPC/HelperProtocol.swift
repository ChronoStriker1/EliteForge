import EliteKit
import Foundation

/// Mach service the root helper listens on. Also its launchd label.
public let helperServiceName = "com.eliteforge.helper"

/// Bumped whenever the request/reply format changes, so the app can tell
/// the installed helper is out of date and offer to reinstall it.
public let helperProtocolVersion = 18

/// The helper's XPC interface. Requests and replies are JSON-encoded
/// `HelperRequest` / `HelperReply` values, which keeps the XPC surface to one method.
@objc public protocol HelperXPCProtocol {
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}

/// Implemented by clients to receive `HelperEvent`s.
@objc public protocol HelperClientXPCProtocol {
    func receive(_ event: Data)
}

public enum HelperRequest: Codable, Sendable {
    /// Returns `.status`.
    case status
    /// Captures the controller for configuration. Games can't see it until `detach`.
    case attach
    /// Releases the controller back to macOS.
    case detach
    case readSlot(Int)
    /// `serial` is the controller the write is meant for; the helper refuses
    /// it if a different one is connected. nil writes to whatever is there.
    case writeSlot(Int, SlotPages, serial: String?)
    case readName
    case writeName(String, serial: String?)
    /// Shows a colour on the Xbox button without saving it. nil shows the default white.
    case previewLight(RGBColor?)
    case endLightPreview
    /// Colour (already scaled for brightness) to show on the Xbox button
    /// whenever the controller is on its Default profile, which can't store
    /// one. The helper re-applies it after profile switches and restarts.
    /// nil turns it off.
    case setDefaultLight(RGBColor?)
    case rumble(leftGrip: UInt8, rightGrip: UInt8, leftTrigger: UInt8, rightTrigger: UInt8)
    /// Returns `.calibration`. The first read after a calibration's movement
    /// sequence is complete ends it and stores it.
    case readCalibration(CalibrationTarget)
    /// Starts calibrating a stick or trigger in the controller's firmware.
    case startCalibration(CalibrationTarget, serial: String?)
    /// Sends every raw USB frame to this client as `.trace` events. For debugging.
    case setTrace(Bool)
    /// Sends raw bytes to the controller. Only honoured by helpers built with
    /// `-D HELPER_RAW_SEND` for protocol work; release helpers refuse it.
    case sendRaw([UInt8])
    /// Whether the next capture runs the GIP init sequence. Developer helpers only.
    case setInitSequence(Bool)
}

public enum HelperReply: Codable, Sendable {
    case ok
    case status(ControllerStatus)
    case pages(SlotPages)
    case name(String)
    case calibration(CalibrationReading)
    case failure(String)
}

public enum HelperEvent: Codable, Sendable {
    case status(ControllerStatus)
    case input(InputState)
    /// A raw frame, "> " for sent and "< " for received. Only with `setTrace(true)`.
    case trace(String)
}

public struct ControllerStatus: Codable, Sendable, Equatable {
    public var helperVersion: Int
    /// A wired Elite Series 2 is plugged in.
    public var present: Bool
    /// The helper has captured the controller.
    public var attached: Bool
    public var info: DeviceInfo?
    public var serialNumber: String?
    public var battery: BatteryStatus?
    public var activeSlot: Int?

    public init(helperVersion: Int = helperProtocolVersion, present: Bool = false, attached: Bool = false,
                info: DeviceInfo? = nil, serialNumber: String? = nil, battery: BatteryStatus? = nil, activeSlot: Int? = nil) {
        self.helperVersion = helperVersion
        self.present = present
        self.attached = attached
        self.info = info
        self.serialNumber = serialNumber
        self.battery = battery
        self.activeSlot = activeSlot
    }
}

public enum HelperCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

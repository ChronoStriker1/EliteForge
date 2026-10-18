import Foundation

public struct RGBColor: Hashable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB`, with or without the `#`, in either case.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.first == "#" { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// `#RRGGBB`, upper case.
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    public func scaled(by brightness: Int) -> RGBColor {
        let factor = Double(max(0, min(brightness, 100))) / 100
        return RGBColor(red: UInt8(Double(red) * factor), green: UInt8(Double(green) * factor), blue: UInt8(Double(blue) * factor))
    }
}

/// One control point of a stick response curve, both coordinates 0-255.
public struct CurvePoint: Hashable, Codable, Sendable {
    public var x: UInt8
    public var y: UInt8

    public init(x: UInt8, y: UInt8) {
        self.x = x
        self.y = y
    }
}

/// A stick response curve: three control points between (0,0) and (255,255).
public struct StickCurve: Hashable, Codable, Sendable {
    public var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        precondition(points.count == 3)
        self.points = points
    }

    private enum CodingKeys: String, CodingKey { case points }

    /// Rejects curves that don't have exactly three points, so an imported
    /// file can't produce a malformed curves page or crash the editor.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let points = try container.decode([CurvePoint].self, forKey: .points)
        guard points.count == 3 else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: container, debugDescription: "A stick curve needs exactly 3 points, found \(points.count).")
        }
        self.points = points
    }

    init(bytes: ArraySlice<UInt8>) {
        let b = Array(bytes)
        points = [CurvePoint(x: b[0], y: b[1]), CurvePoint(x: b[2], y: b[3]), CurvePoint(x: b[4], y: b[5])]
    }

    var bytes: [UInt8] { points.flatMap { [$0.x, $0.y] } }

    /// Output (0-1) for an input deflection (0-1), worked out the way the
    /// firmware does it, in 15-bit integers: straight lines through (0, 0),
    /// the three placed points and (32767, 32767).
    public func output(for input: Double) -> Double {
        let deflection = Int((max(0, min(1, input)) * 32767).rounded())
        let knots = [(x: 0, y: 0)] + firmwarePoints + [(x: 32767, y: 32767)]
        // The same segment choice as firmware 0x10050612: the first point
        // the input is still left of ends the segment.
        let end = (1...3).first { deflection < knots[$0].x } ?? 4
        let (from, to) = (knots[end - 1], knots[end])
        return Double(Self.firmwareMap(deflection, from: from.x, to.x, onto: from.y, to.y)) / 32767
    }

    /// Where the firmware puts the three points, as fractions of full
    /// deflection. Points 2 and 3 are stored as fractions of the range above
    /// point 1, so they only sit where their bytes say when point 1 is at (0, 0).
    public var placedPoints: [(x: Double, y: Double)] {
        firmwarePoints.map { (Double($0.x) / 32767, Double($0.y) / 32767) }
    }

    /// The curve with one point moved so the firmware places it at `x`, `y`
    /// (fractions of full deflection). Points 2 and 3 stay in order.
    public func moving(point index: Int, toPlaced x: Double, _ y: Double) -> StickCurve {
        func byte(_ fraction: Double) -> Int { Int((max(0, min(1, fraction)) * 255).rounded()) }
        /// The stored fraction that the firmware places at `placed` above `base`.
        func relative(_ placed: Double, above base: Double) -> Double { base < 1 ? (placed - base) / (1 - base) : 0 }
        var points = self.points
        let first = placedPoints[0]
        let (storedX, storedY) = index == 0 ? (x, y) : (relative(x, above: first.x), relative(y, above: first.y))
        let lower = index == 2 ? Int(points[1].x) + 1 : 1
        let upper = index == 1 ? Int(points[2].x) - 1 : 254
        guard lower <= upper else { return self }
        points[index] = CurvePoint(x: UInt8(min(max(byte(storedX), lower), upper)), y: UInt8(byte(storedY)))
        return StickCurve(points: points)
    }

    /// The points as the firmware uses them (0x10050612): each byte scaled to
    /// 15 bits (0x10050608), then points 2 and 3 mapped into the range above point 1.
    private var firmwarePoints: [(x: Int, y: Int)] {
        func scale(_ byte: UInt8) -> Int { Int(byte) * 128 + Int(byte) / 2 }
        let x1 = scale(points[0].x), y1 = scale(points[0].y)
        return [(x1, y1)] + points.dropFirst().map {
            (Self.firmwareMap(scale($0.x), from: 0, 32767, onto: x1, 32767), Self.firmwareMap(scale($0.y), from: 0, 32767, onto: y1, 32767))
        }
    }

    /// The firmware's clamped linear map (0x1004e0ca), with its integer
    /// division that rounds toward zero.
    private static func firmwareMap(_ value: Int, from low: Int, _ high: Int, onto outLow: Int, _ outHigh: Int) -> Int {
        if value >= high { return outHigh }
        if value <= low { return outLow }
        return outLow + (value - low) * (outHigh - outLow) / (high - low)
    }

    public var preset: CurvePreset? { CurvePreset.allCases.first { $0.curve == self } }
}

/// Named response curves, in the Accessories app's order. `.standard` is the
/// controller's factory curve and matches a captured page. The other four
/// are the table entries the Accessories app writes for its presets
/// (Devices.App.dll 0x180c28980), not yet captured; which name goes with
/// which entry is inferred from the order of the app's preset constants.
/// The case names predate the Accessories labels; they stay as the raw values.
public enum CurvePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard, delay, aggressive, instant, smooth

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: "Default"
        case .delay: "Slow start"
        case .aggressive: "Fast start"
        case .instant: "Instant"
        case .smooth: "Smooth"
        }
    }

    public var curve: StickCurve {
        func c(_ v: [UInt8]) -> StickCurve {
            StickCurve(points: [CurvePoint(x: v[0], y: v[1]), CurvePoint(x: v[2], y: v[3]), CurvePoint(x: v[4], y: v[5])])
        }
        switch self {
        case .standard: return c([0x2B, 0x2B, 0x7F, 0x7F, 0xBF, 0xBF])
        case .delay: return c([0x2B, 0x2B, 0x3F, 0x3F, 0xDA, 0x8D])
        case .aggressive: return c([0x2B, 0x2B, 0x3F, 0x3F, 0x8C, 0xC5])
        case .instant: return c([0x2B, 0x2B, 0x3F, 0x3F, 0x3F, 0x68])
        case .smooth: return c([0x2B, 0x2B, 0x8C, 0x8C, 0xD8, 0x9C])
        }
    }
}

public struct StickSettings: Hashable, Codable, Sendable {
    public var curve: StickCurve
    public var invertY: Bool

    public init(curve: StickCurve = CurvePreset.standard.curve, invertY: Bool = false) {
        self.curve = curve
        self.invertY = invertY
    }

    /// Largest dead zone offered, as a 0-255 stick position (about 40%).
    public static let maxDeadZone: UInt8 = 102

    /// Dead zone for new and reset profiles: 11%. Elite Series 2 sticks
    /// commonly rest 5-10% off centre; this covers that with a small margin.
    public static let recommendedDeadZone: UInt8 = 28

    /// The controller's factory curve with the recommended dead zone.
    public static var recommended: StickSettings {
        var settings = StickSettings()
        settings.deadZone = recommendedDeadZone
        return settings
    }

    /// Inner dead zone as a 0-255 stick position. It's stored in the curve:
    /// with the first point on the bottom axis at (deadZone, 0), the output
    /// stays at zero until the stick passes it. Changing it keeps the curve's
    /// preset, if it has one.
    public var deadZone: UInt8 {
        get { curve.points[0].y == 0 ? curve.points[0].x : 0 }
        set { curve = Self.curve(preset?.curve ?? curve, deadZone: newValue) }
    }

    /// The preset this curve was made from, ignoring the dead zone.
    public var preset: CurvePreset? {
        let zone = deadZone
        return CurvePreset.allCases.first { Self.curve($0.curve, deadZone: zone) == curve }
    }

    /// Switches to a preset's shape and keeps the dead zone.
    public mutating func apply(_ preset: CurvePreset) {
        curve = Self.curve(preset.curve, deadZone: deadZone)
    }

    /// `curve` with its first point moved to make a dead zone of `zone`.
    /// Points 2 and 3 keep their bytes: the firmware places them in the
    /// travel past point 1, so the rest of the curve fits after the dead zone.
    static func curve(_ curve: StickCurve, deadZone zone: UInt8) -> StickCurve {
        var points = curve.points
        let zone = min(zone, maxDeadZone)
        if zone > 0 {
            points[0] = CurvePoint(x: zone, y: 0)
        } else if points[0].y == 0 {
            // Back to the first point the Accessories app always writes. A
            // curve that has no dead zone stays as it is.
            points[0] = CurvePreset.standard.curve.points[0]
        }
        return StickCurve(points: points)
    }

    public var deadZonePercent: Int { Int((Double(deadZone) / 255 * 100).rounded()) }
}

public struct TriggerSettings: Hashable, Codable, Sendable {
    /// Trigger range from the Accessories app: how far the trigger travels
    /// (0-255) before it reports a full press. 255 uses the whole travel,
    /// lower values reach full sooner, and 0 makes the trigger on or off.
    /// Stored as a u16 LE at mapping bytes 32-33 for LT and 38-39 for RT,
    /// following upstream xbelite2. 67% is 0xAB; the high byte is zero.
    public var range: UInt8

    public init(range: UInt8 = 0xFF) { self.range = range }

    public var rangePercent: Int { Int((Double(range) / 255 * 100).rounded()) }

    /// The byte for a percentage, rounded the way the Accessories app does (67% = 0xAB).
    public static func range(percent: Int) -> UInt8 {
        UInt8((Double(min(max(percent, 0), 100)) * 255 / 100).rounded())
    }

    /// What a game would read for `pull` (0-1 of the travel).
    public func output(forPull pull: Double) -> Double {
        guard pull > 0 else { return 0 }
        guard range > 0 else { return 1 }
        return min(1, pull / (Double(range) / 255))
    }
}

/// The Accessories app's "same range for both triggers" option. It isn't
/// stored, only the two ranges are. It starts on when they match, and after
/// that only `turnOn` and `turnOff` change it, so moving one range past the
/// other's value doesn't link them.
public struct TriggerRangeLink: Equatable, Sendable {
    public private(set) var isOn: Bool

    public init(_ profile: EliteProfile) {
        isOn = profile.leftTrigger.range == profile.rightTrigger.range
    }

    /// Links the triggers, giving the right one the left one's range.
    public mutating func turnOn(in profile: inout EliteProfile) {
        isOn = true
        profile.rightTrigger.range = profile.leftTrigger.range
    }

    public mutating func turnOff() { isOn = false }

    /// Sets one trigger's range, and while linked the other's too.
    public func setRange(_ range: UInt8, of trigger: WritableKeyPath<EliteProfile, TriggerSettings>, in profile: inout EliteProfile) {
        if isOn {
            profile.leftTrigger.range = range
            profile.rightTrigger.range = range
        } else {
            profile[keyPath: trigger].range = range
        }
    }
}

/// Rumble strength per motor, 0-100.
public struct VibrationSettings: Hashable, Codable, Sendable {
    public var leftGrip: UInt8
    public var rightGrip: UInt8
    public var leftTrigger: UInt8
    public var rightTrigger: UInt8

    public init(leftGrip: UInt8 = 100, rightGrip: UInt8 = 100, leftTrigger: UInt8 = 100, rightTrigger: UInt8 = 100) {
        self.leftGrip = leftGrip
        self.rightGrip = rightGrip
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }
}

public struct LightSettings: Hashable, Codable, Sendable {
    /// 0-100.
    public var brightness: UInt8
    /// nil keeps the default white.
    public var color: RGBColor?

    public init(brightness: UInt8 = 100, color: RGBColor? = nil) {
        self.brightness = brightness
        self.color = color
    }
}

/// Version of the page layout, in byte 0 of every page: major in the high
/// nibble, minor in the low. The mapping page is the same size in both; 1.1
/// adds curves bytes 28-42 (sticky inputs and the Adaptive Controller's
/// extra inputs).
public enum ProfileFormat: UInt8, CaseIterable, Comparable, Sendable {
    case v1_0 = 0x10
    case v1_1 = 0x11

    /// The format the Accessories app writes for a controller: 1.1 from
    /// firmware 5.21.3242.0 on, whatever format the slot was in. The
    /// controller only reports its firmware at power-up, so it can be
    /// unknown; that gives 1.1, which EliteForge has always written and which
    /// was tested on 5.22.16.0.
    public init(firmware: String?) {
        let parts = firmware?.split(separator: ".").compactMap { Int($0) } ?? []
        self = parts.count == 4 && parts.lexicographicallyPrecedes([5, 21, 3242, 0]) ? .v1_0 : .v1_1
    }

    public var curvesSize: Int { self == .v1_0 ? 28 : 43 }

    public static func < (lhs: ProfileFormat, rhs: ProfileFormat) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The four raw pages that make up one controller slot.
public struct SlotPages: Hashable, Codable, Sendable {
    public var normalMapping: [UInt8]
    public var normalCurves: [UInt8]
    public var shiftMapping: [UInt8]
    public var shiftCurves: [UInt8]

    public init(normalMapping: [UInt8], normalCurves: [UInt8], shiftMapping: [UInt8], shiftCurves: [UInt8]) {
        self.normalMapping = normalMapping
        self.normalCurves = normalCurves
        self.shiftMapping = shiftMapping
        self.shiftCurves = shiftCurves
    }

    public static let factoryDefault = SlotPages(
        normalMapping: MappingLayout.defaultPage, normalCurves: CurvesLayout.defaultPage,
        shiftMapping: MappingLayout.defaultPage, shiftCurves: CurvesLayout.defaultPage
    )

    /// Mapping pages of 56 bytes and both curves pages the size of one format.
    public var isValid: Bool {
        normalMapping.count == MappingLayout.size && shiftMapping.count == MappingLayout.size
            && normalCurves.count == shiftCurves.count && ProfileFormat.allCases.contains { $0.curvesSize == normalCurves.count }
    }
}

/// A complete controller configuration, as edited in the app and stored in the library.
public struct EliteProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var modified: Date

    /// Assignments for the normal layer. Missing entries mean `.standard`.
    public var buttons: [RemappableControl: Assignment]
    /// Assignments while the shift button is held. Missing entries mean `.standard`.
    public var shiftButtons: [RemappableControl: Assignment]
    public var leftStick: StickSettings
    public var rightStick: StickSettings
    public var leftTrigger: TriggerSettings
    public var rightTrigger: TriggerSettings
    public var vibration: VibrationSettings
    public var light: LightSettings

    /// Pages this profile was last read from or written to. Bytes the app
    /// doesn't understand are carried over from here unchanged.
    public var basePages: SlotPages

    public init(
        id: UUID = UUID(), name: String, modified: Date = Date(),
        buttons: [RemappableControl: Assignment] = [:], shiftButtons: [RemappableControl: Assignment] = [:],
        leftStick: StickSettings = StickSettings(), rightStick: StickSettings = StickSettings(),
        leftTrigger: TriggerSettings = TriggerSettings(), rightTrigger: TriggerSettings = TriggerSettings(),
        vibration: VibrationSettings = VibrationSettings(), light: LightSettings = LightSettings(),
        basePages: SlotPages = .factoryDefault
    ) {
        self.id = id
        self.name = name
        self.modified = modified
        self.buttons = buttons
        self.shiftButtons = shiftButtons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.vibration = vibration
        self.light = light
        self.basePages = basePages
    }

    public func assignment(for control: RemappableControl, shift: Bool) -> Assignment {
        (shift ? shiftButtons : buttons)[control] ?? .standard
    }

    public mutating func setAssignment(_ assignment: Assignment, for control: RemappableControl, shift: Bool) {
        let value: Assignment? = assignment == .standard ? nil : assignment
        if assignment == .shift {
            // One shift button per profile, and it must act as shift in both
            // layers, the same as the Accessories app writes it.
            for other in RemappableControl.allCases where other != control {
                if buttons[other] == .shift { buttons[other] = nil }
                if shiftButtons[other] == .shift { shiftButtons[other] = nil }
            }
            buttons[control] = .shift
            shiftButtons[control] = .shift
            return
        }
        let wasShift = (shift ? shiftButtons : buttons)[control] == .shift
        if shift { shiftButtons[control] = value } else { buttons[control] = value }
        if wasShift {
            if shift { buttons[control] = nil } else { shiftButtons[control] = nil }
        }
    }

    /// True when every setting matches a freshly reset slot, which includes
    /// the recommended stick dead zone.
    public var hasDefaultSettings: Bool {
        buttons.isEmpty && shiftButtons.isEmpty
            && leftStick == .recommended && rightStick == .recommended
            && leftTrigger == TriggerSettings() && rightTrigger == TriggerSettings()
            && vibration == VibrationSettings() && light == LightSettings()
    }

    /// The gamepad button `control` produces in a layer. Triggers, unmapped
    /// and shift controls, and keyboard keys produce none.
    public func output(of control: RemappableControl, shift: Bool) -> GamepadButton? {
        switch assignment(for: control, shift: shift) {
        case .standard: control.standardOutput
        case .button(let button): button
        case .disabled, .shift, .key: nil
        }
    }

    /// The Accessories app warns when nothing on the normal layer produces
    /// one of these, since A confirms and B goes back on Xbox and in most games.
    public static let essentialButtons: [GamepadButton] = [.a, .b]

    /// Essential buttons that no control produces on the normal layer.
    public var unmappedEssentialButtons: [GamepadButton] {
        let produced = Set(RemappableControl.allCases.compactMap { output(of: $0, shift: false) })
        return Self.essentialButtons.filter { !produced.contains($0) }
    }

    public var shiftControl: RemappableControl? {
        RemappableControl.allCases.first { buttons[$0] == .shift }
    }

    /// Factory settings, except the sticks get the recommended dead zone.
    public static func factoryDefault(name: String = "New profile") -> EliteProfile {
        EliteProfile(name: name, leftStick: .recommended, rightStick: .recommended)
    }
}

/// Converts between `EliteProfile` and the raw slot pages.
public enum ProfileCodec {
    public enum CodecError: Error, LocalizedError {
        case badPageSize
        public var errorDescription: String? { "The controller returned profile pages of an unexpected size." }
    }

    public static func decode(_ pages: SlotPages, name: String, id: UUID = UUID()) throws -> EliteProfile {
        guard pages.isValid else { throw CodecError.badPageSize }
        let normal = pages.normalMapping
        let curves = pages.normalCurves
        let rumble = MappingLayout.rumbleIntensity
        var light = LightSettings(brightness: normal[MappingLayout.brightness])
        if normal[MappingLayout.colorFlag] != 0xFF {
            let c = MappingLayout.color
            light.color = RGBColor(red: normal[c], green: normal[c + 1], blue: normal[c + 2])
        }
        let inversion = curves[CurvesLayout.inversion]
        return EliteProfile(
            id: id, name: name,
            buttons: decodeAssignments(normal),
            shiftButtons: decodeAssignments(pages.shiftMapping),
            leftStick: StickSettings(curve: StickCurve(bytes: curves[1..<7]), invertY: inversion & 0x01 != 0),
            rightStick: StickSettings(curve: StickCurve(bytes: curves[13..<19]), invertY: inversion & 0x02 != 0),
            leftTrigger: TriggerSettings(range: normal[MappingLayout.leftTriggerRange]),
            rightTrigger: TriggerSettings(range: normal[MappingLayout.rightTriggerRange]),
            vibration: VibrationSettings(leftGrip: normal[rumble + 1], rightGrip: normal[rumble], leftTrigger: normal[rumble + 3], rightTrigger: normal[rumble + 2]),
            light: light,
            basePages: pages
        )
    }

    /// Pages in `format`, which the controller's firmware decides
    /// (`ProfileFormat(firmware:)`), not the pages the profile was read from.
    public static func encode(_ profile: EliteProfile, format: ProfileFormat) -> SlotPages {
        let base = profile.basePages.isValid ? profile.basePages : .factoryDefault
        func versioned(_ page: [UInt8]) -> [UInt8] {
            var page = page
            page[0] = format.rawValue
            return page
        }
        // A curves page in the other format is cut short or filled in from the default page.
        func curves(_ page: [UInt8]) -> [UInt8] {
            versioned(Array((page + CurvesLayout.defaultPage.dropFirst(page.count)).prefix(format.curvesSize)))
        }
        return SlotPages(
            normalMapping: versioned(encodeMapping(base.normalMapping, profile: profile, assignments: profile.buttons)),
            normalCurves: curves(encodeCurves(base.normalCurves, profile: profile)),
            shiftMapping: versioned(encodeMapping(base.shiftMapping, profile: profile, assignments: profile.shiftButtons)),
            shiftCurves: curves(encodeCurves(base.shiftCurves, profile: profile))
        )
    }

    static func decodeAssignments(_ page: [UInt8]) -> [RemappableControl: Assignment] {
        var result: [RemappableControl: Assignment] = [:]
        let keyboard = page[MappingLayout.keyboardFlags] & MappingLayout.keyboardFlagValue != 0
        for (index, control) in RemappableControl.paddles.enumerated() {
            let code = page[control.mappingOffset]
            if code == MappingLayout.defaultPaddleOutputs[index] { continue }
            result[control] = assignment(forCode: code)
        }
        for control in RemappableControl.buttons {
            let code = page[control.mappingOffset]
            if code == control.nativeButton!.rawValue { continue }
            result[control] = assignment(forCode: code)
        }
        for control in RemappableControl.triggers {
            let code = page[control.mappingOffset]
            if code == 0 { continue }
            result[control] = keyboard ? .key(KeyboardKey(usage: code)) : assignment(forCode: code)
        }
        return result
    }

    static func assignment(forCode code: UInt8) -> Assignment {
        switch code {
        case MappingLayout.codeDisabled: return .disabled
        case MappingLayout.codeShift: return .shift
        default:
            if let button = GamepadButton(rawValue: code) { return .button(button) }
            return .key(KeyboardKey(usage: code))
        }
    }

    static func code(for assignment: Assignment, control: RemappableControl) -> UInt8 {
        switch assignment {
        case .standard: return control.standardOutput?.rawValue ?? 0x00
        case .disabled: return MappingLayout.codeDisabled
        case .shift: return MappingLayout.codeShift
        case .button(let button): return button.rawValue
        case .key(let key): return key.usage
        }
    }

    static func encodeMapping(_ base: [UInt8], profile: EliteProfile, assignments: [RemappableControl: Assignment]) -> [UInt8] {
        var page = base
        var usesKeyboard = false
        for control in RemappableControl.allCases {
            let assignment = assignments[control] ?? .standard
            if control.isTrigger, case .key = assignment { usesKeyboard = true }
            page[control.mappingOffset] = code(for: assignment, control: control)
        }
        if usesKeyboard {
            page[MappingLayout.keyboardFlags] |= MappingLayout.keyboardFlagValue
        } else {
            page[MappingLayout.keyboardFlags] &= ~MappingLayout.keyboardFlagValue
        }

        let rumble = MappingLayout.rumbleIntensity
        page[rumble] = min(profile.vibration.rightGrip, 100)
        page[rumble + 1] = min(profile.vibration.leftGrip, 100)
        page[rumble + 2] = min(profile.vibration.rightTrigger, 100)
        page[rumble + 3] = min(profile.vibration.leftTrigger, 100)

        page[MappingLayout.leftTriggerRange] = profile.leftTrigger.range
        page[MappingLayout.leftTriggerRange + 1] = 0
        page[MappingLayout.rightTriggerRange] = profile.rightTrigger.range
        page[MappingLayout.rightTriggerRange + 1] = 0

        page[MappingLayout.brightness] = min(profile.light.brightness, 100)
        let c = MappingLayout.color
        if let color = profile.light.color {
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

    /// Stick settings are stored in both layers' curves pages. The Accessories
    /// app sometimes leaves the shift layer's copy alone, so only settings the
    /// user changed relative to the base pages are written, and they go to both layers.
    static func encodeCurves(_ base: [UInt8], profile: EliteProfile) -> [UInt8] {
        var page = base
        let original = profile.basePages.isValid ? profile.basePages.normalCurves : CurvesLayout.defaultPage
        let originalInversion = original[CurvesLayout.inversion]
        let sticks: [(StickSettings, Int, UInt8)] = [(profile.leftStick, 0, 0x01), (profile.rightStick, 2, 0x02)]
        for (stick, firstAxis, bit) in sticks {
            // Decoding exposes the X-axis curve for each stick. Only when the
            // user changed it do both axes get the new curve; otherwise an
            // independent Y curve stays as it was.
            let xOffset = CurvesLayout.curveOffsets[firstAxis]
            if StickCurve(bytes: original[xOffset..<xOffset + 6]) != stick.curve {
                for axis in firstAxis..<firstAxis + 2 {
                    let offset = CurvesLayout.curveOffsets[axis]
                    page.replaceSubrange(offset..<offset + 6, with: stick.curve.bytes)
                }
            }
            if (originalInversion & bit != 0) != stick.invertY {
                if stick.invertY { page[CurvesLayout.inversion] |= bit } else { page[CurvesLayout.inversion] &= ~bit }
            }
        }
        return page
    }
}

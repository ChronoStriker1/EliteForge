import EliteIPC
import EliteKit
import EliteUSB
import Foundation

// Command-line access to the controller, through the root helper or, with
// --direct and sudo, straight over USB.

let usage = """
usage: forgectl [--direct] [--trace] <command> [arguments]

commands:
  status                         controller and helper state
  name [NEW_NAME]                read or set the controller name (15 characters max)
  read <profile> [--json | --raw]   show controller profile 1-3
  write <profile> <file.json>      write a setup exported with `read --json` or the app
  write-raw <profile> <file.json>  write raw pages saved with `read --raw`
  reset <profile>                  restore a profile to factory defaults
  light <RRGGBB | default>       preview an Xbox button colour for a few seconds
  rumble <lgrip> <rgrip> <ltrig> <rtrig> [seconds]   test motors, values 0-100
  calibration [target]           show the stored calibration (targets: ls, rs, lt, rt)
  calibrate <target> [seconds]   recalibrate a stick or trigger; ends on Enter or after the seconds
  watch [seconds]                print live input (default 30 seconds)
  trace [seconds]                print raw USB frames (default 10 seconds)
  send <hex bytes>               send a raw frame (developer helper builds only)
  init-sequence <on|off>         run GIP init on the next capture (developer helper builds only)
  detach                         release the controller back to macOS

--direct  talk to the controller over USB without the helper (needs sudo)
--trace   with --direct, print every frame sent and received
"""

protocol Backend {
    func perform(_ request: HelperRequest) throws -> HelperReply
    func watch(seconds: Double, _ handler: @escaping (InputState) -> Void) throws
    func trace(seconds: Double, _ handler: @escaping (String) -> Void) throws
    func finish()
}

final class HelperBackend: Backend {
    let client = HelperClient()
    var inputHandler: ((InputState) -> Void)?
    var traceHandler: ((String) -> Void)?

    init() {
        client.onEvent = { [weak self] event in
            switch event {
            case .input(let state): self?.inputHandler?(state)
            case .trace(let line): self?.traceHandler?(line)
            case .status: break
            }
        }
    }

    func trace(seconds: Double, _ handler: @escaping (String) -> Void) throws {
        traceHandler = handler
        _ = try perform(.setTrace(true))
        _ = try perform(.attach)
        Thread.sleep(forTimeInterval: seconds)
        _ = try? perform(.setTrace(false))
    }

    func perform(_ request: HelperRequest) throws -> HelperReply {
        try client.performSync(request, timeout: 20)
    }

    func watch(seconds: Double, _ handler: @escaping (InputState) -> Void) throws {
        inputHandler = handler
        _ = try perform(.attach)
        Thread.sleep(forTimeInterval: seconds)
    }

    func finish() {
        _ = try? perform(.detach)
        client.disconnect()
    }
}

final class DirectBackend: Backend {
    let controller: EliteUSBController
    var input = InputState()
    var inputHandler: ((InputState) -> Void)?

    init(trace: Bool) throws {
        controller = try EliteUSBController()
        if trace { controller.trace = { print($0) } }
        controller.onEvent = { [weak self] frame in
            guard let self else { return }
            switch frame.command {
            case GIPCommand.input: self.input.apply(input: frame.payload)
            case GIPCommand.guide: self.input.apply(guide: frame.payload)
            case GIPCommand.eliteInput: self.input.apply(elite: frame.payload)
            default: return
            }
            self.inputHandler?(self.input)
        }
        try controller.open()
    }

    func perform(_ request: HelperRequest) throws -> HelperReply {
        let session = controller.session
        switch request {
        case .status:
            return .status(ControllerStatus(present: true, attached: true, info: controller.deviceInfo, serialNumber: controller.serialNumber))
        case .attach, .detach, .setTrace, .setInitSequence:
            return .ok
        case .sendRaw(let bytes):
            guard let frame = GIPFrame(bytes: bytes) else { throw ControllerError.usb("not a GIP frame") }
            try controller.send(GIPFrame(command: frame.command, options: frame.options, sequence: frame.sequence, payload: Array(bytes.dropFirst(4)), lengthOverride: bytes[3]))
            return .ok
        case .readSlot(let slot):
            return .pages(try session.readSlot(slot))
        case .writeSlot(let slot, let pages, _):
            try session.writeSlot(slot, pages: pages)
            return .ok
        case .readName:
            return .name(try session.readName())
        case .writeName(let name, _):
            return .name(try session.writeName(name))
        case .previewLight(let color):
            try session.previewLight(color)
            return .ok
        case .endLightPreview:
            try session.endLightPreview()
            return .ok
        case .setDefaultLight(let color):
            if let color { try session.previewLight(color) } else { try session.endLightPreview() }
            return .ok
        case .rumble(let lg, let rg, let lt, let rt):
            try session.rumble(leftGrip: lg, rightGrip: rg, leftTrigger: lt, rightTrigger: rt)
            return .ok
        case .readCalibration(let target):
            return .calibration(try session.readCalibration(target))
        case .startCalibration(let target, _):
            try session.startCalibration(target)
            return .ok
        }
    }

    func watch(seconds: Double, _ handler: @escaping (InputState) -> Void) throws {
        inputHandler = handler
        Thread.sleep(forTimeInterval: seconds)
    }

    func trace(seconds: Double, _ handler: @escaping (String) -> Void) throws {
        controller.trace = handler
        Thread.sleep(forTimeInterval: seconds)
    }

    func finish() { controller.close() }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("forgectl: \(message)\n".utf8))
    exit(1)
}

func slotArgument(_ args: [String], _ index: Int) -> Int {
    guard index < args.count, let slot = Int(args[index]), (1...3).contains(slot) else { fail("profile must be 1, 2 or 3") }
    return slot
}

/// The connected controller's firmware, which decides the page format. The
/// helper learns it from the HELLO it waits for while capturing, so a helper
/// that has just started knows it only after the attach.
func connectedFirmware(_ backend: Backend) throws -> String? {
    _ = try backend.perform(.attach)
    guard case .status(let status) = try backend.perform(.status) else { return nil }
    return status.info?.firmware
}

func describe(_ profile: EliteProfile, pages: SlotPages) -> String {
    let version = pages.normalMapping[0]
    var lines = [String(format: "Page format %d.%d, curves page %d bytes", version >> 4, version & 0x0F, pages.normalCurves.count)]
    func layer(_ title: String, shift: Bool) {
        let changed = RemappableControl.allCases.filter { profile.assignment(for: $0, shift: shift) != .standard || profile.isSticky($0, shift: shift) }
        lines.append("\(title):" + (changed.isEmpty ? " all default" : ""))
        for control in changed {
            let sticky = profile.isSticky(control, shift: shift) ? ", sticky" : ""
            lines.append("  \(control.shortLabel.padding(toLength: 4, withPad: " ", startingAt: 0)) -> \(profile.assignment(for: control, shift: shift).label)\(sticky)")
        }
    }
    layer("Buttons", shift: false)
    layer("Shift layer", shift: true)
    for (name, stick) in [("Left stick", profile.leftStick), ("Right stick", profile.rightStick)] {
        let curve = stick.preset.map { $0.label + (stick.deadZone > 0 ? ", dead zone \(stick.deadZonePercent)%" : "") } ?? "Custom " + stick.curve.points.map { "(\($0.x),\($0.y))" }.joined(separator: " ")
        lines.append("\(name): curve \(curve)\(stick.invertY ? ", Y inverted" : "")")
    }
    func range(_ trigger: TriggerSettings) -> String {
        trigger.deadZone == 0 ? "full at \(trigger.rangePercent)%" : "from \(trigger.deadZonePercent)%, full at \(trigger.rangePercent)%"
    }
    lines.append("Trigger range: left \(range(profile.leftTrigger)), right \(range(profile.rightTrigger))")
    let swaps = [("sticks", profile.swapSticks), ("triggers", profile.swapsTriggers(shift: false)), ("triggers while Shift is held", profile.swapsTriggers(shift: true))]
    let swapped = swaps.filter { $0.1 }.map { $0.0 }
    if !swapped.isEmpty { lines.append("Swapped: " + swapped.joined(separator: ", ")) }
    // The app writes one range to the full and half lock positions and (0, 0)
    // to short; pages written otherwise get their pairs shown.
    let page = MappingPage(pages.normalMapping)
    for (name, pairs) in [("left", page.leftTrigger), ("right", page.rightTrigger)] where pairs != TriggerLockPairs(pairs.settings) {
        let stored = [("full", pairs.full), ("half", pairs.half), ("short", pairs.short)].map { String(format: "%@ %02x %02x", $0, $1.max, $1.min) }
        lines.append("  \(name) trigger (max, min) per lock position: " + stored.joined(separator: ", "))
    }
    let v = profile.vibration
    lines.append("Vibration: left grip \(v.leftGrip)%, right grip \(v.rightGrip)%, left trigger \(v.leftTrigger)%, right trigger \(v.rightTrigger)%")
    lines.append("Xbox button: brightness \(profile.light.brightness)%, colour \(profile.light.color?.hex ?? "default")")
    return lines.joined(separator: "\n")
}

func calibrationTarget(_ name: String) -> CalibrationTarget {
    switch name.lowercased() {
    case "ls", "left-stick": .leftStick
    case "rs", "right-stick": .rightStick
    case "lt", "left-trigger": .leftTrigger
    case "rt", "right-trigger": .rightTrigger
    default: fail("unknown target \(name): use ls, rs, lt or rt")
    }
}

func describe(_ reading: CalibrationReading) -> String {
    let state: String
    switch reading.state {
    case .idle: state = "stored"
    case .finished: state = "new, stored"
    case .collecting(let mask):
        let names = CalibrationTarget.allCases.filter { mask & $0.rawValue != 0 }.map(\.label).joined(separator: ", ")
        state = reading.isCollecting ? "calibrating" : "stored (calibrating \(names))"
    }
    let v = reading.values
    let values = reading.target.isTrigger
        ? zip(["rest", "short", "half", "full"], v).map { "\($0) \($1)" }.joined(separator: "  ")
        : v.count == 4 ? "X \(v[0])-\(v[1])  Y \(v[2])-\(v[3])" : v.map(String.init).joined(separator: " ")
    return "\(reading.target.label.padding(toLength: 13, withPad: " ", startingAt: 0)) \(state): \(values)"
}

func describe(_ state: InputState) -> String {
    let order = InputButton.allCases.filter { state.buttons.contains($0) }.map(\.shortLabel).joined(separator: " ")
    return String(format: "profile %@  LT %4d RT %4d  LS %6d,%6d  RS %6d,%6d  %@",
                  state.activeSlot.map(String.init) ?? "?", state.leftTrigger, state.rightTrigger,
                  state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY, order)
}

var args = Array(CommandLine.arguments.dropFirst())
let direct = args.contains("--direct")
let trace = args.contains("--trace")
args.removeAll { $0 == "--direct" || $0 == "--trace" }
guard let command = args.first, command != "help", command != "--help", command != "-h" else {
    print(usage)
    exit(0)
}

let backend: Backend
do {
    backend = direct ? try DirectBackend(trace: trace) : HelperBackend()
} catch {
    fail(error.localizedDescription)
}

func run() throws {
    switch command {
    case "status":
        guard case .status(let s) = try backend.perform(.status) else { return }
        print("helper protocol: \(s.helperVersion)")
        print("controller: \(s.present ? "connected over USB" : "not connected")\(s.attached ? ", in configuration mode" : "")")
        if let info = s.info { print("firmware: \(info.firmware)  hardware: \(info.hardware)  id: \(info.deviceID)") }
        if let serial = s.serialNumber { print("serial: \(serial)") }
        if let slot = s.activeSlot { print("active profile: \(slot == 0 ? "0 (Default)" : String(slot))") }
        if let battery = s.battery { print("battery: \(battery.label)") }
    case "name":
        let reply = try backend.perform(args.count > 1 ? .writeName(args[1...].joined(separator: " "), serial: nil) : .readName)
        if case .name(let name) = reply { print(name) }
    case "read":
        let slot = slotArgument(args, 1)
        guard case .pages(let pages) = try backend.perform(.readSlot(slot)) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if args.contains("--raw") {
            print(String(decoding: try encoder.encode(pages), as: UTF8.self))
        } else if args.contains("--json") {
            print(String(decoding: try encoder.encode(try ProfileCodec.decode(pages, name: "Profile \(slot)")), as: UTF8.self))
        } else {
            print("Profile \(slot)")
            print(describe(try ProfileCodec.decode(pages, name: "Profile \(slot)"), pages: pages))
            print("normal mapping: \(pages.normalMapping.hexString)")
            print("shift mapping:  \(pages.shiftMapping.hexString)")
            print("normal curves:  \(pages.normalCurves.hexString)")
            print("shift curves:   \(pages.shiftCurves.hexString)")
        }
    case "write", "write-raw":
        let slot = slotArgument(args, 1)
        guard args.count > 2 else { fail("missing file") }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let pages = command == "write"
            ? ProfileCodec.encode(try JSONDecoder().decode(EliteProfile.self, from: data), format: try ProfileFormat.forWriting(firmware: connectedFirmware(backend)))
            : try JSONDecoder().decode(SlotPages.self, from: data)
        _ = try backend.perform(.writeSlot(slot, pages, serial: nil))
        print("wrote profile \(slot)")
    case "reset":
        let slot = slotArgument(args, 1)
        _ = try backend.perform(.writeSlot(slot, ProfileCodec.encode(.factoryDefault(name: "Profile \(slot)"), format: try ProfileFormat.forWriting(firmware: connectedFirmware(backend))), serial: nil))
        print("profile \(slot) restored to defaults (\(StickSettings.recommended.deadZonePercent)% stick dead zone)")
    case "light":
        guard args.count > 1 else { fail("missing colour") }
        let color: RGBColor? = args[1] == "default" ? nil : RGBColor(hex: args[1])
        if args[1] != "default", color == nil { fail("colour must be RRGGBB") }
        // The helper only plays effects for clients that hold the controller.
        _ = try backend.perform(.attach)
        _ = try backend.perform(.previewLight(color))
        Thread.sleep(forTimeInterval: 4)
        _ = try backend.perform(.endLightPreview)
    case "rumble":
        guard args.count >= 5, let values = Optional(args[1...4].compactMap { UInt8($0) }), values.count == 4 else {
            fail("rumble needs four values 0-100")
        }
        let seconds = args.count > 5 ? Double(args[5]) ?? 1 : 1
        _ = try backend.perform(.attach)
        _ = try backend.perform(.rumble(leftGrip: values[0], rightGrip: values[1], leftTrigger: values[2], rightTrigger: values[3]))
        Thread.sleep(forTimeInterval: seconds)
        _ = try backend.perform(.rumble(leftGrip: 0, rightGrip: 0, leftTrigger: 0, rightTrigger: 0))
    case "calibration":
        let targets = args.count > 1 ? [calibrationTarget(args[1])] : CalibrationTarget.allCases
        for target in targets {
            guard case .calibration(let reading) = try backend.perform(.readCalibration(target)) else { continue }
            print(describe(reading))
        }
    case "calibrate":
        guard args.count > 1 else { fail("calibrate needs a target: ls, rs, lt or rt") }
        let target = calibrationTarget(args[1])
        _ = try backend.perform(.attach)
        if case .calibration(let before) = try backend.perform(.readCalibration(target)) { print("before: \(describe(before))") }
        _ = try backend.perform(.startCalibration(target, serial: nil))
        print(target.isTrigger
              ? "Pull the \(target.label) all the way and let go 12 times with the hair trigger lock on full, then 12 times on half, then 12 times on short."
              : "Circle the \(target.label) around its edge 6 times clockwise, then 6 times counter-clockwise. Then push it up, right, down and left, and let go.")
        if args.count > 2, let seconds = Double(args[2]) {
            print("Finishing in \(Int(seconds)) seconds.")
            fflush(stdout)
            Thread.sleep(forTimeInterval: seconds)
        } else {
            print("Press Enter when done.")
            _ = readLine()
        }
        guard case .calibration(let after) = try backend.perform(.readCalibration(target)) else { return }
        print("after:  \(describe(after))")
        if after.isCollecting { print("The controller hasn't seen the whole sequence yet. Finish the movements and run `forgectl calibration \(args[1])`.") }
    case "watch":
        let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
        var last = ""
        try backend.watch(seconds: seconds) { state in
            let line = describe(state)
            if line != last {
                print(line)
                fflush(stdout)
                last = line
            }
        }
    case "init-sequence":
        _ = try backend.perform(.setInitSequence(args.count > 1 && args[1] == "on"))
        // Keep the connection open briefly so the setting lands before exit.
    case "detach":
        _ = try backend.perform(.detach)
    case "send":
        guard let bytes = [UInt8](hexString: args.dropFirst().joined()), bytes.count >= 4 else { fail("send needs at least 4 hex bytes") }
        _ = try backend.perform(.sendRaw(bytes))
    case "trace":
        let seconds = args.count > 1 ? Double(args[1]) ?? 10 : 10
        try backend.trace(seconds: seconds) { line in
            print(line)
            fflush(stdout)
        }
    default:
        fail("unknown command \(command)\n\(usage)")
    }
}

do {
    try run()
    backend.finish()
} catch {
    backend.finish()
    fail(error.localizedDescription)
}

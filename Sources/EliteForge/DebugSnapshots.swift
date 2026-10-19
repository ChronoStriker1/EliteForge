#if DEBUG
import EliteIPC
import EliteKit
import SwiftUI

/// `EliteForge --snapshots <dir>` (debug builds only) renders the main screens
/// to PNG files, for checking the design without a display.
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshots"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        GlassSupport.enabled = false
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = AppModel()
        model.helperState = .ready
        model.status = ControllerStatus(present: true, attached: true, info: DeviceInfo(hello: [UInt8](repeating: 0, count: 12) + [5, 0, 22, 0, 16, 0, 0, 0] + [UInt8](repeating: 1, count: 8)), serialNumber: "3032363330303235303435343235", activeSlot: 1)
        model.controllerName = "Himothy"
        var input = InputState()
        input.buttons = [.a, .paddleUpperRight, .rightBumper]
        input.leftStickX = 18000
        input.leftStickY = 9000
        input.rightTrigger = 700
        input.activeSlot = 1
        model.input = input
        var profile = EliteProfile.factoryDefault(name: "Shooter")
        profile.setAssignment(.button(.rightBumper), for: .paddleUpperRight, shift: false)
        profile.setAssignment(.shift, for: .paddleLowerLeft, shift: false)
        profile.setAssignment(.button(.a), for: .y, shift: false)
        profile.setAssignment(.button(.leftTrigger), for: .paddleLowerRight, shift: false)
        profile.setAssignment(.key(KeyCombination(KeyboardKey(usage: 0x09), modifiers: [.control, .shift])), for: .rightTrigger, shift: false)
        profile.leftStick.curve = CurvePreset.aggressive.curve
        profile.light.brightness = 70
        profile.leftTrigger = TriggerSettings(range: 0xAB, deadZone: 0x1A)
        profile.rightTrigger = profile.leftTrigger
        profile.swapSticks = true
        profile.setSticky(true, for: .paddleUpperRight, shift: false)
        profile.setSticky(true, for: .x, shift: false)
        model.slots[1] = profile
        model.draft = profile
        model.draftSource = .slot(1)

        func render<V: View>(_ name: String, size: CGSize, _ view: V) {
            let renderer = ImageRenderer(content: view.environment(model).environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("failed \(name)")
                return
            }
            try? png.write(to: directory.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }

        render("controller-art", size: CGSize(width: 1000, height: 717), ZStack { CanvasBackground(); EliteControllerArt(input: input, highlighted: [.leftTrigger, .dpadLeft, .paddleLowerLeft], brightness: 80, lightColor: LightColor(red: 0x10, green: 0x40, blue: 0xFF)) })
        render("mapping", size: CGSize(width: 1180, height: 760), ZStack { CanvasBackground(); MappingView(profile: profile, selected: .constant(.paddleUpperRight), pickerOpen: .constant(false)) })
        render("sticks", size: CGSize(width: 1180, height: 1180), ZStack { CanvasBackground(); SticksEditor(profile: profile).padding(20) })
        render("triggers", size: CGSize(width: 1180, height: 480), ZStack { CanvasBackground(); TriggersEditor(profile: profile).padding(20) })
        render("vibration", size: CGSize(width: 1180, height: 460), ZStack { CanvasBackground(); VibrationEditor(profile: profile).padding(20) })
        render("light", size: CGSize(width: 900, height: 320), ZStack { CanvasBackground(); LightEditor(profile: profile).padding(20) })
        var left = StickCheck(), right = StickCheck()
        left.addRest(x: 400, y: -300)
        right.addRest(x: 1900, y: 900)
        for step in 0..<720 {
            let angle = Double(step) / 720 * 2 * .pi
            left.addMotion(x: Int16(max(min(cos(angle) * 1.05, 1), -1) * 32767), y: Int16(max(min(sin(angle) * 1.05, 1), -1) * 32767))
            let short = angle > 1.4 && angle < 3.3 ? 0.92 : 1.0
            right.addMotion(x: Int16(cos(angle) * short * 32767), y: Int16(sin(angle) * short * 32767))
        }
        var leftTrigger = TriggerCheck(), rightTrigger = TriggerCheck()
        leftTrigger.addMotion(1023)
        rightTrigger.addMotion(1023)
        render("stick-check", size: CGSize(width: 1180, height: 460), ZStack { CanvasBackground(); StickCheckCard(finished: left, right, leftTrigger, rightTrigger).padding(20) })
        render("home", size: CGSize(width: 1180, height: 900), ZStack(alignment: .top) { CanvasBackground(glow: 0.6); ControllerDashboard() })

        var unmapped = profile
        unmapped.setAssignment(.disabled, for: .a, shift: false)
        unmapped.setAssignment(.disabled, for: .paddleUpperLeft, shift: false)
        unmapped.setAssignment(.button(.x), for: .b, shift: false)
        unmapped.setAssignment(.disabled, for: .paddleUpperRight, shift: false)
        unmapped.setAssignment(.standard, for: .y, shift: false)
        model.withSnapshotConnection {
            model.input.activeSlot = 0
            model.status.activeSlot = 0
            render("home-live", size: CGSize(width: 1180, height: 1500), ZStack(alignment: .top) { CanvasBackground(glow: 1.2); ControllerDashboard() })
            render("mapping-live", size: CGSize(width: 1180, height: 760), ZStack { CanvasBackground(); MappingView(profile: profile, selected: .constant(.a), pickerOpen: .constant(false)) })
            model.draft = unmapped
            render("editor-unmapped", size: CGSize(width: 1180, height: 900), ProfileEditorView())
        }
        render("assignment-picker", size: CGSize(width: 280, height: 660), ZStack { CanvasBackground(); AssignmentPicker(control: .a, shiftLayer: false, current: .disabled) { _ in } })
        let key = Assignment.key(KeyCombination(KeyboardKey(usage: 0x2C), modifiers: [.control, .alt]))
        var swapped = profile
        swapped.swapsTriggers = true
        render("triggers-swapped", size: CGSize(width: 1180, height: 480), ZStack { CanvasBackground(); TriggersEditor(profile: swapped).padding(20) })
        render("assignment-picker-swapped", size: CGSize(width: 280, height: 600), ZStack { CanvasBackground(); AssignmentPicker(control: .leftTrigger, shiftLayer: false, current: .button(.rightTrigger)) { _ in } })
        render("assignment-picker-trigger-key", size: CGSize(width: 280, height: 600), ZStack { CanvasBackground(); AssignmentPicker(control: .leftTrigger, shiftLayer: false, current: key) { _ in } })
        exit(0)
    }
}
#endif

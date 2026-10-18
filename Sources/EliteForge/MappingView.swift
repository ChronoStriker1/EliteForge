import EliteKit
import SwiftUI

/// Button mapping in the style of the Accessories app: the controller in the
/// middle, a chip per control on either side with a leader line, and an
/// inspector bar for the selected control.
struct MappingView: View {
    @Environment(AppModel.self) private var model
    let profile: EliteProfile
    @Binding var selected: RemappableControl?
    @Binding var pickerOpen: Bool
    @State private var shiftLayer = false

    static let canvas = CGSize(width: 1400, height: 880)
    static let artOrigin = CGPoint(x: 200, y: 40)
    static let chipSize = CGSize(width: 196, height: 50)
    static let left: [RemappableControl] = [.leftTrigger, .leftBumper, .leftStick, .dpadUp, .dpadLeft, .dpadRight, .dpadDown, .paddleUpperLeft, .paddleLowerLeft]
    static let right: [RemappableControl] = [.rightTrigger, .rightBumper, .y, .x, .b, .a, .rightStick, .paddleUpperRight, .paddleLowerRight]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                GlassSegmentedPicker(options: [false, true], selection: $shiftLayer) { $0 ? "While Shift is held" : "Normal" }
                Spacer()
                if model.isConfiguring {
                    Label(model.input.activeSlot == 0 ? "Hold a button or paddle on the controller to remap it" : "To remap by holding a button, switch the controller to Profile 0 (Default)",
                          systemImage: "hand.tap")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let shift = profile.shiftControl {
                    Label("Shift: \(shift.shortLabel)", systemImage: "shift")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassCapsule(tint: .purple)
                }
            }
            .padding(.horizontal, 20)

            GeometryReader { proxy in
                let scale = min(proxy.size.width / Self.canvas.width, proxy.size.height / Self.canvas.height)
                stage
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let selected {
                inspector(for: selected)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            EliteControllerArt(input: model.input, highlighted: selected.map { [$0] } ?? [],
                               brightness: Double(profile.light.brightness), lightColor: profile.light.color)
                .frame(width: EliteControllerArt.size.width, height: EliteControllerArt.size.height)
                .offset(x: Self.artOrigin.x, y: Self.artOrigin.y)

            Canvas { context, _ in
                for (index, control) in Self.left.enumerated() { line(&context, control: control, index: index, leftSide: true) }
                for (index, control) in Self.right.enumerated() { line(&context, control: control, index: index, leftSide: false) }
            }
            .allowsHitTesting(false)

            ForEach(Array(Self.left.enumerated()), id: \.element) { index, control in
                chip(control).position(Self.chipCenter(index: index, leftSide: true))
            }
            ForEach(Array(Self.right.enumerated()), id: \.element) { index, control in
                chip(control).position(Self.chipCenter(index: index, leftSide: false))
            }
        }
    }

    static func chipCenter(index: Int, leftSide: Bool) -> CGPoint {
        CGPoint(x: leftSide ? chipSize.width / 2 + 8 : canvas.width - chipSize.width / 2 - 8, y: 70 + CGFloat(index) * 86)
    }

    private func line(_ context: inout GraphicsContext, control: RemappableControl, index: Int, leftSide: Bool) {
        let chip = Self.chipCenter(index: index, leftSide: leftSide)
        let start = CGPoint(x: chip.x + (leftSide ? 1 : -1) * Self.chipSize.width / 2, y: chip.y)
        let elbow = CGPoint(x: start.x + (leftSide ? 36 : -36), y: chip.y)
        let anchor = EliteControllerArt.anchor(control)
        let end = CGPoint(x: anchor.x + Self.artOrigin.x, y: anchor.y + Self.artOrigin.y)
        var path = Path()
        path.move(to: start)
        path.addLine(to: elbow)
        path.addLine(to: end)
        let isSelected = selected == control
        let pressed = model.input.isPressed(control)
        let changed = profile.assignment(for: control, shift: shiftLayer) != .standard
        let color: Color = isSelected ? .selection : (pressed ? .xboxGlow : (changed ? .white.opacity(0.45) : .white.opacity(0.16)))
        let active = isSelected || pressed
        context.stroke(path, with: .color(color), lineWidth: active ? 2.5 : 1.2)
        context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)), with: .color(color))
    }

    private func chip(_ control: RemappableControl) -> some View {
        let assignment = profile.assignment(for: control, shift: shiftLayer)
        let isSelected = selected == control
        let changed = assignment != .standard
        let pressed = model.input.isPressed(control)
        return Button {
            pickerOpen = false
            withAnimation(.snappy(duration: 0.2)) { selected = control }
        } label: {
            VStack(spacing: 2) {
                Text(control.shortLabel)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(control.isPaddle ? Color.orange : .white)
                Text(chipDetail(control, assignment))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(changed ? Color.xboxGlow : Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: Self.chipSize.width, height: Self.chipSize.height)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: 14, tint: isSelected ? .selection : (assignment == .shift ? .purple : nil), interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(pressed ? Color.xboxGlow : (isSelected ? Color.selection : .clear), lineWidth: pressed ? 3 : 2)
        }
        .scaleEffect(pressed ? 1.04 : 1)
        .animation(.easeOut(duration: 0.1), value: pressed)
    }

    private func chipDetail(_ control: RemappableControl, _ assignment: Assignment) -> String {
        switch assignment {
        case .standard:
            if control.isPaddle, let button = control.standardOutput { return "→ \(button.shortLabel) (default)" }
            return "Default"
        case .disabled: return "Unmapped"
        case .shift: return "Shift"
        case .button(let button): return "→ \(button.shortLabel)"
        case .key(let key): return "⌨ \(key.label)"
        }
    }

    // MARK: Inspector

    private func inspector(for control: RemappableControl) -> some View {
        let current = profile.assignment(for: control, shift: shiftLayer)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shiftLayer ? "While Shift is held" : "Remap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(control.label)
                    .font(.title3.weight(.semibold))
            }
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            if shiftLayer && current == .shift {
                Text("This is the Shift button")
                    .foregroundStyle(.secondary)
            } else {
                // A popover rather than a Menu, so holding a control on the
                // controller can open it.
                Button {
                    pickerOpen.toggle()
                } label: {
                    HStack {
                        Text(current.label)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                    .frame(minWidth: 180, alignment: .leading)
                }
                .glassButton()
                .fixedSize()
                .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                    AssignmentPicker(control: control, shiftLayer: shiftLayer, current: current) { value in
                        model.updateDraft { $0.setAssignment(value, for: control, shift: shiftLayer) }
                        pickerOpen = false
                    }
                }
            }
            Spacer()
            if current != .standard {
                Button("Reset") {
                    model.updateDraft { $0.setAssignment(.standard, for: control, shift: shiftLayer) }
                }
                .glassButton()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 18)
    }
}

/// What a control can do in one layer: the inspector's popover.
struct AssignmentPicker: View {
    let control: RemappableControl
    let shiftLayer: Bool
    let current: Assignment
    let choose: (Assignment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(control.label)
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            if control.isTrigger {
                row("Default (trigger)", .standard)
                Menu(keyMenuLabel) {
                    ForEach(KeyboardKey.all) { key in
                        Button(key.label) { choose(.key(key)) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            } else {
                row(defaultLabel, .standard)
                row("Unmapped", .disabled)
                if !shiftLayer {
                    row("Shift", .shift)
                }
                Divider().padding(.vertical, 4)
                ForEach(GamepadButton.allCases) { button in
                    row(button.label, .button(button))
                }
            }
        }
        .padding(10)
        .frame(width: 240)
    }

    private func row(_ title: String, _ value: Assignment) -> some View {
        Button {
            choose(value)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if value == current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.xboxGlow)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var keyMenuLabel: String {
        if case .key = current { return current.label }
        return "Keyboard key"
    }

    private var defaultLabel: String {
        if control.isPaddle, let button = control.standardOutput { return "Default (\(button.label))" }
        return "Default"
    }
}

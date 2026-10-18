import EliteKit
import SwiftUI
import UniformTypeIdentifiers

enum EditorTab: String, CaseIterable, Identifiable {
    case mapping, sticks, triggers, vibration, light
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mapping: "Mapping"
        case .sticks: "Thumbsticks"
        case .triggers: "Triggers"
        case .vibration: "Vibration"
        case .light: "Xbox button"
        }
    }
}

struct ProfileEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: EditorTab = .mapping
    @State private var previewID = UUID()
    /// Slot waiting for the user to confirm saving a profile without A or B.
    @State private var unmappedSaveSlot: Int?
    @State private var mappingSelection: RemappableControl? = .paddleUpperRight
    @State private var pickerOpen = false
    @State private var quickRemap = QuickRemapDetector()

    var body: some View {
        if let profile = model.draft {
            VStack(spacing: 0) {
                header(profile)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                if let warning = Self.unmappedWarning(profile) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassPanel(cornerRadius: 14, tint: .orange)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }
                GlassSegmentedPicker(options: EditorTab.allCases, selection: $tab) { $0.label }
                    .padding(.vertical, 12)
                Group {
                    switch tab {
                    case .mapping: MappingView(profile: profile, selected: $mappingSelection, pickerOpen: $pickerOpen)
                    case .sticks: ScrollView { SticksEditor(profile: profile).padding(20) }
                    case .triggers: ScrollView { TriggersEditor(profile: profile).padding(20) }
                    case .vibration: ScrollView { VibrationEditor(profile: profile).padding(20) }
                    case .light: ScrollView { LightEditor(profile: profile).padding(20) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(CanvasBackground())
            .navigationTitle(title(profile))
            .toolbar { toolbar(profile) }
            // While a profile is open, the Xbox button shows its light, saved
            // or not. Connecting or switching profiles on the controller
            // brings back the controller's own light, so show it again.
            .onChange(of: LightPreviewKey(light: profile.light, live: model.isConfiguring, slot: model.status.activeSlot), initial: true) { _, key in
                if key.live { model.showLightPreview(key.light, owner: previewID) }
            }
            .onDisappear { model.endLightPreview(owner: previewID) }
            .onChange(of: model.input) { _, input in detectQuickRemap(input) }
            // A held button sends no more reports, so look again when the hold is long enough.
            .task(id: quickRemap.deadline) {
                guard let deadline = quickRemap.deadline else { return }
                try? await Task.sleep(until: deadline, clock: .continuous)
                if !Task.isCancelled { detectQuickRemap(model.input) }
            }
            .confirmationDialog(
                Self.unmappedWarning(profile) ?? "",
                isPresented: Binding(get: { unmappedSaveSlot != nil }, set: { if !$0 { unmappedSaveSlot = nil } }),
                titleVisibility: .visible,
                presenting: unmappedSaveSlot
            ) { slot in
                Button("Save Anyway") { Task { await model.saveDraft(toSlot: slot) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Xbox menus and most games use A to select and B to go back. You can map them to any button or paddle on the Mapping tab.")
            }
        }
    }

    /// The Accessories app's warning when nothing on the normal layer gives A or B.
    static func unmappedWarning(_ profile: EliteProfile) -> String? {
        let buttons = profile.unmappedEssentialButtons.map(\.label)
        if buttons.isEmpty { return nil }
        return buttons.count == 1 ? "The \(buttons[0]) button is not mapped" : "The \(buttons.joined(separator: " and ")) buttons are not mapped"
    }

    private func detectQuickRemap(_ input: InputState) {
        guard let control = quickRemap.update(model.isConfiguring ? input : InputState(), at: .now) else { return }
        tab = .mapping
        mappingSelection = control
        pickerOpen = true
    }

    private func save(_ profile: EliteProfile, toSlot slot: Int) {
        if profile.unmappedEssentialButtons.isEmpty {
            Task { await model.saveDraft(toSlot: slot) }
        } else {
            unmappedSaveSlot = slot
        }
    }

    private struct LightPreviewKey: Equatable {
        let light: LightSettings
        let live: Bool
        let slot: Int?
    }

    private func header(_ profile: EliteProfile) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.xbox.gradient)
                Image(systemName: isSlot ? "gamecontroller.fill" : "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(profile))
                    .font(.title2.weight(.bold))
                HStack(spacing: 8) {
                    if case .slot(let slot) = model.draftSource {
                        ProfileLEDs(slot: slot, size: 6)
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(model.draftIsDirty && isSlot ? Color.orange : .secondary)
                }
            }
            Spacer()
            if let shift = profile.shiftControl {
                Label("Shift on \(shift.shortLabel)", systemImage: "shift.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .slot(let slot) = model.draftSource {
                Button {
                    model.slotPendingReset = slot
                } label: {
                    Label("Reset to Default", systemImage: "arrow.counterclockwise")
                }
                .glassButton()
                .disabled(!model.isConfiguring)
                .help("Restore every setting in profile \(slot) to the factory default")
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 22)
    }

    private var isSlot: Bool {
        if case .slot = model.draftSource { return true }
        return false
    }

    private func title(_ profile: EliteProfile) -> String {
        if case .slot(let slot) = model.draftSource {
            return model.libraryName(forSlot: slot).map { "Profile \(slot) · \($0)" } ?? "Profile \(slot)"
        }
        return profile.name
    }

    private var subtitle: String {
        switch model.draftSource {
        case .slot: model.draftIsDirty ? "Edited, not saved to the controller" : "Stored on the controller"
        case .library: "Saved on this Mac"
        case nil: ""
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ profile: EliteProfile) -> some ToolbarContent {
        if case .slot(let slot) = model.draftSource {
            ToolbarItemGroup {
                Button("Revert") { model.revertDraft() }
                    .disabled(!model.draftIsDirty)
                Menu {
                    Button("Add to Library") { model.addToLibrary(profile) }
                    Button("Reset Profile \(slot) to Default…", role: .destructive) { model.slotPendingReset = slot }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                Button {
                    save(profile, toSlot: slot)
                } label: {
                    Label("Save to Controller", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .glassButton(prominent: true)
                .tint(.xbox)
                .disabled(!model.draftIsDirty)
            }
        } else {
            ToolbarItemGroup {
                Button { export(profile) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Menu {
                    ForEach(1...3, id: \.self) { slot in
                        Button("Profile \(slot)") { save(profile, toSlot: slot) }
                    }
                } label: {
                    Label("Load onto Profile", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.status.present)
            }
        }
    }

    private func export(_ profile: EliteProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProfileFile.fileExtension) ?? .json]
        panel.nameFieldStringValue = profile.name + "." + ProfileFile.fileExtension
        if panel.runModal() == .OK, let url = panel.url { model.export(profile, to: url) }
    }
}

// MARK: Thumbsticks

struct SticksEditor: View {
    @Environment(AppModel.self) private var model
    let profile: EliteProfile

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            stickCard("Left thumbstick", stick: profile.leftStick, x: model.input.rawLeftStickX, y: model.input.rawLeftStickY) { change in
                model.updateDraft { change(&$0.leftStick) }
            }
            stickCard("Right thumbstick", stick: profile.rightStick, x: model.input.rawRightStickX, y: model.input.rawRightStickY) { change in
                model.updateDraft { change(&$0.rightStick) }
            }
        }
        .glassGroup()
    }

    private func stickCard(_ title: String, stick: StickSettings, x: Int16, y: Int16, update: @escaping ((inout StickSettings) -> Void) -> Void) -> some View {
        GlassCard(title: title, systemImage: "l.joystick.fill") {
            HStack(alignment: .center, spacing: 18) {
                StickPuck(x: x, y: y, deadZone: stick.deadZone, curve: stick.curve, invertY: stick.invertY, live: model.isConfiguring)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Invert Y axis", isOn: Binding(get: { stick.invertY }, set: { value in update { $0.invertY = value } }))
                        .toggleStyle(.switch)
                        .tint(.xbox)
                    Text(stick.preset?.label ?? "Custom curve")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.xboxGlow)
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Where the stick is")
                        } icon: {
                            Circle().stroke(.white.opacity(0.7), lineWidth: 2).frame(width: 12, height: 12)
                        }
                        Label {
                            Text("What the game gets")
                        } icon: {
                            Circle().fill(Color.xboxGlow).frame(width: 10, height: 10)
                        }
                        Label {
                            Text("Dead zone")
                        } icon: {
                            Circle().stroke(Color.xboxGlow, lineWidth: 2).frame(width: 12, height: 12)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Dead zone")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(stick.deadZone == 0 ? "Off" : "\(stick.deadZonePercent)%")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.xboxGlow)
                }
                Slider(value: Binding(get: { Double(stick.deadZone) }, set: { value in update { $0.deadZone = UInt8(value.rounded()) } }),
                       in: 0...Double(StickSettings.maxDeadZone))
                    .tint(.xbox)
                Text("How far the stick moves before it responds. Raise it if the stick drifts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DriftCheck(x: x, y: y, deadZone: stick.deadZone, live: model.isConfiguring) { zone in update { $0.deadZone = zone } }
            }
            FlowPresets(selected: stick.preset) { preset in update { $0.apply(preset) } }
            CurveEditor(curve: stick.curve, deadZone: stick.deadZone, liveInput: liveDeflection(x: x, y: y)) { curve in update { $0.curve = curve } }
                .frame(height: 240)
            Text(previewNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            StickPlayground(x: x, y: y, curve: stick.curve, invertY: stick.invertY, live: model.isConfiguring)
        }
    }

    /// The live dots use the physical stick position (the 0x0C report), so
    /// the preview is right whichever profile is active.
    private var previewNote: String {
        "Across: how far you push the stick. Up: what the game gets. Drag the points to shape the response."
    }

    private func liveDeflection(x: Int16, y: Int16) -> Double? {
        guard model.isConfiguring else { return nil }
        return min(1, (Double(x) * Double(x) + Double(y) * Double(y)).squareRoot() / 32767)
    }
}

/// Watches where the stick settles when it's let go. A stick that rests away
/// from the centre is drifting; a dead zone just larger than the resting
/// offset hides it.
struct DriftCheck: View {
    let x: Int16
    let y: Int16
    let deadZone: UInt8
    let live: Bool
    let setDeadZone: (UInt8) -> Void

    /// Resting offset, 0-1, once the stick has been still for a moment.
    @State private var rest: Double?

    /// Anything past this is a push, not a stick at rest.
    private static let restLimit = 0.3
    private static let margin = 0.03

    var body: some View {
        Group {
            if live, let rest, rest >= 0.02 {
                let percent = Int((rest * 100).rounded())
                let suggested = UInt8(min(Double(StickSettings.maxDeadZone), ((rest + Self.margin) * 255).rounded(.up)))
                if Double(deadZone) / 255 > rest {
                    Label("At rest this stick reads \(percent)%, inside the dead zone, so the drift is hidden.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.xboxGlow)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Label("At rest this stick reads \(percent)%. That's drift: games without their own dead zone see slow movement.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button("Set to \(Int((Double(suggested) / 255 * 100).rounded()))%") { setDeadZone(suggested) }
                            .glassButton()
                            .controlSize(.small)
                    }
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        // The controller only reports the sticks when they move, so no new
        // report for a second and a half means the stick has settled.
        .task(id: live ? Int(x) << 16 | Int(UInt16(bitPattern: y)) : -1) {
            guard live else { rest = nil; return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let magnitude = min(1, (Double(x) * Double(x) + Double(y) * Double(y)).squareRoot() / 32767)
            if magnitude < Self.restLimit { rest = magnitude }
        }
    }
}

/// Row of preset buttons.
struct FlowPresets: View {
    let selected: CurvePreset?
    let choose: (CurvePreset) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CurvePreset.allCases) { preset in
                Button(preset.label) { choose(preset) }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected == preset ? Color.white : .primary)
                    .background(selected == preset ? AnyShapeStyle(Color.xbox.gradient) : AnyShapeStyle(Color.white.opacity(0.06)), in: Capsule())
                    .buttonStyle(.plain)
            }
        }
    }
}

/// Live stick position with the dead zone and curve applied. The hollow ring
/// is where the stick is; the green dot is what a game would get with these
/// settings. Nothing inside the green circle registers.
struct StickPuck: View {
    let x: Int16
    let y: Int16
    let deadZone: UInt8
    let curve: StickCurve
    let invertY: Bool
    let live: Bool

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            let travel = radius - 10
            let raw = CGPoint(x: Double(x) / 32767, y: -Double(y) / 32767)
            let shaped = PlaygroundWorld.shape(CGVector(dx: raw.x, dy: -raw.y), curve: curve, invertY: invertY)
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                Circle().strokeBorder(.white.opacity(0.12))
                Path { path in
                    path.move(to: CGPoint(x: radius, y: 8))
                    path.addLine(to: CGPoint(x: radius, y: radius * 2 - 8))
                    path.move(to: CGPoint(x: 8, y: radius))
                    path.addLine(to: CGPoint(x: radius * 2 - 8, y: radius))
                }
                .stroke(.white.opacity(0.08))
                if deadZone > 0 {
                    let zone = travel * CGFloat(deadZone) / 255 * 2
                    Circle()
                        .fill(Color.xbox.opacity(0.18))
                        .overlay(Circle().stroke(Color.xboxGlow, lineWidth: 2))
                        .shadow(color: .xboxGlow.opacity(0.5), radius: 4)
                        .frame(width: zone, height: zone)
                        .animation(.easeOut(duration: 0.15), value: deadZone)
                }
                if live {
                    Circle()
                        .stroke(.white.opacity(0.7), lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                        .offset(x: raw.x * travel, y: raw.y * travel)
                    Circle()
                        .fill(Color.xboxGlow)
                        .shadow(color: .xboxGlow, radius: 4)
                        .frame(width: 8, height: 8)
                        .offset(x: shaped.dx * travel, y: -shaped.dy * travel)
                }
            }
        }
    }
}

/// Graph of a response curve with three draggable control points.
struct CurveEditor: View {
    let curve: StickCurve
    let deadZone: UInt8
    let liveInput: Double?
    let onChange: (StickCurve) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35))
                Path { path in
                    for step in 1..<4 {
                        let offset = CGFloat(step) / 4
                        path.move(to: CGPoint(x: size.width * offset, y: 0))
                        path.addLine(to: CGPoint(x: size.width * offset, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * offset))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * offset))
                    }
                }
                .stroke(Color.white.opacity(0.06))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                curvePath(in: size)
                    .fill(LinearGradient(colors: [Color.xbox.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                curveLine(in: size)
                    .stroke(Color.xboxGlow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: .xboxGlow.opacity(0.6), radius: 6)
                if deadZone > 0 {
                    Rectangle()
                        .fill(Color.xbox.opacity(0.14))
                        .frame(width: size.width * CGFloat(deadZone) / 255)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                if let liveInput {
                    let output = curve.output(for: liveInput)
                    let point = CGPoint(x: size.width * liveInput, y: size.height * (1 - output))
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: size.height))
                        path.addLine(to: point)
                        path.addLine(to: CGPoint(x: 0, y: point.y))
                    }
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle()
                        .fill(Color.xboxGlow)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .xboxGlow, radius: 6)
                        .frame(width: 12, height: 12)
                        .position(point)
                    Text("Stick \(Int((liveInput * 100).rounded()))%  →  Game \(Int((output * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                ForEach(curve.points.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.xbox, lineWidth: 3))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .frame(width: 18, height: 18)
                        .position(position(curve.points[index], in: size))
                        .gesture(DragGesture().onChanged { value in drag(index, to: value.location, in: size) })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func curveLine(in size: CGSize) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            for point in curve.points { path.addLine(to: position(point, in: size)) }
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
    }

    private func curvePath(in size: CGSize) -> Path {
        var path = curveLine(in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private func position(_ point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * CGFloat(point.x) / 255, y: size.height * (1 - CGFloat(point.y) / 255))
    }

    private func drag(_ index: Int, to location: CGPoint, in size: CGSize) {
        var points = curve.points
        let lower = index > 0 ? Int(points[index - 1].x) + 1 : 1
        let upper = index < points.count - 1 ? Int(points[index + 1].x) - 1 : 254
        // Points read from a controller or file may not be in order; don't move one that has no room.
        guard lower <= upper, (0...255).contains(lower), (0...255).contains(upper) else { return }
        let x = Int((location.x / size.width * 255).rounded())
        let y = Int(((1 - location.y / size.height) * 255).rounded())
        points[index] = CurvePoint(x: UInt8(min(max(x, lower), upper)), y: UInt8(min(max(y, 0), 255)))
        onChange(StickCurve(points: points))
    }
}

// MARK: Triggers

/// Trigger range, as in the Accessories app: how far the trigger is pulled
/// before it reports a full press. The tab also shows the hair trigger
/// locks, which are physical switches, and the live pull.
struct TriggersEditor: View {
    @Environment(AppModel.self) private var model
    let profile: EliteProfile
    @State private var link: TriggerRangeLink

    init(profile: EliteProfile) {
        self.profile = profile
        _link = State(initialValue: TriggerRangeLink(profile))
    }

    var body: some View {
        VStack(spacing: 18) {
            Toggle("Same range for both triggers", isOn: Binding(get: { link.isOn }, set: { on in
                if on { model.updateDraft { link.turnOn(in: &$0) } } else { link.turnOff() }
            }))
            .toggleStyle(.switch)
            .tint(.xbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 18) {
                triggerCard("Left trigger", short: "LT", settings: profile.leftTrigger, lock: model.input.leftTriggerStop, live: model.input.rawLeftTrigger) { value in
                    model.updateDraft { link.setRange(value, of: \.leftTrigger, in: &$0) }
                }
                triggerCard("Right trigger", short: "RT", settings: profile.rightTrigger, lock: model.input.rightTriggerStop, live: model.input.rawRightTrigger) { value in
                    model.updateDraft { link.setRange(value, of: \.rightTrigger, in: &$0) }
                }
            }
            .glassGroup()
            Text("Range sets where a pull counts as a full press. At 100% the whole travel is used; lower values reach full sooner, and 0% makes the trigger on or off. The hair trigger locks on the back shorten the travel itself, and the controller scales the shorter travel so a full pull still reads as 100%.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 640)
        }
        .onChange(of: model.draftRevision) { link = TriggerRangeLink(profile) }
    }

    /// The switch positions come with the 0x0C report, on any profile.
    private var lockReadable: Bool { model.isConfiguring && model.input.leftTriggerStop != nil }

    private var lockHint: String {
        model.isConfiguring ? "Press any button on the controller so it reports the switch." : "Connect the controller to read the switch."
    }

    private func triggerCard(_ title: String, short: String, settings: TriggerSettings, lock: TriggerStop?, live: UInt16, update: @escaping (UInt8) -> Void) -> some View {
        let pull = Double(min(live, 1023)) / 1023
        return GlassCard(title: title, systemImage: "button.angledtop.vertical.left.fill") {
            HStack(alignment: .bottom, spacing: 24) {
                TriggerGauge(range: settings.range, live: model.isConfiguring ? live : nil, label: short)
                    .frame(width: 70, height: 220)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Range")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(settings.range == 0 ? "On/off" : "\(settings.rangePercent)%")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Slider(value: Binding(get: { Double(settings.rangePercent) }, set: { update(TriggerSettings.range(percent: Int($0.rounded()))) }),
                           in: 0...100)
                        .tint(.xbox)
                    Text(settings.range == 0 ? "Any pull is a full press." : "Full press at \(settings.rangePercent)% of the pull.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isConfiguring {
                        Text("Pulled \(Int((pull * 100).rounded()))%  →  game gets \(Int((settings.output(forPull: pull) * 100).rounded()))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    Text("Hair trigger lock")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 6)
                    TriggerLockIndicator(position: lockReadable ? lock : nil)
                    if !lockReadable {
                        Text(lockHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Read-only picture of the three-position switch.
struct TriggerLockIndicator: View {
    let position: TriggerStop?

    var body: some View {
        HStack(spacing: 6) {
            ForEach([TriggerStop.full, .mid, .short], id: \.self) { stop in
                let on = stop == position
                Text(stop.label)
                    .font(.callout.weight(on ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(on ? Color.white : .secondary)
                    .background(on ? AnyShapeStyle(Color.xbox.gradient) : AnyShapeStyle(Color.white.opacity(0.04)), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.08)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hair trigger lock")
        .accessibilityValue(position?.label ?? "Unknown")
    }
}

/// Vertical bar showing the live pull and the point where it counts as a
/// full press.
struct TriggerGauge: View {
    let range: UInt8
    let live: UInt16?
    let label: String

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height - 22
            let rangeHeight = height * CGFloat(range) / 255
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35))
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12))
                    // Past the range line, the trigger already reads 100%.
                    Rectangle()
                        .fill(Color.xbox.opacity(0.25))
                        .frame(height: height - rangeHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                    if let live {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.xboxGlow.gradient)
                            .frame(height: height * CGFloat(min(live, 1023)) / 1023)
                            .shadow(color: .xboxGlow.opacity(0.6), radius: 6)
                    }
                    Rectangle()
                        .fill(Color.white)
                        .frame(height: 2)
                        .offset(y: -rangeHeight)
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Vibration

struct VibrationEditor: View {
    @Environment(AppModel.self) private var model
    let profile: EliteProfile

    var body: some View {
        VStack(spacing: 18) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                motor("Left grip", icon: "hand.raised.fill", value: profile.vibration.leftGrip, test: { await model.rumble(leftGrip: $0) }) { v in model.updateDraft { $0.vibration.leftGrip = v } }
                motor("Right grip", icon: "hand.raised.fill", value: profile.vibration.rightGrip, test: { await model.rumble(rightGrip: $0) }) { v in model.updateDraft { $0.vibration.rightGrip = v } }
                motor("Left trigger", icon: "button.angledtop.vertical.left.fill", value: profile.vibration.leftTrigger, test: { await model.rumble(leftTrigger: $0) }) { v in model.updateDraft { $0.vibration.leftTrigger = v } }
                motor("Right trigger", icon: "button.angledtop.vertical.right.fill", value: profile.vibration.rightTrigger, test: { await model.rumble(rightTrigger: $0) }) { v in model.updateDraft { $0.vibration.rightTrigger = v } }
            }
            .glassGroup()
            Text("Scales each motor while this profile is active on the controller. 0% turns a motor off. Test plays the motor at the chosen strength.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func motor(_ title: String, icon: String, value: UInt8, test: @escaping (UInt8) async -> Void, update: @escaping (UInt8) -> Void) -> some View {
        GlassCard(title: title, systemImage: icon) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(value)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Image(systemName: "waveform", variableValue: Double(value) / 100)
                    .font(.title)
                    .foregroundStyle(Color.xboxGlow)
            }
            Slider(value: Binding(get: { Double(value) }, set: { update(UInt8($0.rounded())) }), in: 0...100)
                .tint(.xbox)
            Button {
                Task { await test(max(value, 1)) }
            } label: {
                Label("Test", systemImage: "play.fill")
            }
            .glassButton()
            .disabled(!model.isConfiguring || value == 0)
        }
    }
}

// MARK: Xbox button light

struct LightEditor: View {
    @Environment(AppModel.self) private var model
    let profile: EliteProfile

    static let swatches: [(String, LightColor?)] = [
        ("White", nil),
        ("Green", LightColor(red: 0x10, green: 0xE0, blue: 0x10)),
        ("Cyan", LightColor(red: 0x00, green: 0xD0, blue: 0xFF)),
        ("Blue", LightColor(red: 0x10, green: 0x40, blue: 0xFF)),
        ("Purple", LightColor(red: 0x90, green: 0x30, blue: 0xFF)),
        ("Pink", LightColor(red: 0xFF, green: 0x30, blue: 0xA0)),
        ("Red", LightColor(red: 0xFF, green: 0x10, blue: 0x10)),
        ("Orange", LightColor(red: 0xFF, green: 0x6D, blue: 0x20)),
        ("Yellow", LightColor(red: 0xFF, green: 0xD0, blue: 0x00)),
    ]

    var body: some View {
        GlassCard(title: "Xbox button light", systemImage: "lightbulb.fill") {
            HStack(alignment: .top, spacing: 36) {
                XboxButtonGlow(brightness: Double(profile.light.brightness), color: profile.light.color)
                    .frame(width: 190, height: 190)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Colour").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(Self.swatches, id: \.0) { name, color in
                                swatch(name: name, color: color)
                            }
                            ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                                .labelsHidden()
                                .help("Custom colour")
                            HexColorField(color: profile.light.color) { color in model.updateDraft { $0.light.color = color } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Brightness").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(profile.light.brightness)%")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        Slider(value: Binding(get: { Double(profile.light.brightness) }, set: { value in
                            let brightness = UInt8(value.rounded())
                            model.updateDraft { $0.light.brightness = brightness }
                        }), in: 0...100)
                        .tint(.xbox)
                    }
                    Text(previewNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 820)
    }

    private var previewNote: String {
        if !model.isConfiguring { return "Connect the controller over USB to see this light on it." }
        return "While this profile is open, the controller's Xbox button shows its light, including changes you haven't saved. It goes back when you leave the profile."
    }

    private func swatch(name: String, color: LightColor?) -> some View {
        let selected = profile.light.color == color
        return Button {
            model.updateDraft { $0.light.color = color }
        } label: {
            Circle()
                .fill(color.map(Color.init(rgb:)) ?? .white)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.2), lineWidth: selected ? 3 : 1))
                .shadow(color: (color.map(Color.init(rgb:)) ?? .white).opacity(selected ? 0.8 : 0), radius: 6)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var customColor: Binding<Color> {
        Binding(get: {
            profile.light.color.map(Color.init(rgb:)) ?? .white
        }, set: { newValue in
            guard let rgb = LightColor(newValue) else { return }
            model.updateDraft { $0.light.color = rgb }
        })
    }
}

/// `#RRGGBB` entry for a light colour. A complete code applies as it's
/// typed, like picking a swatch; anything else is outlined in red.
struct HexColorField: View {
    /// nil is the default white.
    let color: LightColor?
    let apply: (LightColor) -> Void
    @State private var text = ""

    private var shown: LightColor { color ?? LightColor(red: 255, green: 255, blue: 255) }

    var body: some View {
        TextField("#RRGGBB", text: $text)
            .textFieldStyle(.plain)
            .font(.callout.monospaced())
            .frame(width: 76)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LightColor(hex: text) == nil ? Color.red.opacity(0.85) : .white.opacity(0.12)))
            .help("Colour as #RRGGBB")
            // Comparing colours rather than text leaves a code that's being
            // typed alone, and typing white keeps the default white.
            .onChange(of: shown, initial: true) { _, shown in
                if LightColor(hex: text) != shown { text = shown.hex }
            }
            .onChange(of: text) { _, text in
                if let parsed = LightColor(hex: text), parsed != shown { apply(parsed) }
            }
            .onSubmit {
                if let parsed = LightColor(hex: text) { text = parsed.hex }
            }
    }
}

extension Color {
    init(rgb: LightColor) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

extension LightColor {
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        self.init(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
    }
}

/// The Xbox button as on the Elite 2: a glossy black button whose logo lights up.
struct XboxButtonGlow: View {
    let brightness: Double
    var color: LightColor?

    var body: some View {
        let level = max(0.06, min(brightness, 100) / 100)
        let light = color.map(Color.init(rgb:)) ?? .white
        GeometryReader { proxy in
            // Drawn for 190 points; everything scales so smaller copies look the same.
            let scale = min(proxy.size.width, proxy.size.height) / 190
            ZStack {
                Circle()
                    .fill(light.opacity(0.55 * level))
                    .blur(radius: 34 * level * scale)
                    .padding(10 * scale)
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.04)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2 * scale, endRadius: 110 * scale))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: max(1, 1.5 * scale)))
                    .padding(18 * scale)
                    .shadow(color: .black.opacity(0.6), radius: 8 * scale, y: 4 * scale)
                XboxLogo()
                    .fill(light.opacity(0.35 + 0.65 * level))
                    .shadow(color: light.opacity(level), radius: 14 * level * scale)
                    .padding(48 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeOut(duration: 0.2), value: brightness)
        .animation(.easeOut(duration: 0.2), value: color)
    }
}

/// The Xbox sphere logo, from the public-domain "Xbox logo 2012 cropped.svg"
/// on Wikimedia Commons, normalised to a unit square.
struct XboxLogo: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * size, y: origin.y + y * size) }
        var path = Path()
        path.move(to: p(0.38910, 0.97630))
        path.addCurve(to: p(0.14382, 0.81555), control1: p(0.27314, 0.94605), control2: p(0.14382, 0.86130))
        path.addCurve(to: p(0.41894, 0.45620), control1: p(0.14382, 0.75430), control2: p(0.27507, 0.58286))
        path.addLine(to: p(0.49987, 0.38494))
        path.addLine(to: p(0.53617, 0.41074))
        path.addCurve(to: p(0.81645, 0.70698), control1: p(0.59319, 0.45127), control2: p(0.77564, 0.64410))
        path.addCurve(to: p(0.79187, 0.89628), control1: p(0.88268, 0.80900), control2: p(0.87973, 0.83175))
        path.addCurve(to: p(0.38910, 0.97630), control1: p(0.68592, 0.97410), control2: p(0.51266, 1.00852))
        path.closeSubpath()
        path.move(to: p(0.08889, 0.76555))
        path.addCurve(to: p(0.03407, 0.34447), control1: p(0.01327, 0.65223), control2: p(-0.01102, 0.46562))
        path.addCurve(to: p(0.16370, 0.14328), control1: p(0.06200, 0.26944), control2: p(0.12783, 0.16726))
        path.addCurve(to: p(0.23020, 0.14573), control1: p(0.18960, 0.12596), control2: p(0.19457, 0.12614))
        path.addCurve(to: p(0.32846, 0.22149), control1: p(0.25139, 0.15737), control2: p(0.29560, 0.19146))
        path.addLine(to: p(0.38820, 0.27609))
        path.addLine(to: p(0.32422, 0.35694))
        path.addCurve(to: p(0.11582, 0.78373), control1: p(0.19567, 0.51939), control2: p(0.09666, 0.72215))
        path.addCurve(to: p(0.08889, 0.76555), control1: p(0.12548, 0.81481), control2: p(0.11870, 0.81022))
        path.closeSubpath()
        path.move(to: p(0.88893, 0.76203))
        path.addCurve(to: p(0.68337, 0.35705), control1: p(0.88764, 0.66725), control2: p(0.81496, 0.52405))
        path.addLine(to: p(0.61976, 0.27632))
        path.addLine(to: p(0.67679, 0.22291))
        path.addCurve(to: p(0.77584, 0.14655), control1: p(0.70816, 0.19354), control2: p(0.75273, 0.15918))
        path.addLine(to: p(0.81786, 0.12358))
        path.addLine(to: p(0.86441, 0.16987))
        path.addCurve(to: p(0.94746, 0.29167), control1: p(0.89001, 0.19533), control2: p(0.92738, 0.25014))
        path.addCurve(to: p(0.98791, 0.47446), control1: p(0.97893, 0.35674), control2: p(0.98452, 0.38202))
        path.addCurve(to: p(0.92271, 0.75663), control1: p(0.99245, 0.59845), control2: p(0.97395, 0.67850))
        path.addLine(to: p(0.88954, 0.80720))
        path.addLine(to: p(0.88893, 0.76203))
        path.closeSubpath()
        path.move(to: p(0.44694, 0.14565))
        path.addCurve(to: p(0.33010, 0.09845), control1: p(0.42191, 0.13052), control2: p(0.36933, 0.10928))
        path.addCurve(to: p(0.26390, 0.07027), control1: p(0.29086, 0.08761), control2: p(0.26107, 0.07493))
        path.addCurve(to: p(0.34971, 0.03533), control1: p(0.26672, 0.06561), control2: p(0.30533, 0.04989))
        path.addCurve(to: p(0.70574, 0.05707), control1: p(0.46585, -0.00278), control2: p(0.60332, 0.00562))
        path.addCurve(to: p(0.75433, 0.08756), control1: p(0.74561, 0.07710), control2: p(0.76747, 0.09082))
        path.addCurve(to: p(0.54647, 0.15182), control1: p(0.72506, 0.08031), control2: p(0.59753, 0.11973))
        path.addCurve(to: p(0.44694, 0.14565), control1: p(0.50166, 0.17998), control2: p(0.50402, 0.18013))
        path.closeSubpath()
        return path
    }
}

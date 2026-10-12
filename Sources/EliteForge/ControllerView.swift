import EliteKit
import SwiftUI

/// Home screen: the controller, live, with its details, renaming and a vibration test.
struct ControllerView: View {
    @Environment(AppModel.self) private var model
    @State private var editedName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                infoTiles
                if model.isConfiguring {
                    HStack(alignment: .top, spacing: 18) {
                        renameCard
                        vibrationCard
                    }
                    .glassGroup()
                    DefaultLightCard()
                }
            }
            .padding(20)
        }
        .background(CanvasBackground(glow: model.isConfiguring ? 1.2 : 0.6))
        .navigationTitle(displayName)
        .onAppear { editedName = model.controllerName }
        .onChange(of: model.controllerName) { _, name in editedName = name }
    }

    private var displayName: String { model.controllerName.isEmpty ? "Elite Series 2" : model.controllerName }

    private var hero: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(model.isConfiguring ? Color.xboxGlow : .secondary)
                }
                Spacer()
                if model.isConfiguring {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassCapsule(tint: .xbox)
                }
            }
            EliteControllerArt(input: model.input,
                               brightness: artBrightness,
                               lightColor: artLightColor)
                .frame(maxHeight: 420)
                .opacity(model.status.present ? 1 : 0.45)
                .padding(.vertical, 6)
            if model.isConfiguring {
                InputReadout(state: model.input)
            } else {
                Text(!model.status.present
                     ? "Connect the controller with a USB cable to configure it."
                     : (model.releasedByUser ? "Released for games. Reconnect from the sidebar or the Controller menu." : "Connecting…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .glassPanel(cornerRadius: 28)
    }

    /// On Default, the colour EliteForge sets; otherwise the active profile's.
    private var onDefaultWithLight: Bool { model.isConfiguring && model.status.activeSlot == 0 && model.defaultLight != nil }
    private var artBrightness: Double {
        onDefaultWithLight ? Double(model.defaultLight?.brightness ?? 100) : Double(model.slots[model.status.activeSlot ?? 0]?.light.brightness ?? 100)
    }
    private var artLightColor: LightColor? {
        onDefaultWithLight ? model.defaultLight?.color : model.slots[model.status.activeSlot ?? 0]?.light.color
    }

    private var statusLine: String {
        if !model.status.present { return "Not connected over USB" }
        if model.isConfiguring { return "Connected over USB · games can't use it while EliteForge is open" }
        return model.releasedByUser ? "Released for games" : "Connecting…"
    }

    private var infoTiles: some View {
        HStack(spacing: 14) {
            tile("Firmware", value: model.deviceInfo?.firmware ?? (model.status.present ? "Replug to read" : "—"), icon: "cpu")
            tile("Battery", value: model.status.battery?.label ?? "—", icon: batteryIcon)
            tile("Active profile", value: activeProfile, icon: "circle.grid.3x3.fill")
            tile("Serial", value: model.status.serialNumber.map(serialText) ?? "—", icon: "number")
        }
        .glassGroup()
    }

    private var activeProfile: String {
        guard let slot = model.status.activeSlot else { return model.isConfiguring ? "Press any button" : "—" }
        return slot == 0 ? "Profile 0 (Default)" : "Profile \(slot)"
    }

    private var batteryIcon: String {
        switch model.status.battery?.level {
        case .full: "battery.100percent"
        case .medium: "battery.50percent"
        case .low: "battery.25percent"
        case .critical: "battery.0percent"
        case nil: "battery.100percent"
        }
    }

    private func tile(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.xboxGlow)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 16)
    }

    private var renameCard: some View {
        GlassCard(title: "Name", systemImage: "pencil") {
            HStack {
                TextField("Controller name", text: $editedName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(rename)
                let canRename = !editedName.isEmpty && editedName != model.controllerName
                Button(action: rename) {
                    Text("Rename")
                        .foregroundStyle(.white.opacity(canRename ? 1 : 0.45))
                        .padding(.horizontal, 4)
                }
                .glassButton(prominent: true)
                .tint(canRename ? .xbox : .gray)
                .disabled(!canRename)
            }
            Text("Up to 15 characters. Bluetooth devices see this name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var vibrationCard: some View {
        GlassCard(title: "Vibration test", systemImage: "waveform") {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button("Left trigger") { Task { await model.rumble(leftTrigger: 60) } }
                    Button("Right trigger") { Task { await model.rumble(rightTrigger: 60) } }
                }
                GridRow {
                    Button("Left grip") { Task { await model.rumble(leftGrip: 60) } }
                    Button("Right grip") { Task { await model.rumble(rightGrip: 60) } }
                }
            }
            .glassButton()
        }
    }

    private func rename() {
        let name = String(editedName.prefix(15))
        guard !name.isEmpty, name != model.controllerName else { return }
        Task { await model.renameController(name) }
    }

    /// The USB serial is reported as hex-encoded ASCII.
    private func serialText(_ serial: String) -> String {
        guard let bytes = [UInt8](hexString: serial), bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return serial }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Numbers under the live controller: triggers, sticks and buttons held.
struct InputReadout: View {
    let state: InputState

    var body: some View {
        HStack(spacing: 18) {
            value("LT", "\(Int(Double(state.leftTrigger) / 10.23))%")
            value("RT", "\(Int(Double(state.rightTrigger) / 10.23))%")
            value("LS", "\(percent(state.leftStickX)), \(percent(state.leftStickY))")
            value("RS", "\(percent(state.rightStickX)), \(percent(state.rightStickY))")
            Spacer()
            Text(InputButton.allCases.filter { state.buttons.contains($0) }.map(\.shortLabel).joined(separator: " "))
                .font(.callout.weight(.semibold).monospaced())
                .foregroundStyle(Color.xboxGlow)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCapsule()
    }

    private func value(_ label: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(text)
        }
    }

    private func percent(_ value: Int16) -> Int { Int(Double(value) / 327.67) }
}

/// Colour for the Xbox button while the controller is on its Default profile.
struct DefaultLightCard: View {
    @Environment(AppModel.self) private var model

    private var light: LightSettings { model.defaultLight ?? LightSettings(color: LightEditor.swatches[1].1) }

    var body: some View {
        GlassCard(title: "Default profile light", systemImage: "lightbulb.fill") {
            HStack(alignment: .center, spacing: 24) {
                XboxButtonGlow(brightness: model.defaultLight == nil ? 100 : Double(light.brightness),
                               color: model.defaultLight == nil ? nil : light.color)
                    .frame(width: 96, height: 96)
                    .opacity(model.defaultLight == nil ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Set a colour while the controller is on its Default profile", isOn: Binding(
                        get: { model.defaultLight != nil },
                        set: { model.defaultLight = $0 ? light : nil }))
                        .toggleStyle(.switch)
                        .tint(.xbox)
                    if model.defaultLight != nil {
                        HStack(spacing: 10) {
                            ForEach(LightEditor.swatches, id: \.0) { name, color in
                                swatch(name: name, color: color)
                            }
                            ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                                .labelsHidden()
                                .help("Custom colour")
                        }
                        HStack {
                            Text("Brightness").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Slider(value: Binding(get: { Double(light.brightness) }, set: { value in
                                var updated = light
                                updated.brightness = UInt8(value.rounded())
                                model.defaultLight = updated
                            }), in: 0...100)
                            .tint(.xbox)
                            Text("\(light.brightness)%")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Text("The Default profile can't store a colour. While EliteForge is connected over USB, it shows this one whenever no profile light is on. Released or unplugged, the button goes back to white.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func swatch(name: String, color: LightColor?) -> some View {
        let selected = light.color == color
        return Button {
            var updated = light
            updated.color = color
            model.defaultLight = updated
        } label: {
            Circle()
                .fill(color.map(Color.init(rgb:)) ?? .white)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.2), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var customColor: Binding<Color> {
        Binding(get: { light.color.map(Color.init(rgb:)) ?? .white }, set: { newValue in
            guard let rgb = LightColor(newValue) else { return }
            var updated = light
            updated.color = rgb
            model.defaultLight = updated
        })
    }
}

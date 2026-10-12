import EliteKit
import SwiftUI

/// EliteKit.RGBColor; the bare name clashes with QuickDraw's RGBColor in AppKit.
typealias LightColor = EliteKit.RGBColor

extension Color {
    /// Xbox brand green and a brighter variant for glows.
    static let xbox = Color(red: 0.063, green: 0.486, blue: 0.063)
    static let xboxGlow = Color(red: 0.36, green: 0.85, blue: 0.24)
    /// The control selected for editing. Selection draws as an outline and a
    /// press as a fill, so both use the same green.
    static let selection = Color.xboxGlow
    static let canvasTop = Color(red: 0.09, green: 0.10, blue: 0.11)
    static let canvasBottom = Color(red: 0.02, green: 0.02, blue: 0.03)
}

/// Dark backdrop with a soft green glow, like the Accessories app.
struct CanvasBackground: View {
    var glow: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [.canvasTop, .canvasBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.xbox.opacity(0.28 * glow), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 20, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// Liquid Glass is used on macOS 26 and later unless this is off. Offscreen
/// snapshots turn it off because ImageRenderer can't draw glass.
enum GlassSupport {
    nonisolated(unsafe) static var enabled = true

    static var available: Bool {
        if #available(macOS 26.0, *) { return enabled }
        return false
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later, a material elsewhere.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), GlassSupport.enabled {
            self.glassEffect(glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(tint.map { $0.opacity(0.25) } ?? .clear, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *), GlassSupport.enabled {
            self.glassEffect(glass(tint: tint, interactive: interactive), in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .background(tint.map { $0.opacity(0.3) } ?? .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
    }

    /// Groups glass shapes so they blend into each other on macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *), GlassSupport.enabled {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *), GlassSupport.enabled {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

@available(macOS 26.0, *)
private func glass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint.opacity(0.55)) }
    if interactive { glass = glass.interactive() }
    return glass
}

/// A titled glass card used across the editor.
struct GlassCard<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.xboxGlow)
                }
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

/// A capsule segmented control drawn with glass, for the editor's sections.
struct GlassSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.xbox.gradient)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassCapsule()
    }
}

/// The three profile LEDs on the controller.
struct ProfileLEDs: View {
    let slot: Int?
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(1...3, id: \.self) { index in
                Circle()
                    .fill(slot.map { index <= $0 } ?? false ? Color.white : Color.white.opacity(0.15))
                    .shadow(color: slot.map { index <= $0 } ?? false ? .white.opacity(0.8) : .clear, radius: size * 0.6)
                    .frame(width: size, height: size)
            }
        }
    }
}

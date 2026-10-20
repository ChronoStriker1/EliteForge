import SwiftUI

/// A slider with two handles over a trigger's travel (0-255): where it
/// starts to count and where it reads full. The handles don't cross;
/// `TriggerSettings` keeps them a step apart.
struct RangeSlider: View {
    let lower: UInt8
    let upper: UInt8
    let setLower: (UInt8) -> Void
    let setUpper: (UInt8) -> Void

    private static let knob: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let track = proxy.size.width - Self.knob
            let center = proxy.size.height / 2
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: track, height: 6)
                    .position(x: proxy.size.width / 2, y: center)
                Capsule()
                    .fill(Color.xbox.gradient)
                    .frame(width: max(0, x(upper, track) - x(lower, track)), height: 6)
                    .position(x: (x(lower, track) + x(upper, track)) / 2, y: center)
                handle("Dead zone", value: lower, set: setLower, track: track, y: center)
                handle("Full press", value: upper, set: setUpper, track: track, y: center)
            }
            .coordinateSpace(name: "range")
        }
        .frame(height: 26)
    }

    private func x(_ value: UInt8, _ track: CGFloat) -> CGFloat { Self.knob / 2 + track * CGFloat(value) / 255 }

    private func handle(_ label: String, value: UInt8, set: @escaping (UInt8) -> Void, track: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.xbox, lineWidth: 3))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .frame(width: Self.knob, height: Self.knob)
            .position(x: x(value, track), y: y)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range")).onChanged { drag in
                set(UInt8(min(max(((drag.location.x - Self.knob / 2) / track * 255).rounded(), 0), 255)))
            })
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int((Double(value) / 255 * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 3 : -3
                set(UInt8(min(max(Int(value) + step, 0), 255)))
            }
    }
}

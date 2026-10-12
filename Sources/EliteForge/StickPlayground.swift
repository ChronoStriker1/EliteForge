import EliteKit
import SwiftUI

/// A character walking around a small floor, steered by one stick. The solid
/// character moves with the dead zone and curve applied, the faint one with
/// the raw stick, so the gap between them shows what the settings do.
struct StickPlayground: View {
    let x: Int16
    let y: Int16
    let curve: StickCurve
    let invertY: Bool
    let live: Bool

    @State private var world = PlaygroundWorld()
    @State private var demoStart: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Try it")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    world.recenter()
                    demoStart = .now
                    Task {
                        try? await Task.sleep(for: .seconds(PlaygroundDemo.duration))
                        demoStart = nil
                    }
                } label: {
                    Label("Demo", systemImage: "play.fill")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(demoStart != nil)
                Button { world.recenter() } label: {
                    Label("Recenter", systemImage: "scope")
                }
                .glassButton()
                .controlSize(.small)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !live && demoStart == nil)) { timeline in
                Canvas { context, size in
                    let input = input(at: timeline.date)
                    world.step(to: timeline.date, input: input, curve: curve, invertY: invertY, size: size)
                    world.draw(in: &context, size: size, input: input, curve: curve)
                }
            }
            .frame(height: 190)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 14) {
                Label { Text("With these settings") } icon: {
                    Image(systemName: "figure.walk").foregroundStyle(Color.xboxGlow)
                }
                Label { Text("Raw stick, no dead zone or curve") } icon: {
                    Image(systemName: "figure.walk").foregroundStyle(.white.opacity(0.35))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Stick position from -1 to 1 on each axis, up positive.
    private func input(at date: Date) -> CGVector {
        if let demoStart { return PlaygroundDemo.input(at: date.timeIntervalSince(demoStart)) }
        guard live else { return .zero }
        return CGVector(dx: Double(x) / 32767, dy: Double(y) / 32767)
    }
}

/// A scripted push for trying settings without the controller: right with a
/// steadily growing push, then the same to the left. Small pushes show the
/// dead zone and the bottom of the curve; big ones the top.
enum PlaygroundDemo {
    static let duration: Double = 8

    static func input(at t: Double) -> CGVector {
        let half = duration / 2
        guard t >= 0, t < duration else { return .zero }
        let push = (t.truncatingRemainder(dividingBy: half)) / half
        return CGVector(dx: t < half ? push : -push, dy: 0)
    }
}

/// Positions and drawing for the playground. A reference type that the
/// Canvas steps on every frame; it isn't observed, so changing it doesn't
/// trigger extra renders.
final class PlaygroundWorld {
    struct Walker {
        var position: CGPoint?
        var facingLeft = false
        var speed: Double = 0
        var distance: Double = 0
        var trail: [CGPoint] = []
    }

    /// Full push walks this many points per second.
    static let topSpeed: Double = 150
    private static let margin: CGFloat = 20

    private var shaped = Walker()
    private var raw = Walker()
    private var last: Date?
    private var sinceTrail: Double = 0

    func recenter() {
        shaped = Walker()
        raw = Walker()
    }

    /// The stick after the dead zone and curve, applied to the push the way
    /// the stick view shows it.
    static func shape(_ input: CGVector, curve: StickCurve, invertY: Bool) -> CGVector {
        let magnitude = min(1, (input.dx * input.dx + input.dy * input.dy).squareRoot())
        let scale = magnitude > 0 ? curve.output(for: magnitude) / magnitude : 0
        return CGVector(dx: input.dx * scale, dy: input.dy * scale * (invertY ? -1 : 1))
    }

    func step(to date: Date, input: CGVector, curve: StickCurve, invertY: Bool, size: CGSize) {
        // Long gaps happen when the timeline was paused; don't jump.
        let dt = min(last.map { date.timeIntervalSince($0) } ?? 0, 0.05)
        last = date
        sinceTrail += dt
        let addTrail = sinceTrail > 0.06
        if addTrail { sinceTrail = 0 }
        move(&shaped, by: Self.shape(input, curve: curve, invertY: invertY), dt: dt, size: size, addTrail: addTrail)
        move(&raw, by: input, dt: dt, size: size, addTrail: addTrail)
    }

    private func move(_ walker: inout Walker, by stick: CGVector, dt: Double, size: CGSize, addTrail: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + 6)
        var position = walker.position ?? center
        let velocity = CGVector(dx: stick.dx * Self.topSpeed, dy: -stick.dy * Self.topSpeed)
        position.x = min(max(position.x + velocity.dx * dt, Self.margin), size.width - Self.margin)
        position.y = min(max(position.y + velocity.dy * dt, Self.margin + 14), size.height - Self.margin)
        let moved = walker.position.map { hypot(position.x - $0.x, position.y - $0.y) } ?? 0
        walker.speed = dt > 0 ? moved / dt : 0
        walker.distance += moved
        if velocity.dx < -1 { walker.facingLeft = true } else if velocity.dx > 1 { walker.facingLeft = false }
        if addTrail {
            walker.trail.append(position)
            if walker.trail.count > 24 { walker.trail.removeFirst(walker.trail.count - 24) }
        }
        walker.position = position
    }

    func draw(in context: inout GraphicsContext, size: CGSize, input: CGVector, curve: StickCurve) {
        // Floor tiles, so slow movement is still visible.
        var grid = Path()
        var gx: CGFloat = 30
        while gx < size.width {
            grid.move(to: CGPoint(x: gx, y: 0))
            grid.addLine(to: CGPoint(x: gx, y: size.height))
            gx += 30
        }
        var gy: CGFloat = 30
        while gy < size.height {
            grid.move(to: CGPoint(x: 0, y: gy))
            grid.addLine(to: CGPoint(x: size.width, y: gy))
            gy += 30
        }
        context.stroke(grid, with: .color(.white.opacity(0.05)))

        drawWalker(raw, in: &context, color: .white.opacity(0.3))
        drawWalker(shaped, in: &context, color: .xboxGlow)

        let push = min(1, (input.dx * input.dx + input.dy * input.dy).squareRoot())
        let label = "Push \(Int((push * 100).rounded()))%  →  walks at \(Int((curve.output(for: push) * 100).rounded()))%"
        let text = context.resolve(Text(label).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white))
        let textSize = text.measure(in: size)
        let badge = CGRect(x: 10, y: 10, width: textSize.width + 16, height: textSize.height + 8)
        context.fill(Path(roundedRect: badge, cornerRadius: badge.height / 2), with: .color(.black.opacity(0.5)))
        context.draw(text, at: CGPoint(x: badge.midX, y: badge.midY))
    }

    private func drawWalker(_ walker: Walker, in context: inout GraphicsContext, color: Color) {
        guard let position = walker.position else { return }
        for (index, point) in walker.trail.enumerated() {
            let fade = Double(index + 1) / Double(walker.trail.count + 1)
            let dot = CGRect(x: point.x - 2, y: point.y + 14, width: 4, height: 4)
            context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.35 * fade)))
        }
        let walking = walker.speed > 2
        // Steps follow distance walked, so a faster walker also steps faster.
        let bob = walking ? abs(sin(walker.distance / 9)) * 3 : 0
        context.fill(Path(ellipseIn: CGRect(x: position.x - 11, y: position.y + 14, width: 22, height: 6)),
                     with: .color(.black.opacity(0.35)))
        var symbol = context.resolve(Image(systemName: walking ? "figure.walk" : "figure.stand"))
        symbol.shading = .color(color)
        var copy = context
        copy.translateBy(x: position.x, y: position.y - bob)
        if walker.facingLeft { copy.scaleBy(x: -1, y: 1) }
        copy.draw(symbol, in: CGRect(x: -12, y: -16, width: 24, height: 32))
    }
}

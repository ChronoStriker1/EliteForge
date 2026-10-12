import EliteKit
import SwiftUI

/// Measures the sticks and triggers from their raw positions: how far each
/// stick rests from centre and how far it reaches when circled. The
/// calibration itself lives in the controller's firmware; this only reads it.
struct StickCheckCard: View {
    @Environment(AppModel.self) private var model
    @State private var phase = Phase.idle
    @State private var left = StickCheck()
    @State private var right = StickCheck()
    @State private var leftTrigger = TriggerCheck()
    @State private var rightTrigger = TriggerCheck()
    @State private var calibrating: CalibrationTarget?

    private enum Phase { case idle, resting, circling, finished }

    /// How long the sticks are sampled while let go.
    private static let restDuration: Duration = .seconds(2)

    init() {}

    #if DEBUG
    /// A finished check, for snapshots.
    init(finished left: StickCheck, _ right: StickCheck, _ leftTrigger: TriggerCheck, _ rightTrigger: TriggerCheck) {
        _phase = State(initialValue: .finished)
        _left = State(initialValue: left)
        _right = State(initialValue: right)
        _leftTrigger = State(initialValue: leftTrigger)
        _rightTrigger = State(initialValue: rightTrigger)
    }
    #endif

    var body: some View {
        GlassCard(title: "Stick check", systemImage: "scope") {
            HStack(alignment: .top, spacing: 24) {
                StickReachPlot(title: "Left stick", check: left, x: sample.lx, y: sample.ly, measured: phase != .idle)
                StickReachPlot(title: "Right stick", check: right, x: sample.rx, y: sample.ry, measured: phase != .idle)
                VStack(alignment: .leading, spacing: 12) {
                    switch phase {
                    case .idle:
                        Text("Checks each stick for drift when you let go and for how far it reaches around its edge, using the raw positions before any profile settings.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: start) {
                            Text("Start Check").foregroundStyle(.white).padding(.horizontal, 4)
                        }
                        .glassButton(prominent: true)
                        .tint(.xbox)
                    case .resting:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Let go of both sticks and triggers…")
                        }
                    case .circling:
                        Text("Push each stick to its edge and circle it slowly two or three times. Pull both triggers all the way. Then press Done.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Circled: left \(percent(left.coverage)), right \(percent(right.coverage))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button { phase = .finished } label: {
                            Text("Done").foregroundStyle(.white).padding(.horizontal, 4)
                        }
                        .glassButton(prominent: true)
                        .tint(.xbox)
                    case .finished:
                        results
                        Button("Check Again", action: start)
                            .glassButton()
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Text("Calibrate").font(.subheadline.weight(.semibold))
                        ForEach(CalibrationTarget.allCases) { target in
                            Button(target.shortLabel) { calibrating = target }
                                .help("Calibrate the \(target.label)")
                        }
                        .glassButton()
                        .controlSize(.small)
                        .disabled(phase == .resting || phase == .circling)
                    }
                    Text("Calibrating stores a new range for a stick or trigger in the controller, as the Xbox Accessories app does. It applies to every profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: sample) { _, sample in record(sample) }
        .sheet(item: $calibrating) { target in
            CalibrationSheet(target: target)
        }
    }

    private var sample: RawSample {
        let input = model.input
        return RawSample(lx: input.rawLeftStickX, ly: input.rawLeftStickY,
                         rx: input.rawRightStickX, ry: input.rawRightStickY,
                         lt: input.rawLeftTrigger, rt: input.rawRightTrigger)
    }

    private func start() {
        left = StickCheck()
        right = StickCheck()
        leftTrigger = TriggerCheck()
        rightTrigger = TriggerCheck()
        phase = .resting
        // A stick held perfectly still sends no new reports, so take the
        // current position as the first sample.
        record(sample)
        Task {
            try? await Task.sleep(for: Self.restDuration)
            if phase == .resting { phase = .circling }
        }
    }

    private func record(_ sample: RawSample) {
        switch phase {
        case .resting:
            left.addRest(x: sample.lx, y: sample.ly)
            right.addRest(x: sample.rx, y: sample.ry)
            leftTrigger.addRest(sample.lt)
            rightTrigger.addRest(sample.rt)
        case .circling:
            left.addMotion(x: sample.lx, y: sample.ly)
            right.addMotion(x: sample.rx, y: sample.ry)
            leftTrigger.addMotion(sample.lt)
            rightTrigger.addMotion(sample.rt)
        case .idle, .finished:
            break
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            stickResult("Left stick", left)
            stickResult("Right stick", right)
            triggerResult("Left trigger", leftTrigger)
            triggerResult("Right trigger", rightTrigger)
        }
    }

    private func stickResult(_ name: String, _ check: StickCheck) -> some View {
        var lines: [(String, Bool)] = []
        if let deadZone = check.suggestedDeadZone {
            lines.append(("Rests \(percent(check.restOffset)) off centre. A \(deadZone)% dead zone in a profile hides the drift.", false))
        } else {
            lines.append(("Rests \(percent(check.restOffset)) off centre.", true))
        }
        if check.coverage < 0.9 {
            lines.append(("Only \(percent(check.coverage)) of the edge was circled, so reach wasn't measured all the way round.", false))
        }
        if let minimum = check.minimumReach {
            let short = check.shortDirections
            if short.isEmpty {
                lines.append(("Reaches at least \(percent(minimum)) of full travel in every direction circled.", true))
            } else {
                let directions = ListFormatter.localizedString(byJoining: short.map(\.label))
                lines.append(("Falls short of full travel to the \(directions), at \(percent(minimum)) at worst.", false))
            }
        }
        return resultRow(name, lines)
    }

    private func triggerResult(_ name: String, _ check: TriggerCheck) -> some View {
        var lines: [(String, Bool)] = []
        if check.rest > 20 {
            lines.append(("Reads \(percent(Double(check.rest) / 1023)) when let go.", false))
        }
        if check.peak == 0 {
            lines.append(("Wasn't pulled.", false))
        } else {
            let full = check.peak >= 1000
            lines.append((full ? "Reaches full travel." : "A full pull reaches \(percent(Double(check.peak) / 1023)).", full))
        }
        return resultRow(name, lines)
    }

    private func resultRow(_ name: String, _ lines: [(String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.subheadline.weight(.semibold))
            ForEach(lines, id: \.0) { text, good in
                Label {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(good ? Color.xboxGlow : .orange)
                }
                .font(.callout)
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

private struct RawSample: Equatable {
    var lx, ly, rx, ry: Int16
    var lt, rt: UInt16
}

/// A stick's reach drawn as a wedge per direction, with the live position
/// and, once measured, how far it rested from centre.
private struct StickReachPlot: View {
    let title: String
    let check: StickCheck
    let x: Int16
    let y: Int16
    let measured: Bool

    /// The plot leaves room past full travel, since diagonals often exceed it.
    private static let scale = 1.15

    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 / Self.scale
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                func point(_ distance: Double, _ angle: Double) -> CGPoint {
                    CGPoint(x: centre.x + cos(angle) * distance * radius, y: centre.y - sin(angle) * distance * radius)
                }

                let full = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                context.fill(full, with: .color(.black.opacity(0.3)))
                var cross = Path()
                cross.move(to: CGPoint(x: centre.x - radius, y: centre.y))
                cross.addLine(to: CGPoint(x: centre.x + radius, y: centre.y))
                cross.move(to: CGPoint(x: centre.x, y: centre.y - radius))
                cross.addLine(to: CGPoint(x: centre.x, y: centre.y + radius))
                context.stroke(cross, with: .color(.white.opacity(0.12)), lineWidth: 1)

                let width = 2 * Double.pi / Double(StickCheck.sectorCount)
                for (index, reach) in check.reach.enumerated() where reach > 0 {
                    let start = Double(index) * width
                    var wedge = Path()
                    wedge.move(to: centre)
                    wedge.addLine(to: point(reach, start))
                    wedge.addLine(to: point(reach, start + width))
                    wedge.closeSubpath()
                    let short = reach >= StickCheck.visitedReach && reach < StickCheck.shortReach
                    context.fill(wedge, with: .color(short ? .orange.opacity(0.55) : Color.xboxGlow.opacity(0.4)))
                }
                context.stroke(full, with: .color(.white.opacity(0.45)), lineWidth: 1.5)

                if measured, check.restSamples > 0 {
                    let rest = max(check.restOffset * radius, 2)
                    context.stroke(Path(ellipseIn: CGRect(x: centre.x - rest, y: centre.y - rest, width: rest * 2, height: rest * 2)),
                                   with: .color(.yellow.opacity(0.8)), lineWidth: 1)
                }

                let dot = CGPoint(x: centre.x + Double(x) / 32767 * radius, y: centre.y - Double(y) / 32767 * radius)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)), with: .color(.white))
            }
            .frame(width: 150, height: 150)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

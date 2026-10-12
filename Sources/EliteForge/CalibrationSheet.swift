import EliteKit
import SwiftUI

/// Recalibrates one stick or trigger in the controller's firmware with the
/// Xbox Accessories app's sequence. Sticks: 6 turns clockwise, 6
/// counter-clockwise, then up, right, down and left, then let go. Triggers:
/// 12 full pulls with the hair trigger lock on full, 12 on half, 12 on
/// short, with moving the lock as a step of its own. After each step the
/// control goes back to rest, the controller buzzes once, and Next starts
/// the following step. The controller collects
/// until it has seen the whole sequence; the read after that ends the
/// calibration and stores it, with the Accessories app's closing buzzes.
struct CalibrationSheet: View {
    let target: CalibrationTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var stage = Stage.intro
    @State private var before: CalibrationReading?
    @State private var after: CalibrationReading?
    @State private var error: String?
    /// Turns in the current direction, or pulls at the current lock position.
    @State private var count = 0.0
    @State private var lastAngle: Double?
    @State private var pulled = false
    @State private var restingSince: Date?
    @State private var confirmCancel = false

    private indirect enum Stage: Equatable {
        case intro, starting
        case clockwise, counterClockwise
        case push(Int)
        /// Move the hair trigger lock to `locks[index]`; Next is enabled
        /// once the controller reports it there.
        case setLock(Int)
        case pulls(Int)
        /// A step's movement is done; waiting for the control to go back to
        /// rest before buzzing. Then `next`, or the end of the calibration.
        case letGo(next: Stage?)
        /// Buzzed; Next goes on to the stage.
        case stepDone(next: Stage)
        case finishing, done, unfinished
    }

    private static let turnsPerDirection = 6
    private static let pullsPerLock = 12
    /// Where the stick is pushed after the turns, in order, as angles in degrees.
    private static let pushes: [(name: String, symbol: String, degrees: Double)] = [
        ("up", "arrow.up", 90), ("right", "arrow.right", 0), ("down", "arrow.down", -90), ("left", "arrow.left", 180),
    ]
    /// Lock positions in the order the Accessories app asks for them, long to short.
    private static let locks: [TriggerStop] = [.full, .mid, .short]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate the \(target.label)")
                .font(.title2.weight(.semibold))
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(stage != .intro && stage != .done)
        .onChange(of: sample) { _, sample in record(sample) }
        .confirmationDialog("Stop calibrating the \(target.label)?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop Calibrating", role: .destructive) { dismiss() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The controller keeps waiting for the rest of the movement, so the \(target.label) won't work properly until you calibrate it again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .intro:
            Text(target.isTrigger
                 ? "You'll set the hair trigger lock to full, half and short in turn, and at each one pull the trigger all the way and let go 12 times. After each set of pulls, let go of the trigger: the controller buzzes and asks you to move the lock. The new range is stored in the controller and applies to every profile."
                 : "You'll circle the stick around its edge 6 times clockwise, then 6 times counter-clockwise, then push it up, right, down and left, letting go after each push. After each step, let go of the stick: the controller buzzes, and Next starts the next step. The new range is stored in the controller and applies to every profile.")
                .fixedSize(horizontal: false, vertical: true)
        case .starting:
            working("Starting…")
        case .finishing:
            working("Saving…")
        case .clockwise, .counterClockwise:
            instruction(stage == .clockwise ? "Circle the stick clockwise around its edge." : "Now circle it counter-clockwise.",
                        detail: "\(min(Int(count), Self.turnsPerDirection)) of \(Self.turnsPerDirection) circles")
        case .push(let index):
            let push = Self.pushes[index]
            instruction("Push the stick \(push.name) as far as it goes.", symbol: push.symbol, detail: nil)
        case .letGo:
            instruction(target.isTrigger ? "Let go of the trigger." : "Let go of the stick.", detail: nil)
        case .stepDone(let next):
            instruction("Step done.", symbol: "checkmark.circle.fill", detail: "Press Next when you're ready to \(describe(next)).")
        case .setLock(let index):
            let lock = Self.locks[index]
            instruction("Set the hair trigger lock to \(lock.label.lowercased()).", symbol: "lock",
                        detail: lockPosition == lock
                            ? "The lock is on \(lock.label.lowercased()). Press Next to start pulling."
                            : "The lock is on \(lockPosition?.label.lowercased() ?? "an unknown position") now.")
        case .pulls(let index):
            let lock = Self.locks[index]
            if let current = lockPosition, current != lock {
                instruction("Set the hair trigger lock back to \(lock.label.lowercased()).",
                            detail: "It's on \(current.label.lowercased()) now.")
            } else {
                instruction("With the lock on \(lock.label.lowercased()), pull the trigger all the way and let go.",
                            detail: "\(Int(count)) of \(Self.pullsPerLock) pulls")
            }
        case .done:
            Label("Calibrated.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.xboxGlow)
            if let after {
                VStack(alignment: .leading, spacing: 2) {
                    if let before, !before.isCollecting { Text("Before: \(describe(before))") }
                    Text("After:  \(describe(after))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        case .unfinished:
            Text("The controller is still waiting for part of the movement. Start over and do every step.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    private func instruction(_ text: String, symbol: String? = nil, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.xboxGlow)
                }
                Text(text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: progress)
                .tint(.xbox)
            if let detail {
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Share of the whole sequence done, 0-1.
    private var progress: Double {
        let turns = Double(Self.turnsPerDirection)
        let steps = 2 * turns + Double(Self.pushes.count)
        switch stage {
        case .clockwise: return min(count, turns) / steps
        case .counterClockwise: return (turns + min(count, turns)) / steps
        case .push(let index): return (2 * turns + Double(index)) / steps
        case .pulls(let index): return (Double(index * Self.pullsPerLock) + count) / Double(Self.locks.count * Self.pullsPerLock)
        case .letGo(let next): return next.map(progressBefore) ?? 1
        case .stepDone(let next): return progressBefore(next)
        case .setLock: return progressBefore(stage)
        default: return 0
        }
    }

    /// Progress at the start of `stage`.
    private func progressBefore(_ stage: Stage) -> Double {
        let turns = Double(Self.turnsPerDirection)
        let steps = 2 * turns + Double(Self.pushes.count)
        switch stage {
        case .counterClockwise: return turns / steps
        case .push(let index): return (2 * turns + Double(index)) / steps
        case .pulls(let index), .setLock(let index): return Double(index) / Double(Self.locks.count)
        default: return 0
        }
    }

    /// What the next step asks for, after "ready to".
    private func describe(_ stage: Stage) -> String {
        switch stage {
        case .counterClockwise: "circle the stick counter-clockwise"
        case .push: "push the stick up, right, down and left"
        case .pulls(let index): "pull with the lock on \(Self.locks[index].label.lowercased())"
        default: "go on"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch stage {
        case .intro:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Start", action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isConfiguring)
        case .setLock(let index):
            cancelButton
            Button("Start Over", action: start)
            Button("Next") {
                reset()
                stage = .pulls(index)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(lockPosition != Self.locks[index])
        case .clockwise, .counterClockwise, .push, .pulls, .letGo, .unfinished:
            cancelButton
            Button("Start Over", action: start)
        case .stepDone(let next):
            cancelButton
            Button("Start Over", action: start)
            Button("Next") {
                reset()
                stage = next
            }
            .keyboardShortcut(.defaultAction)
        case .starting, .finishing:
            EmptyView()
        case .done:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Once started, the controller can't be told to stop, so leaving asks first.
    private var cancelButton: some View {
        Button("Cancel") { confirmCancel = true }
            .keyboardShortcut(.cancelAction)
    }

    // MARK: Flow

    private var sample: Sample {
        let input = model.input
        switch target {
        case .leftStick: return Sample(x: input.rawLeftStickX, y: input.rawLeftStickY, trigger: 0)
        case .rightStick: return Sample(x: input.rawRightStickX, y: input.rawRightStickY, trigger: 0)
        case .leftTrigger: return Sample(x: 0, y: 0, trigger: input.rawLeftTrigger)
        case .rightTrigger: return Sample(x: 0, y: 0, trigger: input.rawRightTrigger)
        }
    }

    /// Where the hair trigger lock is, from the 0x0C report. nil until the
    /// first report arrives.
    private var lockPosition: TriggerStop? {
        target == .leftTrigger ? model.input.leftTriggerStop : model.input.rightTriggerStop
    }

    private func start() {
        error = nil
        after = nil
        reset()
        stage = .starting
        Task {
            do {
                if before == nil { before = try await model.readCalibration(target) }
                try await model.startCalibration(target)
                stage = target.isTrigger ? .setLock(0) : .clockwise
            } catch {
                self.error = error.localizedDescription
                stage = .intro
            }
        }
    }

    private func reset() {
        count = 0
        lastAngle = nil
        pulled = false
        restingSince = nil
    }

    /// Ends a step: wait for the control to go back to rest, then buzz.
    private func stepFinished(next: Stage?) {
        reset()
        stage = .letGo(next: next)
        // It may already be at rest, and a control held still sends no reports.
        record(sample)
    }

    private func record(_ sample: Sample) {
        let x = Double(sample.x) / 32767, y = Double(sample.y) / 32767
        let radius = (x * x + y * y).squareRoot()
        switch stage {
        case .clockwise, .counterClockwise:
            guard radius >= 0.6 else {
                lastAngle = nil
                return
            }
            let angle = atan2(y, x)
            if let lastAngle {
                var delta = angle - lastAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                // Clockwise is a falling angle. Turning the other way undoes progress.
                let turn = (stage == .clockwise ? -delta : delta) / (2 * .pi)
                count = max(0, count + turn)
                if count >= Double(Self.turnsPerDirection) {
                    stepFinished(next: stage == .clockwise ? .counterClockwise : .push(0))
                    return
                }
            }
            lastAngle = angle
        case .push(let index):
            let wanted = Self.pushes[index].degrees * .pi / 180
            var off = abs(atan2(y, x) - wanted)
            if off > .pi { off = 2 * .pi - off }
            // Each push is followed by a let-go and a buzz, but the four
            // are one step, so there's no Next between them.
            if radius >= 0.9, off <= .pi / 6 {
                stepFinished(next: index + 1 < Self.pushes.count ? .push(index + 1) : nil)
            }
        case .letGo(let next):
            let resting = target.isTrigger ? sample.trigger <= 100 : radius < 0.2
            if resting { completeWhenStill(next: next) } else { restingSince = nil }
        case .pulls(let index):
            if let current = lockPosition, current != Self.locks[index] { return }
            if sample.trigger >= 900 { pulled = true }
            if pulled, sample.trigger <= 100 {
                pulled = false
                count += 1
                if Int(count) >= Self.pullsPerLock {
                    stepFinished(next: index + 1 < Self.locks.count ? .pulls(index + 1) : nil)
                }
            }
        default:
            break
        }
    }

    /// Once the control has stayed at rest for half a second, buzzes and
    /// offers Next, or after the last step ends the calibration. A control
    /// held still sends no reports, so the check runs on a timer rather
    /// than on the next sample.
    private func completeWhenStill(next: Stage?) {
        guard restingSince == nil else { return }
        let since = Date()
        restingSince = since
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard stage == .letGo(next: next), restingSince == since else { return }
            guard let next else { return finish() }
            switch next {
            case .push: stage = next
            case .pulls(let index): stage = .setLock(index)
            default: stage = .stepDone(next: next)
            }
            await model.calibrationPulse(strength: 10)
        }
    }

    /// The Accessories app's ending: one buzz, the read that stores the new
    /// calibration, then two more buzzes.
    private func finish() {
        stage = .finishing
        Task {
            await model.calibrationPulse(strength: 30)
            do {
                var reading = try await model.readCalibration(target)
                // The controller may take a moment to notice the last movement.
                for _ in 0..<4 where reading.isCollecting {
                    try await Task.sleep(for: .milliseconds(500))
                    reading = try await model.readCalibration(target)
                }
                if reading.isCollecting {
                    stage = .unfinished
                    return
                }
                after = reading
                stage = .done
                for _ in 0..<2 {
                    try? await Task.sleep(for: .milliseconds(200))
                    await model.calibrationPulse(strength: 30)
                }
            } catch {
                self.error = error.localizedDescription
                stage = .unfinished
            }
        }
    }

    private func describe(_ reading: CalibrationReading) -> String {
        let v = reading.values
        if target.isTrigger {
            return zip(["rest", "short", "half", "full"], v).map { "\($0) \($1)" }.joined(separator: ", ")
        }
        return v.count == 4 ? "X \(v[0]) to \(v[1]), Y \(v[2]) to \(v[3])" : v.map(String.init).joined(separator: " ")
    }
}

private struct Sample: Equatable {
    var x: Int16
    var y: Int16
    var trigger: UInt16
}

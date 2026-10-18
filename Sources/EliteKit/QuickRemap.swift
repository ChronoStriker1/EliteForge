import Foundation

/// The Accessories app's "press and hold a button to quickly remap it": one
/// control held on its own for `holdTime` picks it, once per press.
///
/// The controller only sends a report when something changes, so a button
/// held still produces no new samples. Call `update` again at `deadline`.
public struct QuickRemapDetector: Equatable, Sendable {
    public static let holdTime: Duration = .seconds(1)

    private enum Phase: Equatable, Sendable {
        case idle
        case holding(RemappableControl, since: ContinuousClock.Instant)
        /// Picked already; nothing more until it's let go.
        case picked(RemappableControl)
    }

    private var phase = Phase.idle

    public init() {}

    /// When a hold in progress becomes long enough.
    public var deadline: ContinuousClock.Instant? {
        if case .holding(_, let since) = phase { return since + Self.holdTime }
        return nil
    }

    /// Returns the control once it has been held for `holdTime`.
    public mutating func update(_ input: InputState, at time: ContinuousClock.Instant) -> RemappableControl? {
        // On a custom profile the report carries the remapped buttons, not
        // the ones pressed, so only Profile 0 (Default) says which control it is.
        guard input.activeSlot == 0, let control = Self.heldControl(input.buttons) else {
            phase = .idle
            return nil
        }
        switch phase {
        case .holding(control, let since) where time - since >= Self.holdTime:
            phase = .picked(control)
            return control
        case .holding(control, _), .picked(control):
            return nil
        default:
            phase = .holding(control, since: time)
            return nil
        }
    }

    /// The single control behind `buttons`. A paddle also reports the button
    /// it's mapped to, so a paddle bit outranks the buttons.
    static func heldControl(_ buttons: Set<InputButton>) -> RemappableControl? {
        let held = RemappableControl.allCases.filter { $0.inputButton.map(buttons.contains) ?? false }
        let paddles = held.filter(\.isPaddle)
        let candidates = paddles.isEmpty ? held : paddles
        return candidates.count == 1 ? candidates[0] : nil
    }
}

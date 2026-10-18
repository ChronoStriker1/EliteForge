import Foundation

/// Runs rumbles that can overlap, such as Buzz pressed during a motor test.
/// The motors stop when the newest rumble that actually started ends.
@MainActor
public final class RumbleSequencer {
    private var generation = 0

    public init() {}

    /// Starts the motors, waits `duration`, then stops them unless a newer
    /// rumble has started by then. A start that throws counts for nothing,
    /// so the rumble already playing still stops on time.
    public func play(for duration: Duration, start: () async throws -> Void, stop: () async throws -> Void) async throws {
        try await start()
        generation += 1
        let mine = generation
        try await Task.sleep(for: duration)
        if mine == generation { try await stop() }
    }
}

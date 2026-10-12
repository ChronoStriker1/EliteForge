import Foundation

/// Measures one stick from its raw 0x0C positions: how far from centre it
/// sits when let go, and how far it reaches in each direction when circled.
/// It reads the controller's calibration as it is; it can't change it.
public struct StickCheck: Equatable, Sendable {
    /// Directions are grouped into 5° sectors.
    public static let sectorCount = 72
    /// A sector counts as visited once the stick has been pushed at least
    /// this far in it.
    public static let visitedReach = 0.5
    /// Reach below this in a visited sector is reported as short.
    public static let shortReach = 0.95

    /// Furthest distance from centre seen in each sector, where 1 is a full
    /// axis (32767). Sector 0 points right and they run anticlockwise, so
    /// sector 18 is up.
    public private(set) var reach = [Double](repeating: 0, count: StickCheck.sectorCount)
    /// Furthest distance from centre while the stick was let go.
    public private(set) var restOffset: Double = 0
    public private(set) var restSamples = 0
    private var restSumX: Double = 0
    private var restSumY: Double = 0

    public init() {}

    public mutating func addRest(x: Int16, y: Int16) {
        let (dx, dy) = Self.normalized(x, y)
        restOffset = max(restOffset, (dx * dx + dy * dy).squareRoot())
        restSumX += dx
        restSumY += dy
        restSamples += 1
    }

    public mutating func addMotion(x: Int16, y: Int16) {
        let (dx, dy) = Self.normalized(x, y)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return }
        let sector = Self.sector(dx: dx, dy: dy)
        reach[sector] = max(reach[sector], distance)
    }

    /// Average resting position, each axis from -1 to 1, up positive.
    public var restCentre: (x: Double, y: Double)? {
        guard restSamples > 0 else { return nil }
        return (restSumX / Double(restSamples), restSumY / Double(restSamples))
    }

    /// Share of directions the stick has been pushed in, 0-1.
    public var coverage: Double {
        Double(reach.filter { $0 >= Self.visitedReach }.count) / Double(Self.sectorCount)
    }

    private var visited: [Double] { reach.filter { $0 >= Self.visitedReach } }

    public var averageReach: Double? {
        let visited = visited
        return visited.isEmpty ? nil : visited.reduce(0, +) / Double(visited.count)
    }

    public var minimumReach: Double? { visited.min() }

    /// Compass directions (of eight) containing a visited sector that fell
    /// short of `shortReach`.
    public var shortDirections: [Direction] {
        var result: [Direction] = []
        for (index, value) in reach.enumerated() where value >= Self.visitedReach && value < Self.shortReach {
            let direction = Direction(sector: index)
            if !result.contains(direction) { result.append(direction) }
        }
        return result.sorted { $0.rawValue < $1.rawValue }
    }

    /// Dead zone, in percent, that hides the resting offset with a small
    /// margin. Nil when the stick rests close enough to centre not to need one.
    public var suggestedDeadZone: Int? {
        guard restSamples > 0, restOffset >= 0.04 else { return nil }
        return min(Int(((restOffset + 0.02) * 100).rounded(.up)), 100)
    }

    static func normalized(_ x: Int16, _ y: Int16) -> (Double, Double) {
        (max(Double(x) / 32767, -1), max(Double(y) / 32767, -1))
    }

    static func sector(dx: Double, dy: Double) -> Int {
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        return min(Int(angle / (2 * .pi) * Double(sectorCount)), sectorCount - 1)
    }

    public enum Direction: Int, Sendable, CaseIterable {
        case right, upRight, up, upLeft, left, downLeft, down, downRight

        /// The eighth of the circle a sector's centre falls in.
        init(sector: Int) {
            let degrees = (Double(sector) + 0.5) * 360 / Double(StickCheck.sectorCount)
            self = Direction(rawValue: Int(((degrees + 22.5) / 45).rounded(.down)) % 8) ?? .right
        }

        public var label: String {
            switch self {
            case .right: "right"
            case .upRight: "up-right"
            case .up: "up"
            case .upLeft: "up-left"
            case .left: "left"
            case .downLeft: "down-left"
            case .down: "down"
            case .downRight: "down-right"
            }
        }
    }
}

/// Measures one trigger from its raw positions: where it rests and how far
/// a full pull reaches, out of 1023.
public struct TriggerCheck: Equatable, Sendable {
    public private(set) var rest: UInt16 = 0
    public private(set) var peak: UInt16 = 0

    public init() {}

    public mutating func addRest(_ value: UInt16) { rest = max(rest, value) }
    public mutating func addMotion(_ value: UInt16) { peak = max(peak, value) }
}

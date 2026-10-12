import Foundation

/// Sends raw GIP frames to the controller. Implemented by the USB transport
/// and by the simulator used in tests.
public protocol GIPLink: AnyObject, Sendable {
    func send(_ frame: GIPFrame) throws
    /// Called right before a frame that makes the controller restart its
    /// session, so the transport can re-send the init sequence afterwards.
    func expectRestart()
}

public extension GIPLink {
    func expectRestart() {}
}

/// Collects reply frames from the controller so a request can wait for its answer.
public final class FrameInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [GIPFrame] = []
    private let capacity = 256

    public init() {}

    public func push(_ frame: GIPFrame) {
        condition.lock()
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        condition.broadcast()
        condition.unlock()
    }

    /// Removes and returns the first frame matching `match`, waiting up to `timeout`.
    public func take(timeout: TimeInterval, where match: (GIPFrame) -> Bool) -> GIPFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = frames.firstIndex(where: match) {
                return frames.remove(at: index)
            }
            if !condition.wait(until: deadline) { return nil }
        }
    }

    public func removeAll() {
        condition.lock()
        frames.removeAll()
        condition.unlock()
    }

    public func removeAll(where match: (GIPFrame) -> Bool) {
        condition.lock()
        frames.removeAll(where: match)
        condition.unlock()
    }
}

public enum ControllerError: Error, LocalizedError, Equatable {
    case notConnected
    case timeout(String)
    case rejected(String, status: UInt8)
    case verifyFailed(page: UInt8)
    case invalidSlot(Int)
    case invalidPages
    /// The controller only accepts writes while its Default profile (slot 0) is active.
    case customProfileActive
    case differentController
    case usb(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "No Elite Series 2 controller is connected over USB."
        case .timeout(let what): "The controller didn't answer (\(what))."
        case .rejected(let what, let status): String(format: "The controller rejected %@ (status 0x%02X).", what, status)
        case .verifyFailed(let page): String(format: "Read-back of page 0x%02X didn't match what was written.", page)
        case .invalidSlot(let slot): "Profile \(slot) can't be changed. Use profiles 1, 2 or 3."
        case .invalidPages: "Profile pages have the wrong size."
        case .customProfileActive: "The controller only accepts changes while it's on Profile 0 (Default). Press the profile button until no profile light is on, then try again."
        case .differentController: "A different controller is connected now, so the change wasn't saved."
        case .usb(let message): message
        }
    }
}

/// Request/response operations on a connected controller. Blocking; call from
/// a background queue. One operation at a time.
public final class ControllerSession: @unchecked Sendable {
    public let link: GIPLink
    public let inbox: FrameInbox
    public let sequence: GIPSequence
    public var timeout: TimeInterval = 0.6
    public var retries = 3
    /// Answers still owed for attempts that timed out: each retry means the
    /// controller may answer the earlier attempt too, possibly much later.
    /// Guarded by the session lock.
    private var strays: [(isReply: (GIPFrame) -> Bool, count: Int, until: Date)] = []
    /// How long an owed answer is waited for before it's assumed lost.
    private var strayWindow: TimeInterval { timeout * 2 + 0.25 }
    private let lock = NSRecursiveLock()

    public init(link: GIPLink, inbox: FrameInbox, sequence: GIPSequence = GIPSequence()) {
        self.link = link
        self.inbox = inbox
        self.sequence = sequence
    }

    /// Runs `body` while holding the session lock, so multi-step writes don't interleave.
    public func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Vendor requests

    /// Reply status byte. Page reads of the active slot come back flagged
    /// 0x80 but still carry valid data; an unlock flagged 0x80 is refused.
    public static let statusActiveSlot: UInt8 = 0x80

    /// Sends a 0x4D request and waits for the 0x4D reply that `match` accepts.
    /// Throws unless the reply status is in `accepting`.
    @discardableResult
    func vendorRequest(_ payload: [UInt8], what: String, accepting: Set<UInt8> = [0x00], match: @escaping ([UInt8]) -> Bool) throws -> [UInt8] {
        try exclusive {
            // Every reply carries [sub-command, status, ...]; shorter ones are malformed.
            let isReply: (GIPFrame) -> Bool = { $0.command == GIPCommand.vendor && $0.payload.count >= 2 && match($0.payload) }
            // A late answer to an earlier, retried request must not be taken
            // as this request's answer. Replies use the controller's own
            // sequence numbers, so they can't be told apart any other way:
            // wait out the answers still owed, then drop anything left.
            absorbStrays()
            inbox.removeAll { $0.command == GIPCommand.vendor }
            // Every attempt may still be answered except the one whose answer
            // was taken; recorded on every way out, including send errors.
            // A send that threw counts too: it may have reached the controller.
            var attempts = 0
            var answered = false
            defer {
                let owed = attempts - (answered ? 1 : 0)
                if owed > 0 { strays.append((isReply, owed, Date().addingTimeInterval(strayWindow))) }
            }
            for _ in 0..<retries {
                attempts += 1
                try link.send(GIPPackets.vendor(sequence, payload))
                if let frame = inbox.take(timeout: timeout, where: isReply) {
                    answered = true
                    if !accepting.contains(frame.payload[1]) {
                        throw ControllerError.rejected(what, status: frame.payload[1])
                    }
                    return frame.payload
                }
            }
            throw ControllerError.timeout(what)
        }
    }

    /// Takes the answers owed to earlier timed-out attempts as they arrive,
    /// up to each one's deadline. Called with the session lock held.
    private func absorbStrays() {
        for stray in strays {
            var owed = stray.count
            while owed > 0, inbox.take(timeout: max(0, stray.until.timeIntervalSinceNow), where: stray.isReply) != nil {
                owed -= 1
            }
        }
        strays.removeAll()
    }

    public func unlock() throws {
        do {
            try vendorRequest([VendorCommand.unlock], what: "unlock") { $0.first == VendorCommand.unlock }
        } catch ControllerError.rejected(_, let status) where status == Self.statusActiveSlot {
            throw ControllerError.customProfileActive
        }
    }

    public func initExtendedReports() throws {
        try vendorRequest([VendorCommand.initExtended, 0x00], what: "extended reports") { $0.first == VendorCommand.initExtended }
    }

    public func readPage(_ page: UInt8, size: Int) throws -> [UInt8] {
        let what = String(format: "read page 0x%02X", page)
        let reply = try vendorRequest([VendorCommand.readPage, page, UInt8(size)], what: what, accepting: [0x00, Self.statusActiveSlot]) {
            $0.count >= 4 && $0[0] == VendorCommand.readPage && $0[2] == page
        }
        let data = Array(reply.dropFirst(4))
        guard data.count >= size else { throw ControllerError.timeout(what) }
        return Array(data.prefix(size))
    }

    public func writePage(_ page: UInt8, data: [UInt8]) throws {
        let what = String(format: "write page 0x%02X", page)
        try vendorRequest([VendorCommand.writePage, page, UInt8(data.count)] + data, what: what) {
            $0.count >= 3 && $0[0] == VendorCommand.writePage && $0[2] == page
        }
    }

    // MARK: Profiles

    public func readSlot(_ slot: Int) throws -> SlotPages {
        guard let pages = ProfilePages.addresses(slot: slot) else { throw ControllerError.invalidSlot(slot) }
        return try exclusive {
            SlotPages(
                normalMapping: try readPage(pages.normalMapping, size: MappingLayout.size),
                normalCurves: try readPage(pages.normalCurves, size: CurvesLayout.size),
                shiftMapping: try readPage(pages.shiftMapping, size: MappingLayout.size),
                shiftCurves: try readPage(pages.shiftCurves, size: CurvesLayout.size)
            )
        }
    }

    /// Writes all four pages of a slot using the same sequence as the
    /// Accessories app: unlock, write, re-init, commit to flash, read back,
    /// then tell the controller to reload the profile.
    public func writeSlot(_ slot: Int, pages: SlotPages) throws {
        guard let addresses = ProfilePages.addresses(slot: slot) else { throw ControllerError.invalidSlot(slot) }
        guard pages.isValid else { throw ControllerError.invalidPages }
        try exclusive {
            try initExtendedReports()
            try unlock()
            try unlock()
            let writes: [(UInt8, [UInt8])] = [
                (addresses.normalMapping, pages.normalMapping),
                (addresses.shiftMapping, pages.shiftMapping),
                (addresses.normalCurves, pages.normalCurves),
                (addresses.shiftCurves, pages.shiftCurves),
            ]
            for (page, data) in writes { try writePage(page, data: data) }
            try initExtendedReports()
            try unlock() // commit to flash
            let readBack = try readSlot(slot)
            let pairs: [(UInt8, [UInt8], [UInt8])] = [
                (addresses.normalMapping, pages.normalMapping, readBack.normalMapping),
                (addresses.shiftMapping, pages.shiftMapping, readBack.shiftMapping),
                (addresses.normalCurves, pages.normalCurves, readBack.normalCurves),
                (addresses.shiftCurves, pages.shiftCurves, readBack.shiftCurves),
            ]
            link.expectRestart()
            try link.send(GIPPackets.reloadProfile(sequence))
            for (page, written, read) in pairs where written != read {
                throw ControllerError.verifyFailed(page: page)
            }
        }
    }

    // MARK: Device name

    public func readName() throws -> String {
        let reply = try vendorRequest([VendorCommand.readName], what: "read name") { $0.first == VendorCommand.readName }
        return Self.decodeName(Array(reply.dropFirst(2)))
    }

    /// Writes the controller name (up to 15 characters) and returns what the controller stored.
    public func writeName(_ name: String) throws -> String {
        try exclusive {
            try unlock()
            try vendorRequest([VendorCommand.writeName] + Self.encodeName(name), what: "write name") { $0.first == VendorCommand.writeName }
            try initExtendedReports()
            try unlock()
            return try readName()
        }
    }

    static func encodeName(_ name: String) -> [UInt8] {
        // At most 15 UTF-16 units, cut at a whole character so an emoji
        // isn't split into half a surrogate pair.
        var units: [UInt16] = []
        for character in name {
            let next = Array(String(character).utf16)
            guard units.count + next.count <= 15 else { break }
            units += next
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        for (index, unit) in units.enumerated() {
            bytes[index * 2] = UInt8(unit & 0xFF)
            bytes[index * 2 + 1] = UInt8(unit >> 8)
        }
        return bytes
    }

    static func decodeName(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Live effects

    public func previewLight(_ color: RGBColor?) throws {
        try exclusive {
            try unlock()
            try link.send(GIPPackets.ledPreview(sequence, color: color))
        }
    }

    public func endLightPreview() throws {
        try link.send(GIPPackets.ledPreviewEnd(sequence))
    }

    public func rumble(leftGrip: UInt8, rightGrip: UInt8, leftTrigger: UInt8, rightTrigger: UInt8) throws {
        try link.send(GIPPackets.rumble(sequence, leftTrigger: leftTrigger, rightTrigger: rightTrigger, strong: leftGrip, weak: rightGrip))
    }
}

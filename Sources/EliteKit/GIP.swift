import Foundation

/// GIP (Gaming Input Protocol) command bytes used by the Elite Series 2.
public enum GIPCommand {
    public static let ack: UInt8 = 0x01
    public static let hello: UInt8 = 0x02
    public static let status: UInt8 = 0x03
    public static let power: UInt8 = 0x05
    public static let authDone: UInt8 = 0x06
    public static let guide: UInt8 = 0x07
    public static let rumble: UInt8 = 0x09
    public static let led: UInt8 = 0x0A
    public static let eliteInput: UInt8 = 0x0C
    public static let ledPreview: UInt8 = 0x0E
    public static let system: UInt8 = 0x1E
    public static let input: UInt8 = 0x20
    public static let vendor: UInt8 = 0x4D
}

/// GIP header option bits.
public enum GIPOptions {
    /// The receiver must acknowledge this frame.
    public static let needsAck: UInt8 = 0x10
    /// System (internal) message.
    public static let system: UInt8 = 0x20
    /// First chunk of a message split across several frames.
    public static let chunkStart: UInt8 = 0x40
    /// Part of a message split across several frames.
    public static let chunked: UInt8 = 0x80
}

/// Sub-commands of the 0x4D vendor command that carries all profile traffic.
public enum VendorCommand {
    public static let writePage: UInt8 = 0x01
    public static let readPage: UInt8 = 0x02
    public static let unlock: UInt8 = 0x03
    public static let writeName: UInt8 = 0x04
    public static let readName: UInt8 = 0x05
    public static let initExtended: UInt8 = 0x07
}

/// One GIP frame: a 4-byte header followed by the payload.
public struct GIPFrame: Equatable, Sendable {
    public var command: UInt8
    public var options: UInt8
    public var sequence: UInt8
    public var payload: [UInt8]
    /// Sends this byte as the length field instead of the payload size. Only
    /// for the fixed power packets that Xbox drivers send with a magic length.
    public var lengthOverride: UInt8?
    /// For chunked frames (option bit 0x80): the total size on the first
    /// chunk (option bit 0x40), otherwise this chunk's offset.
    public var chunkOffset: Int?

    public init(command: UInt8, options: UInt8, sequence: UInt8, payload: [UInt8], lengthOverride: UInt8? = nil) {
        self.command = command
        self.options = options
        self.sequence = sequence
        self.payload = payload
        self.lengthOverride = lengthOverride
    }

    /// Parses a frame from raw USB bytes. The length field is a LEB128 varint,
    /// although every Elite 2 frame seen so far fits in one byte.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 4 else { return nil }
        var length = 0
        var shift = 0
        var index = 3
        while index < bytes.count {
            let byte = bytes[index]
            length |= Int(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 14 { return nil }
        }
        var chunkOffset: Int?
        if bytes[1] & GIPOptions.chunked != 0 {
            var offset = 0
            var offsetShift = 0
            while index < bytes.count {
                let byte = bytes[index]
                offset |= Int(byte & 0x7F) << offsetShift
                index += 1
                if byte & 0x80 == 0 { break }
                offsetShift += 7
                if offsetShift > 14 { return nil }
            }
            // ACKs carry sizes as u16, so anything larger is malformed.
            guard offset <= 0xFFFF else { return nil }
            chunkOffset = offset
        }
        guard index + length <= bytes.count else { return nil }
        let end = index + length
        self.command = bytes[0]
        self.options = bytes[1]
        self.sequence = bytes[2]
        self.payload = Array(bytes[index..<end])
        self.lengthOverride = nil
        self.chunkOffset = chunkOffset
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [command, options, sequence]
        if let lengthOverride { return out + [lengthOverride] + payload }
        var length = payload.count
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length > 0 { byte |= 0x80 }
            out.append(byte)
        } while length > 0
        out.append(contentsOf: payload)
        return out
    }

    public var needsAck: Bool { options & GIPOptions.needsAck != 0 && command != GIPCommand.ack }

    public var clientID: UInt8 { options & 0x0F }

    /// The acknowledgement the host must send back for a frame flagged `needsAck`.
    /// Layout matches what the Windows Xbox Accessories app sends:
    /// `01 20 <seq> 09 00 <cmd> <opts> <received lo> <received hi> 00 00 <remaining lo> <remaining hi>`.
    /// For chunked messages `received` counts every byte up to the end of this
    /// chunk and `remaining` what is still to come; pass the message total.
    public func acknowledgement(totalLength: Int? = nil) -> GIPFrame {
        var received = payload.count
        var remaining = 0
        if let chunkOffset, options & GIPOptions.chunked != 0 {
            let total = totalLength ?? chunkOffset
            received = options & GIPOptions.chunkStart != 0 ? payload.count : chunkOffset + payload.count
            remaining = max(0, total - received)
        }
        received = min(received, 0xFFFF)
        remaining = min(remaining, 0xFFFF)
        return GIPFrame(
            command: GIPCommand.ack,
            options: GIPOptions.system | clientID,
            sequence: sequence,
            payload: [0x00, command, options & (GIPOptions.system | 0x0F),
                      UInt8(received & 0xFF), UInt8(received >> 8), 0, 0, UInt8(remaining & 0xFF), UInt8(remaining >> 8)]
        )
    }

    public var acknowledgement: GIPFrame { acknowledgement() }

    /// True for the frames the controller streams continuously (input and status).
    public var isStreaming: Bool {
        command == GIPCommand.input || command == GIPCommand.eliteInput || command == GIPCommand.status
    }
}

extension GIPFrame: CustomStringConvertible {
    public var description: String { bytes.hexString }
}

/// Thread-safe GIP sequence counter. Sequence 0 is reserved, so it wraps 255 -> 1.
public final class GIPSequence: @unchecked Sendable {
    private var value: UInt8
    private let lock = NSLock()

    public init(start: UInt8 = 1) { value = start == 0 ? 1 : start }

    public func next() -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = value == 255 ? 1 : value + 1
        return current
    }
}

/// Fixed packets the host sends.
public enum GIPPackets {
    /// Host init sequence after the controller says HELLO: Linux xpad's, then
    /// a "return to profile colour" LED command. xpad's LED command
    /// (`0a 20 .. 00 01 14`) is what starts the input stream, but it also
    /// forces the Xbox button to dim white; the trailing 0x0E mode-1 frame
    /// (also sent by the Accessories app after a preview) restores the
    /// active profile's colour.
    public static func initSequence(_ seq: GIPSequence) -> [GIPFrame] {
        [
            GIPFrame(command: GIPCommand.power, options: GIPOptions.system, sequence: seq.next(), payload: [0x00]),
            // Bluetooth -> USB transition, required on Elite 2 / One S hardware.
            // Linux xpad sends exactly `05 20 00 0f 06`: length byte 0x0F, one payload byte.
            GIPFrame(command: GIPCommand.power, options: GIPOptions.system, sequence: 0x00, payload: [0x06], lengthOverride: 0x0F),
            GIPFrame(command: GIPCommand.vendor, options: GIPOptions.needsAck, sequence: seq.next(), payload: [VendorCommand.initExtended, 0x00]),
            GIPFrame(command: GIPCommand.led, options: GIPOptions.system, sequence: seq.next(), payload: [0x00, 0x01, 0x14]),
            GIPFrame(command: GIPCommand.authDone, options: GIPOptions.system, sequence: seq.next(), payload: [0x01, 0x00]),
            ledPreviewEnd(seq),
        ]
    }

    /// USB -> Bluetooth transition, so the controller reconnects over Bluetooth
    /// without re-pairing once the cable is removed.
    public static func usbToBluetooth(_ seq: GIPSequence) -> GIPFrame {
        GIPFrame(command: GIPCommand.power, options: GIPOptions.system, sequence: 0x00, payload: [0x00], lengthOverride: 0x0F)
    }

    /// Makes the controller reload its active profile from flash.
    public static func reloadProfile(_ seq: GIPSequence) -> GIPFrame {
        GIPFrame(command: GIPCommand.power, options: GIPOptions.system, sequence: seq.next(), payload: [0x05])
    }

    /// Rumble. Values are 0-100.
    public static func rumble(_ seq: GIPSequence, leftTrigger: UInt8, rightTrigger: UInt8, strong: UInt8, weak: UInt8) -> GIPFrame {
        GIPFrame(
            command: GIPCommand.rumble, options: 0x00, sequence: seq.next(),
            payload: [0x00, 0x0F, min(leftTrigger, 100), min(rightTrigger, 100), min(strong, 100), min(weak, 100), 0xFF, 0x00, 0xEB]
        )
    }

    /// Rumble-off doubles as the keepalive that stops the controller re-sending HELLO.
    public static func keepalive(_ seq: GIPSequence) -> GIPFrame {
        rumble(seq, leftTrigger: 0, rightTrigger: 0, strong: 0, weak: 0)
    }

    /// Live Xbox-button LED preview. Not stored. Needs a vendor unlock first.
    /// Payload is `[mode, colorFlag, R, G, B]`; colorFlag 0xFF means the default white.
    public static func ledPreview(_ seq: GIPSequence, color: RGBColor?) -> GIPFrame {
        let payload: [UInt8]
        if let color {
            payload = [0x00, 0x00, color.red, color.green, color.blue]
        } else {
            payload = [0x00, 0xFF, 0x00, 0x00, 0x00]
        }
        return GIPFrame(command: GIPCommand.ledPreview, options: 0x00, sequence: seq.next(), payload: payload)
    }

    /// Ends the LED preview and returns to the stored profile colour.
    public static func ledPreviewEnd(_ seq: GIPSequence) -> GIPFrame {
        GIPFrame(command: GIPCommand.ledPreview, options: 0x00, sequence: seq.next(), payload: [0x01, 0x00, 0x00, 0x00, 0x00])
    }

    public static func vendor(_ seq: GIPSequence, _ payload: [UInt8]) -> GIPFrame {
        GIPFrame(command: GIPCommand.vendor, options: GIPOptions.needsAck, sequence: seq.next(), payload: payload)
    }

    /// A 0x1E request, such as calibration, in the same form as vendor requests.
    public static func system(_ seq: GIPSequence, _ payload: [UInt8]) -> GIPFrame {
        GIPFrame(command: GIPCommand.system, options: GIPOptions.needsAck, sequence: seq.next(), payload: payload)
    }
}

extension Array where Element == UInt8 {
    public var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }

    public init?(hexString: String) {
        let digits = hexString.filter { $0.isHexDigit }
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}

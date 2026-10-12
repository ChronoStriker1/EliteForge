import Foundation
@testable import EliteKit

/// In-memory stand-in for the controller's vendor command handling, so the
/// write sequence can be tested without hardware.
final class SimulatedController: GIPLink, @unchecked Sendable {
    let inbox = FrameInbox()
    var pages: [UInt8: [UInt8]] = [:]
    var name: [UInt8] = ControllerSession.encodeName("Elite")
    var sent: [GIPFrame] = []
    var unlocked = false
    var dropNextReplies = 0
    /// Holds the next reply back and delivers it with the reply to the
    /// following request, like a slow answer arriving after a retry.
    var delayNextReply = false
    private var delayed: GIPFrame?
    /// Delays for the next replies, in order; each reply arrives that many
    /// seconds after its request, on another thread.
    var replyDelays: [TimeInterval] = []
    /// The vendor request (counting from 1) whose send throws, like a USB error.
    var failVendorSend: Int?
    private var vendorSends = 0
    var corruptPage: UInt8?
    /// Mimics the real controller: with a custom profile active, unlock is
    /// refused and reads of that slot's pages are flagged 0x80.
    var activeSlot = 0
    /// Calibration values per target, as the controller reports them.
    var calibration: [UInt8: [UInt16]] = [0x01: [849, 3233, 883, 3248], 0x04: [1070, 1353, 1896, 3341]]
    /// Target bits being calibrated: started and not yet ended by a read.
    var calibrating: UInt8 = 0
    /// Whether the controller has seen the whole movement sequence, so the
    /// next read of the target ends its calibration.
    var calibrationMovementDone = true
    private var seq = GIPSequence(start: 0x40)

    init() {
        for slot in 1...3 {
            let a = ProfilePages.addresses(slot: slot)!
            pages[a.normalMapping] = MappingLayout.defaultPage
            pages[a.shiftMapping] = MappingLayout.defaultPage
            pages[a.normalCurves] = CurvesLayout.defaultPage
            pages[a.shiftCurves] = CurvesLayout.defaultPage
        }
    }

    func send(_ frame: GIPFrame) throws {
        sent.append(frame)
        if let late = delayed {
            delayed = nil
            inbox.push(late)
        }
        if frame.command == GIPCommand.system, frame.payload.count >= 2 {
            let target = frame.payload[1]
            var reply: [UInt8]
            switch frame.payload[0] {
            case CalibrationCommand.start:
                calibrating |= target
                reply = [0x10, 0x00, target]
            case CalibrationCommand.read:
                var values = calibration[target] ?? [0, 0, 0, 0]
                var state = calibrating
                if calibrating & target != 0 {
                    if calibrationMovementDone {
                        calibrating &= ~target
                        state = 0x10
                    } else {
                        values = values.map { _ in 0 }
                    }
                }
                reply = [0x0F, 0x00, state, target]
                if target & 0x0C != 0 { reply.append(UInt8(values.count)) }
                for value in values { reply += [UInt8(value & 0xFF), UInt8(value >> 8)] }
            default:
                return
            }
            inbox.push(GIPFrame(command: GIPCommand.system, options: GIPOptions.needsAck, sequence: seq.next(), payload: reply))
            return
        }
        guard frame.command == GIPCommand.vendor, let sub = frame.payload.first else { return }
        vendorSends += 1
        if vendorSends == failVendorSend { throw ControllerError.usb("send failed") }
        if dropNextReplies > 0 {
            dropNextReplies -= 1
            return
        }
        let p = frame.payload
        var reply: [UInt8]
        switch sub {
        case VendorCommand.unlock:
            if activeSlot != 0 {
                reply = [0x03, 0x80, ProfilePages.addresses(slot: activeSlot)!.normalMapping]
            } else {
                unlocked = true
                reply = [0x03, 0x00]
            }
        case VendorCommand.initExtended:
            reply = [0x07, 0x00]
        case VendorCommand.readPage:
            var data = pages[p[1]] ?? []
            if p[1] == corruptPage, !data.isEmpty { data[0] ^= 0xFF }
            let active = ProfilePages.addresses(slot: activeSlot).map { a in [a.normalMapping, a.normalCurves, a.shiftMapping, a.shiftCurves].contains(p[1]) } ?? false
            reply = [0x02, active ? 0x80 : 0x00, p[1], p[2]] + data
        case VendorCommand.writePage:
            guard unlocked else { reply = [0x01, 0x05, p[1]]; break }
            pages[p[1]] = Array(p[3...])
            reply = [0x01, 0x00, p[1]]
        case VendorCommand.readName:
            reply = [0x05, 0x00] + name
        case VendorCommand.writeName:
            name = Array(p[1...])
            reply = [0x04, 0x00]
        default:
            return
        }
        let replyFrame = GIPFrame(command: GIPCommand.vendor, options: 0x00, sequence: seq.next(), payload: reply)
        if delayNextReply {
            delayNextReply = false
            delayed = replyFrame
            return
        }
        if !replyDelays.isEmpty {
            let delay = replyDelays.removeFirst()
            let inbox = inbox
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { inbox.push(replyFrame) }
            return
        }
        inbox.push(replyFrame)
    }
}

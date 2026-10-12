import EliteKit
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// Raw USB access to a wired Elite Series 2.
///
/// macOS's built-in Xbox driver owns the controller and doesn't pass the
/// vendor (0x4D) profile commands through. `open()` captures the device away
/// from that driver, which needs root. `close()` releases it; macOS then
/// resets the controller and its own driver takes over again, so games keep
/// working once configuration is done.
public final class EliteUSBController: GIPLink, @unchecked Sendable {
    public static let vendorID = 0x045E
    public static let productID = 0x0B00
    static let outEndpoint = 0x02
    static let inEndpoint = 0x82

    public let inbox = FrameInbox()
    public let sequence = GIPSequence()
    /// The session reaches the transport through a weak link; a strong one
    /// would keep every released controller alive.
    public private(set) lazy var session = ControllerSession(link: WeakLink(self), inbox: inbox, sequence: sequence)

    /// Called on an internal queue for every frame that isn't a request reply:
    /// input reports, guide button, status, HELLO and system notifications.
    public var onEvent: ((GIPFrame) -> Void)?
    /// Called once if the controller is unplugged while open, with the
    /// transport that lost its device.
    public var onDisconnect: ((EliteUSBController) -> Void)?
    /// Called after the GIP init sequence is sent, which also resets any
    /// light override. Runs on an internal queue.
    public var onInit: (() -> Void)?
    /// Logs every frame in both directions when set.
    public var trace: ((String) -> Void)?
    /// Runs the GIP init sequence after capture. Off only for protocol experiments.
    public var sendsInitSequence = true

    /// From the last HELLO. Written on the USB queue, read from others.
    public var deviceInfo: DeviceInfo? { stateLock.withLock { storedDeviceInfo } }
    private var storedDeviceInfo: DeviceInfo?
    /// Serial of the controller this transport is for. Capture retries only
    /// take a device with this serial, so a replug of a different controller
    /// mid-capture can't be written to by mistake.
    public private(set) var serialNumber: String?

    private let usbQueue = DispatchQueue(label: "eliteforge.usb")
    private let sendQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "eliteforge.usb.send")
        queue.setSpecific(key: EliteUSBController.sendQueueKey, value: ())
        return queue
    }()
    private static let sendQueueKey = DispatchSpecificKey<Void>()
    private var device: IOUSBHostDevice?
    private var interface: IOUSBHostInterface?
    private var outPipe: IOUSBHostPipe?
    private var inPipe: IOUSBHostPipe?
    private var keepalive: DispatchSourceTimer?
    private var closed = false
    private var helloSeen = false
    private var initSent = false
    private var chunkTotals: [UInt8: Int] = [:]
    private var readErrors = 0
    /// The pipe reads are running on; reads on a pipe that has since been
    /// replaced or closed are left to stop.
    private var readPipe: IOUSBHostPipe?
    private var framesReceived = 0
    private var terminationClaimed = false
    /// Last status, input or reply frame from the gamepad itself.
    private var lastLiveFrame = Date()
    /// Set after a profile save, whose final reload restarts the controller.
    /// Only then does a HELLO during silence mean the init must be re-sent.
    private var restartExpectedUntil: Date?
    private let started = Date()
    private let stateLock = NSLock()
    private var lastRumble = Date.distantPast

    /// True if a wired Elite Series 2 is plugged in.
    public static func isPresent() -> Bool {
        let service = matchingService(class: "IOUSBHostDevice", extra: [:])
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }

    public init() throws {
        let service = Self.matchingService(class: "IOUSBHostDevice", extra: [:])
        guard service != 0 else { throw ControllerError.notConnected }
        defer { IOObjectRelease(service) }
        serialNumber = Self.serial(of: service)
    }

    private static func serial(of service: io_service_t) -> String? {
        IORegistryEntryCreateCFProperty(service, "kUSBSerialNumberString" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    deinit { close() }

    /// Timing state shared by every transport and the arrival monitor, which
    /// run on different queues.
    private static let settleLock = NSLock()
    /// When the last controller was released. macOS resets the device on
    /// release, and capturing again before it has re-enumerated grabs a
    /// half-torn-down device.
    nonisolated(unsafe) private static var lastRelease = Date.distantPast
    static let releaseSettleTime: TimeInterval = 3
    /// When each device was first seen, by IORegistry entry ID. A device that
    /// hasn't been seen before counts as just plugged in: it may have appeared
    /// moments ago, before this process started or between two checks.
    nonisolated(unsafe) private static var arrivals: [UInt64: Date] = [:]
    /// Capturing while macOS's Xbox and HID drivers are still starting on a
    /// freshly plugged-in controller panicked the kernel inside IOHIDFamily
    /// (macOS 27.0.1). Give them time, and wait for the device to go quiet.
    static let arrivalSettleTime: TimeInterval = 4

    /// Records that `service` was just plugged in. Called by EliteUSBMonitor.
    static func noteArrival(of service: io_service_t) {
        guard let id = registryID(service) else { return }
        settleLock.withLock { arrivals[id] = Date() }
    }

    static func noteRelease() {
        settleLock.withLock { lastRelease = Date() }
    }

    /// How long to wait before capturing `service` is safe, given its arrival
    /// and the last release.
    static func settleDelay(for service: io_service_t) -> TimeInterval {
        let id = registryID(service)
        return settleLock.withLock {
            let now = Date()
            var arrived = now
            if let id {
                if let seen = arrivals[id] { arrived = seen } else { arrivals[id] = now }
            }
            return max(releaseSettleTime - now.timeIntervalSince(lastRelease),
                       arrivalSettleTime - now.timeIntervalSince(arrived))
        }
    }

    private static func registryID(_ service: io_service_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    /// Captures the controller and runs the GIP init sequence.
    public func open() throws {
        guard geteuid() == 0 else {
            throw ControllerError.usb("Capturing the controller needs root. Install the EliteForge helper or run with sudo.")
        }
        // Capture asks the macOS driver to terminate, and the exclusive open
        // fails until it has. The device can also vanish briefly while it
        // re-enumerates, so keep trying for a few seconds.
        var lastError: Error = ControllerError.notConnected
        let deadline = Date().addingTimeInterval(20)
        while device == nil, Date() < deadline {
            let deviceService = Self.matchingService(class: "IOUSBHostDevice", extra: [:])
            if deviceService != 0 {
                // Only the controller this transport was made for. The serial
                // survives the re-enumeration after a release; a different
                // controller means the caller should start over.
                let found = Self.serial(of: deviceService)
                if let expected = serialNumber, let found, found != expected {
                    IOObjectRelease(deviceService)
                    throw ControllerError.notConnected
                }
                if serialNumber == nil { serialNumber = found }
                // Checked for this exact device, every attempt: the controller
                // may have been replugged meanwhile.
                let settle = Self.settleDelay(for: deviceService)
                if settle > 0 {
                    IOObjectRelease(deviceService)
                    Thread.sleep(forTimeInterval: min(settle, max(0, deadline.timeIntervalSinceNow)))
                    continue
                }
                // Don't pull the device out from under drivers that are still
                // matching, starting or terminating; try again later instead.
                var wait = mach_timespec_t(tv_sec: 3, tv_nsec: 0)
                guard IOServiceWaitQuiet(deviceService, &wait) == KERN_SUCCESS else {
                    IOObjectRelease(deviceService)
                    lastError = ControllerError.usb("macOS is still setting up the controller.")
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                // Waiting for quiet can take a while; make sure no new arrival
                // or release happened during it.
                guard Self.settleDelay(for: deviceService) <= 0 else {
                    IOObjectRelease(deviceService)
                    continue
                }
                do {
                    // No interest handler: while captured, macOS sends it tens of
                    // thousands of messages a second. Unplugging shows up as failed
                    // reads instead, and EliteUSBMonitor reports removal.
                    device = try IOUSBHostDevice(__ioService: deviceService, options: [.deviceCapture], queue: usbQueue, interestHandler: nil)
                } catch {
                    lastError = error
                }
                IOObjectRelease(deviceService)
            }
            if device == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard device != nil else {
            if case ControllerError.notConnected = lastError { throw lastError }
            throw ControllerError.usb("Couldn't capture the controller from the macOS driver: \(lastError.localizedDescription)")
        }

        // Right after capture the interface can still be a half torn-down copy
        // that accepts reads but never completes them. The controller answers
        // the init sequence within milliseconds, so reopen until it does.
        for attempt in 1...4 {
            try openInterface()
            let helloDeadline = Date().addingTimeInterval(attempt == 1 ? 1.0 : 0.3)
            while Date() < helloDeadline, !stateLock.withLock({ helloSeen }) {
                Thread.sleep(forTimeInterval: 0.02)
            }
            sendInitOnce()
            let aliveDeadline = Date().addingTimeInterval(1.5)
            while Date() < aliveDeadline, stateLock.withLock({ framesReceived }) == 0 {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if stateLock.withLock({ framesReceived }) > 0 { break }
            trace?("\(timestamp) no reply from the controller, reopening interface (attempt \(attempt))")
            closeInterface()
            if attempt == 4 {
                close()
                throw ControllerError.usb("The controller didn't respond after capture. Unplug it, plug it back in, and try again.")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        // Unplugged while initialising: replies arrived, then reads failed.
        if stateLock.withLock({ closed || terminationClaimed }) {
            close()
            throw ControllerError.notConnected
        }
        startKeepalive()
    }

    /// Finds interface 0 under the captured device, opens it, and starts reading.
    private func openInterface() throws {
        // Capture tears down the system driver's interface clients and the
        // interfaces get re-published. Look under the captured device so a
        // stale interface from before a recent release is never picked up.
        var interfaceService: io_service_t = 0
        for _ in 0..<60 {
            if let device { interfaceService = Self.gipInterface(of: device.ioService) }
            if interfaceService != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard interfaceService != 0 else {
            close()
            throw ControllerError.usb("The controller's GIP interface didn't appear after capture.")
        }
        defer { IOObjectRelease(interfaceService) }

        // The system HID driver lets go of the interface a moment after the
        // device itself, so the exclusive open can fail at first.
        let interfaceDeadline = Date().addingTimeInterval(4)
        var opened: IOUSBHostInterface?
        while opened == nil {
            do {
                opened = try IOUSBHostInterface(__ioService: interfaceService, options: [], queue: usbQueue, interestHandler: nil)
            } catch {
                if Date() > interfaceDeadline {
                    close()
                    throw ControllerError.usb("Couldn't open the controller's GIP interface: \(error.localizedDescription)")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let pipes: (IOUSBHostPipe, IOUSBHostPipe)
        do {
            pipes = (try opened!.copyPipe(withAddress: Self.outEndpoint), try opened!.copyPipe(withAddress: Self.inEndpoint))
        } catch {
            opened?.destroy()
            close()
            throw ControllerError.usb("Couldn't open the controller's USB endpoints: \(error.localizedDescription)")
        }
        sendQueue.sync {
            interface = opened
            outPipe = pipes.0
            inPipe = pipes.1
        }
        // On usbQueue, where read completions run, so a completion can't be
        // half-way through when the pipe changes under it.
        usbQueue.sync {
            stateLock.withLock {
                framesReceived = 0
                readErrors = 0
                readPipe = pipes.1
            }
        }
        // Two reads in flight so no report is dropped between completions.
        enqueueRead(on: pipes.1)
        enqueueRead(on: pipes.1)
    }

    /// Drops the interface but keeps the captured device, for a retry.
    private func closeInterface() {
        usbQueue.sync { stateLock.withLock { readPipe = nil } }
        sendQueue.sync {
            try? inPipe?.__abort(with: .asynchronous)
            interface?.destroy()
            interface = nil
            inPipe = nil
            outPipe = nil
        }
        stateLock.withLock { initSent = false }
    }

    /// Releases the controller back to macOS.
    public func close() {
        let alreadyClosed = stateLock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        if alreadyClosed { return }
        keepalive?.cancel()
        keepalive = nil
        // Pipes are only used on sendQueue, so tear them down there: no ACK,
        // keepalive or request can be mid-write when the interface goes away.
        let teardown = {
            try? self.inPipe?.__abort(with: .asynchronous)
            self.interface?.destroy()
            if self.device != nil { Self.noteRelease() }
            self.device?.destroy()
            self.inPipe = nil
            self.outPipe = nil
            self.interface = nil
            self.device = nil
        }
        if DispatchQueue.getSpecific(key: Self.sendQueueKey) != nil {
            teardown()
        } else {
            sendQueue.sync(execute: teardown)
        }
    }

    public var isOpen: Bool { stateLock.withLock { !closed && device != nil } }

    public func send(_ frame: GIPFrame) throws {
        let bytes = frame.bytes
        // Only a running motor counts as a rumble test; the rumble-off
        // keepalive must not hold back the next keepalive.
        if frame.command == GIPCommand.rumble, frame.payload.count >= 6, frame.payload[2...5].contains(where: { $0 > 0 }) {
            stateLock.withLock { lastRumble = Date() }
        }
        try sendQueue.sync {
            guard !stateLock.withLock({ closed }), let outPipe else { throw ControllerError.notConnected }
            trace?("\(timestamp) > \(bytes.hexString)")
            let data = NSMutableData(bytes: bytes, length: bytes.count)
            var transferred = 0
            do {
                try outPipe.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: 0)
            } catch {
                throw ControllerError.usb("USB write failed: \(error.localizedDescription)")
            }
        }
    }

    public func expectRestart() {
        stateLock.withLock { restartExpectedUntil = Date().addingTimeInterval(15) }
    }

    // MARK: Private

    private var timestamp: String { String(format: "%8.3f", Date().timeIntervalSince(started)) }

    /// The controller keeps re-sending HELLO while connected. Like the Linux
    /// driver, answer only the first one: re-running the init sequence mid-way
    /// through a profile write would reset the controller's unlock state.
    private func sendInitOnce() {
        let first = stateLock.withLock { () -> Bool in
            defer { initSent = true }
            return !initSent
        }
        guard first, sendsInitSequence else { return }
        for frame in GIPPackets.initSequence(sequence) {
            try? send(frame)
        }
        onInit?()
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Don't cut off a rumble test that's still running.
            if Date().timeIntervalSince(self.stateLock.withLock { self.lastRumble }) < 3 { return }
            DispatchQueue.global().async { try? self.send(GIPPackets.keepalive(self.sequence)) }
        }
        timer.resume()
        keepalive = timer
    }

    /// Takes the pipe as an argument so the read loop never touches `inPipe`,
    /// which `close()` clears on another queue.
    private func isCurrent(_ pipe: IOUSBHostPipe) -> Bool {
        stateLock.withLock { !closed && readPipe === pipe }
    }

    private func enqueueRead(on inPipe: IOUSBHostPipe) {
        // A pipe replaced by an interface reopen is left to die quietly.
        guard isCurrent(inPipe) else { return }
        let buffer = NSMutableData(length: 64)!
        do {
            try inPipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, count in
                guard let self else { return }
                // Late completions from a replaced pipe mustn't feed frames,
                // reset counters or end the replacement's capture.
                guard self.isCurrent(inPipe) else { return }
                if status == kIOReturnSuccess {
                    self.stateLock.withLock {
                        self.readErrors = 0
                        if count > 0 { self.framesReceived += 1 }
                    }
                    self.handle(Array(UnsafeRawBufferPointer(start: buffer.bytes, count: count)), from: inPipe)
                    self.enqueueRead(on: inPipe)
                    return
                }
                if status == kIOReturnAborted { return }
                if status == kIOReturnNoDevice || status == kIOReturnNotAttached {
                    self.handleTermination(from: inPipe)
                    return
                }
                self.trace?("\(self.timestamp) read error \(String(format: "0x%08x", status))")
                self.readFailed(on: inPipe)
            }
        } catch {
            // Not starting a read is as bad as a failed one: with no read
            // pending, nothing would ever arrive again.
            trace?("read enqueue failed: \(error.localizedDescription)")
            readFailed(on: inPipe)
        }
    }

    /// A pipe that keeps failing means the device went away under us (usually
    /// a stale interface). Retry a while, then give up so the helper sees the
    /// controller as gone and the next request recaptures it.
    private func readFailed(on inPipe: IOUSBHostPipe) {
        let errors = stateLock.withLock { () -> Int? in
            // Errors from a pipe being torn down are expected.
            guard !closed, readPipe === inPipe else { return nil }
            readErrors += 1
            return readErrors
        }
        guard let errors else { return }
        if errors >= 20 {
            handleTermination(from: inPipe)
        } else {
            usbQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.enqueueRead(on: inPipe) }
        }
    }

    /// Runs on usbQueue for a frame read from `pipe`.
    private func handle(_ bytes: [UInt8], from pipe: IOUSBHostPipe) {
        trace?("\(timestamp) < \(bytes.hexString)")
        guard let frame = GIPFrame(bytes: bytes) else { return }
        if frame.options & GIPOptions.chunkStart != 0, let total = frame.chunkOffset {
            stateLock.withLock { chunkTotals[frame.command] = total }
        }
        if frame.needsAck {
            let total = stateLock.withLock { chunkTotals[frame.command] }
            let ack = frame.acknowledgement(totalLength: total)
            sendQueue.async { [weak self] in
                // Only on the interface the frame came from.
                guard let self, !self.stateLock.withLock({ self.closed }), self.inPipe === pipe, let outPipe = self.outPipe else { return }
                let ackBytes = ack.bytes
                self.trace?("\(self.timestamp) > \(ackBytes.hexString)")
                let data = NSMutableData(bytes: ackBytes, length: ackBytes.count)
                var transferred = 0
                try? outPipe.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: 0)
            }
        }
        switch frame.command {
        case GIPCommand.ack:
            return
        case GIPCommand.vendor, GIPCommand.system:
            inbox.push(frame)
            stateLock.withLock { lastLiveFrame = Date() }
        case GIPCommand.hello:
            let info = DeviceInfo(hello: frame.payload)
            stateLock.withLock { storedDeviceInfo = info }
            // Client 1 (the virtual keyboard) repeats HELLO every 504 ms; that
            // needs nothing. The reload at the end of a save restarts the
            // gamepad's session, which then needs the init sequence again or
            // input stays dead; the gamepad goes quiet while it restarts.
            // Status frames also pause for seconds on their own (Windows
            // captures show them 20 s apart), so silence alone isn't a
            // restart. Treating it as one re-sent init every 14 s on firmware
            // 5.22.16.0.
            let restarted = stateLock.withLock { () -> Bool in
                helloSeen = true
                guard initSent, let until = restartExpectedUntil else { return false }
                guard Date() < until else {
                    restartExpectedUntil = nil
                    return false
                }
                guard Date().timeIntervalSince(lastLiveFrame) > 2.2 else { return false }
                initSent = false
                restartExpectedUntil = nil
                return true
            }
            if restarted { trace?("\(timestamp) controller restarted, re-sending init") }
            DispatchQueue.global().async { [weak self] in self?.sendInitOnce() }
            onEvent?(frame)
        default:
            if frame.isStreaming { stateLock.withLock { lastLiveFrame = Date() } }
            onEvent?(frame)
        }
    }

    /// Called on usbQueue (interest handler or failed reads). Closing waits for
    /// sendQueue, which may itself be waiting on a USB transfer, so do it elsewhere.
    /// `pipe` is the read pipe reporting the failure; a pipe that has been
    /// replaced since can't end the capture.
    private func handleTermination(from pipe: IOUSBHostPipe) {
        // Several failed reads can report the same unplug; only the first acts.
        let first = stateLock.withLock { () -> Bool in
            guard !closed, !terminationClaimed, readPipe === pipe else { return false }
            terminationClaimed = true
            return true
        }
        guard first else { return }
        DispatchQueue.global().async { [self] in
            close()
            onDisconnect?(self)
        }
    }

    /// Interface 0 (GIP) among the children of `device`, or 0.
    static func gipInterface(of device: io_service_t) -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               let number = IORegistryEntryCreateCFProperty(child, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               number == 0 {
                return child
            }
            IOObjectRelease(child)
        }
        return 0
    }

    static func matchingService(class className: String, extra: [String: Int]) -> io_service_t {
        let dict = IOServiceMatching(className)! as NSMutableDictionary
        dict["idVendor"] = vendorID
        dict["idProduct"] = productID
        for (key, value) in extra { dict[key] = value }
        return IOServiceGetMatchingService(kIOMainPortDefault, dict as CFDictionary)
    }
}

/// Watches for the wired controller being plugged in or removed.
public final class EliteUSBMonitor: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let handler: (Bool) -> Void

    /// `handler` runs on `queue` with `true` on arrival and `false` on removal.
    public init(queue: DispatchQueue, handler: @escaping (Bool) -> Void) {
        self.handler = handler
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        register(kIOFirstMatchNotification, arrived: true)
        register(kIOTerminatedNotification, arrived: false)
    }

    deinit {
        for iterator in iterators { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    private func register(_ type: String, arrived: Bool) {
        let dict = IOServiceMatching("IOUSBHostDevice")! as NSMutableDictionary
        dict["idVendor"] = EliteUSBController.vendorID
        dict["idProduct"] = EliteUSBController.productID
        var iterator: io_iterator_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = arrived
            ? { context, iterator in
                guard let context else { return }
                Unmanaged<EliteUSBMonitor>.fromOpaque(context).takeUnretainedValue().drain(iterator, arrived: true)
            }
            : { context, iterator in
                guard let context else { return }
                Unmanaged<EliteUSBMonitor>.fromOpaque(context).takeUnretainedValue().drain(iterator, arrived: false)
            }
        IOServiceAddMatchingNotification(port, type, dict as CFDictionary, callback, context, &iterator)
        iterators.append(iterator)
        // Arm the notification by draining the existing matches without reporting them.
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    private func drain(_ iterator: io_iterator_t, arrived: Bool) {
        var any = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            any = true
            if arrived { EliteUSBController.noteArrival(of: service) }
            IOObjectRelease(service)
        }
        if any { handler(arrived) }
    }
}

/// Forwards to a transport without retaining it.
private final class WeakLink: GIPLink, @unchecked Sendable {
    private weak var target: EliteUSBController?

    init(_ target: EliteUSBController) { self.target = target }

    func send(_ frame: GIPFrame) throws {
        guard let target else { throw ControllerError.notConnected }
        try target.send(frame)
    }

    func expectRestart() { target?.expectRestart() }
}

import EliteIPC
import EliteKit
import EliteUSB
import Foundation
import os
import SystemConfiguration

// Root LaunchDaemon that owns the controller while it's being configured.
// launchd starts it on demand when a client connects to the Mach service,
// and it exits after a minute with no clients.

let log = Logger(subsystem: helperServiceName, category: "helper")

final class ControllerManager: @unchecked Sendable {
    /// Blocking controller requests run here, one at a time.
    let operations = DispatchQueue(label: "eliteforge.helper.operations")
    private let lock = NSLock()
    private var controller: EliteUSBController?
    /// A transport that is still being opened. Its events count, so status
    /// and input that arrive during the capture aren't lost.
    private var opening: EliteUSBController?
    /// Xbox button colour for the Default profile, from setDefaultLight, and
    /// the client that set it. It lasts only as long as that client holds
    /// the controller, even if others (forgectl) keep it captured.
    private var defaultLight: RGBColor?
    private var defaultLightOwner: ObjectIdentifier?
    /// The transport currently showing the Default colour, so it can be ended
    /// regardless of what the latest profile slot says.
    private weak var defaultLightShownOn: EliteUSBController?
    private var clients: [ObjectIdentifier: NSXPCConnection] = [:]
    private var owners: Set<ObjectIdentifier> = []
    private var tracers: Set<ObjectIdentifier> = []
    private var sendsInitSequence = true
    private var status = ControllerStatus()
    private var input = InputState()
    private var inputDirty = false
    private var monitor: EliteUSBMonitor?
    private var inputTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private let eventQueue = DispatchQueue(label: "eliteforge.helper.events")

    init() {
        status.present = EliteUSBController.isPresent()
        monitor = EliteUSBMonitor(queue: eventQueue) { [weak self] arrived in
            guard let self else { return }
            let present = arrived || EliteUSBController.isPresent()
            let (changed, unplugged) = self.lock.withLock { () -> (Bool, EliteUSBController?) in
                defer { self.status.present = present }
                return (self.status.present != present, present ? nil : self.controller)
            }
            if let unplugged {
                // The transport has no interest handler, so removal is reported here.
                unplugged.close()
                self.handleDisconnect(unplugged)
            } else if changed {
                self.broadcastStatus()
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.flushInput() }
        timer.resume()
        inputTimer = timer
        scheduleIdleExit()
    }

    // MARK: Clients

    func add(_ connection: NSXPCConnection) {
        lock.withLock { clients[ObjectIdentifier(connection)] = connection }
        idleTimer?.cancel()
    }

    func remove(_ connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        operations.async {
            let (wasOwner, empty) = self.lock.withLock { () -> (Bool, Bool) in
                self.clients[id] = nil
                self.tracers.remove(id)
                return (self.owners.remove(id) != nil, self.clients.isEmpty)
            }
            self.dropDefaultLight(setBy: id)
            if wasOwner { self.releaseIfUnowned() }
            if empty { self.scheduleIdleExit() }
        }
    }

    private func scheduleIdleExit() {
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.clients.isEmpty && self.controller == nil }
            if idle {
                log.info("idle, exiting")
                exit(0)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: Requests

    /// Runs on `operations`.
    func handle(_ request: HelperRequest, from client: ObjectIdentifier) -> HelperReply {
        do {
            switch request {
            case .status:
                return .status(lock.withLock { status })
            case .attach:
                try attach(client)
                return .status(lock.withLock { status })
            case .detach:
                dropDefaultLight(setBy: client)
                lock.withLock { _ = owners.remove(client) }
                releaseIfUnowned()
                return .status(lock.withLock { status })
            case .readSlot(let slot):
                return .pages(try attach(client).readSlot(slot))
            case .writeSlot(let slot, let pages, let serial):
                let controller = try attachController(client, expecting: serial)
                try pages.checkWritable(firmware: controller.deviceInfo?.firmware)
                try controller.session.writeSlot(slot, pages: pages)
                return .ok
            case .readName:
                return .name(try attach(client).readName())
            case .writeName(let name, let serial):
                return .name(try attach(client, expecting: serial).writeName(name))
            // Effects only use an existing capture. Cleanup that arrives after a
            // release (preview end, rumble off) must not take the controller back.
            case .previewLight(let color):
                guard let session = existingSession(client) else { throw ControllerError.notConnected }
                try session.previewLight(color)
                return .ok
            case .endLightPreview:
                // Back to the Default-profile colour if one is set, not white.
                if lock.withLock({ defaultLight != nil && status.activeSlot == 0 }) {
                    applyDefaultLight()
                } else {
                    try existingSession(client)?.endLightPreview()
                }
                return .ok
            case .setDefaultLight(let color):
                lock.withLock {
                    defaultLight = color
                    defaultLightOwner = color == nil ? nil : client
                }
                if color == nil { endDefaultLightOverride() } else { applyDefaultLight() }
                return .ok
            case .rumble(let leftGrip, let rightGrip, let leftTrigger, let rightTrigger):
                let off = leftGrip == 0 && rightGrip == 0 && leftTrigger == 0 && rightTrigger == 0
                guard let session = existingSession(client) else {
                    if off { return .ok }
                    throw ControllerError.notConnected
                }
                try session.rumble(leftGrip: leftGrip, rightGrip: rightGrip, leftTrigger: leftTrigger, rightTrigger: rightTrigger)
                return .ok
            case .readCalibration(let target):
                return .calibration(try attach(client).readCalibration(target))
            case .startCalibration(let target, let serial):
                try attach(client, expecting: serial).startCalibration(target)
                return .ok
            case .sendRaw(let bytes):
                #if HELPER_RAW_SEND
                guard let frame = GIPFrame(bytes: bytes) else { return .failure("Not a GIP frame.") }
                let controller = try attachController(client)
                try controller.send(GIPFrame(command: frame.command, options: frame.options, sequence: frame.sequence, payload: Array(bytes.dropFirst(4)), lengthOverride: bytes[3]))
                return .ok
                #else
                return .failure("This helper was built without raw send support.")
                #endif
            case .setInitSequence(let enabled):
                #if HELPER_RAW_SEND
                lock.withLock { sendsInitSequence = enabled }
                return .ok
                #else
                return .failure("This helper was built without developer options.")
                #endif
            case .setTrace(let enabled):
                lock.withLock {
                    if enabled { tracers.insert(client) } else { tracers.remove(client) }
                }
                return .ok
            }
        } catch {
            log.error("request failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error.localizedDescription)
        }
    }

    /// The session for a controller `client` already holds, without capturing.
    private func existingSession(_ client: ObjectIdentifier) -> ControllerSession? {
        lock.withLock {
            guard owners.contains(client), let controller, controller.isOpen else { return nil }
            return controller.session
        }
    }

    /// Captures the controller if needed and records `client` as a user of it.
    /// With `expecting`, refuses (before capturing) if the connected
    /// controller has a different serial: a write queued for one controller
    /// must not land on another plugged in meanwhile.
    @discardableResult
    private func attach(_ client: ObjectIdentifier, expecting serial: String? = nil) throws -> ControllerSession {
        try attachController(client, expecting: serial).session
    }

    private func attachController(_ client: ObjectIdentifier, expecting serial: String? = nil) throws -> EliteUSBController {
        func check(_ controller: EliteUSBController) throws {
            if let serial, controller.serialNumber != serial { throw ControllerError.differentController }
        }
        if let controller = lock.withLock({ self.controller }), controller.isOpen {
            try check(controller)
            // A new owner needs the current input; reports only arrive on
            // change. The next input flush sends it, in order with later reports.
            lock.withLock {
                owners.insert(client)
                inputDirty = true
            }
            return controller
        }
        let controller = try EliteUSBController()
        try check(controller)
        lock.withLock {
            controller.sendsInitSequence = sendsInitSequence
            opening = controller
            input = InputState()
            inputDirty = false
        }
        controller.onEvent = { [weak self, weak controller] frame in
            guard let self, let controller else { return }
            self.handleEvent(frame, from: controller)
        }
        controller.onDisconnect = { [weak self] lost in self?.handleDisconnect(lost) }
        // The init sequence (first capture, or after a save restarts the
        // controller) ends any light override; put the Default colour back.
        controller.onInit = { [weak self] in
            self?.operations.asyncAfter(deadline: .now() + 0.5) { self?.learnSlotThenApplyLight() }
        }
        controller.trace = { [weak self] line in
            guard let self else { return }
            let targets = self.lock.withLock { self.tracers.compactMap { self.clients[$0] } }
            if !targets.isEmpty { self.send(.trace(line), to: targets) }
        }
        do {
            try controller.open()
        } catch {
            lock.withLock { if opening === controller { opening = nil } }
            throw error
        }
        // An unplug during open() clears `opening`; don't publish a dead transport.
        let promoted = lock.withLock { () -> Bool in
            guard opening === controller, controller.isOpen else { return false }
            opening = nil
            self.controller = controller
            owners.insert(client)
            inputDirty = true
            status.attached = true
            status.present = true
            // Only this capture's HELLO: writes choose the page format by it.
            status.info = controller.deviceInfo
            status.serialNumber = controller.serialNumber
            return true
        }
        if promoted { operations.async { [weak self] in self?.learnSlotThenApplyLight() } }
        guard promoted else {
            lock.withLock { if opening === controller { opening = nil } }
            controller.close()
            throw ControllerError.notConnected
        }
        log.info("captured controller")
        broadcastStatus()
        return controller
    }

    private func releaseIfUnowned() {
        let controller = lock.withLock { () -> EliteUSBController? in
            guard owners.isEmpty, let controller = self.controller else { return nil }
            self.controller = nil
            input = InputState()
            inputDirty = false
            status.attached = false
            status.activeSlot = nil
            status.battery = nil
            return controller
        }
        guard let controller else { return }
        try? controller.session.endLightPreview()
        controller.close()
        log.info("released controller")
        broadcastStatus()
    }

    // MARK: Controller events

    private func handleEvent(_ frame: GIPFrame, from source: EliteUSBController) {
        var statusChanged = false
        var slotBefore: Int?
        var slotAfter: Int?
        // Frames from a transport still opening update state quietly: until
        // promotion, `status` still carries the previous controller's serial,
        // and publishing the new one's details with it would mix them up.
        var opening = false
        lock.withLock {
            // A released or unplugged transport can still deliver a last frame.
            guard source === controller || source === self.opening else { return }
            opening = source !== controller
            slotBefore = status.activeSlot
            defer { slotAfter = status.activeSlot }
            switch frame.command {
            case GIPCommand.input:
                input.apply(input: frame.payload)
                inputDirty = true
            case GIPCommand.guide:
                input.apply(guide: frame.payload)
                inputDirty = true
            case GIPCommand.eliteInput:
                // The raw positions can change on their own: while a stick is
                // being calibrated, its processed 0x20 values stay put.
                let before = input
                input.apply(elite: frame.payload)
                if input != before { inputDirty = true }
                if status.activeSlot != input.activeSlot {
                    status.activeSlot = input.activeSlot
                    statusChanged = true
                }
            case GIPCommand.status:
                let battery = BatteryStatus(status: frame.payload)
                if battery != status.battery {
                    status.battery = battery
                    statusChanged = true
                }
            case GIPCommand.hello:
                // While opening, promotion takes this from the transport.
                guard !opening else { break }
                status.info = DeviceInfo(hello: frame.payload)
                statusChanged = true
            case GIPCommand.system where frame.payload.count >= 2 && frame.payload[0] == 0x03:
                // Profile button pressed on the controller.
                status.activeSlot = Int(frame.payload[1] & 0x03)
                input.activeSlot = status.activeSlot
                statusChanged = true
            default:
                break
            }
        }
        if statusChanged, !opening { broadcastStatus() }
        if !opening, slotBefore != slotAfter {
            operations.async { [weak self] in self?.defaultLightSlotChanged(from: slotBefore, to: slotAfter) }
        }
    }

    // MARK: Default-profile light

    /// After a capture the active profile is unknown until input changes, so
    /// ask the controller; then show the Default colour if it's on Default,
    /// without waiting for a button press. Runs on `operations`.
    private func learnSlotThenApplyLight() {
        let target = lock.withLock { () -> EliteUSBController? in
            guard let controller, controller.isOpen, status.activeSlot == nil else { return nil }
            return controller
        }
        if let target {
            do {
                if let slot = try target.session.probeActiveSlot() {
                    // A report that arrived meanwhile is newer; keep it.
                    let learned = lock.withLock { () -> Bool in
                        guard target === controller, status.activeSlot == nil else { return false }
                        status.activeSlot = slot
                        input.activeSlot = slot
                        inputDirty = true
                        return true
                    }
                    if learned { broadcastStatus() }
                }
            } catch {
                log.error("active profile: \(error.localizedDescription, privacy: .public)")
            }
        }
        applyDefaultLight()
    }

    /// Shows the Default-profile colour if the controller is on Default.
    /// Runs on `operations`: it waits for the controller's reply.
    private func applyDefaultLight() {
        let (target, color) = lock.withLock { () -> (EliteUSBController?, RGBColor?) in
            guard let controller, controller.isOpen, status.activeSlot == 0, let color = defaultLight else { return (nil, nil) }
            return (controller, color)
        }
        guard let target, let color else { return }
        do {
            try target.session.previewLight(color)
            lock.withLock { defaultLightShownOn = target }
        } catch {
            log.error("default light: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the Default colour if it's showing on the current transport.
    /// Runs on `operations`.
    private func endDefaultLightOverride() {
        let target = lock.withLock { () -> EliteUSBController? in
            guard let shown = defaultLightShownOn, shown === controller, shown.isOpen else {
                defaultLightShownOn = nil
                return nil
            }
            defaultLightShownOn = nil
            return shown
        }
        try? target?.session.endLightPreview()
    }

    /// Turns the Default colour off if `client` set it, ending the override
    /// on the controller. Runs on `operations`.
    private func dropDefaultLight(setBy client: ObjectIdentifier) {
        let owned = lock.withLock { () -> Bool in
            guard defaultLightOwner == client else { return false }
            defaultLight = nil
            defaultLightOwner = nil
            return true
        }
        if owned { endDefaultLightOverride() }
    }

    /// On Default the override shows the chosen colour; leaving Default ends
    /// it so the custom profile's own colour shows.
    private func defaultLightSlotChanged(from old: Int?, to new: Int?) {
        if new == 0 {
            applyDefaultLight()
        } else if old == 0 {
            endDefaultLightOverride()
        }
    }

    /// Ignores reports about a transport that has already been replaced.
    fileprivate func handleDisconnect(_ lost: EliteUSBController) {
        let present = EliteUSBController.isPresent()
        // One lock scope: a replacement attached between the check and the
        // reset must not be cleared.
        let current = lock.withLock { () -> Bool in
            // Lost while still opening: attachController sees `opening`
            // cleared and fails instead of publishing it.
            if opening === lost {
                opening = nil
                return false
            }
            guard controller === lost else { return false }
            controller = nil
            input = InputState()
            inputDirty = false
            owners.removeAll()
            status.attached = false
            status.present = present
            status.activeSlot = nil
            status.battery = nil
            return true
        }
        guard current else { return }
        log.info("controller unplugged")
        broadcastStatus()
    }

    // MARK: Events to clients

    private func flushInput() {
        let (state, targets) = lock.withLock { () -> (InputState?, [NSXPCConnection]) in
            guard inputDirty else { return (nil, []) }
            inputDirty = false
            return (input, owners.compactMap { clients[$0] })
        }
        guard let state else { return }
        send(.input(state), to: targets)
    }

    private func broadcastStatus() {
        let (status, targets) = lock.withLock { (self.status, Array(clients.values)) }
        send(.status(status), to: targets)
    }

    private func send(_ event: HelperEvent, to connections: [NSXPCConnection]) {
        let data = HelperCoding.encode(event)
        for connection in connections {
            (connection.remoteObjectProxyWithErrorHandler { _ in } as? HelperClientXPCProtocol)?.receive(data)
        }
    }
}

final class HelperEndpoint: NSObject, HelperXPCProtocol {
    let manager: ControllerManager
    let client: ObjectIdentifier

    init(manager: ControllerManager, client: ObjectIdentifier) {
        self.manager = manager
        self.client = client
    }

    func perform(_ request: Data, reply: @escaping (Data) -> Void) {
        guard let decoded = try? HelperCoding.decode(HelperRequest.self, from: request) else {
            reply(HelperCoding.encode(HelperReply.failure("Malformed request. The app and helper versions may not match.")))
            return
        }
        let manager = self.manager
        let client = self.client
        manager.operations.async {
            reply(HelperCoding.encode(manager.handle(decoded, from: client)))
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let manager = ControllerManager()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only root and the user at the console may drive the controller.
        let uid = connection.effectiveUserIdentifier
        guard uid == 0 || uid == consoleUserID() else {
            log.error("rejected client pid \(connection.processIdentifier) uid \(uid)")
            return false
        }
        #if !HELPER_RAW_SEND
        // And only the exact app and CLI binaries recorded at install time.
        // Builds are ad-hoc signed, so an identifier alone could be copied by
        // any local program; the code hash can't. Developer helpers skip this
        // so command-line tools from `swift build` work.
        guard let requirement = clientRequirement() else {
            log.error("no trusted clients recorded in \(clientsFile, privacy: .public); reinstall the helper")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        #endif
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = HelperEndpoint(manager: manager, client: ObjectIdentifier(connection))
        connection.remoteObjectInterface = NSXPCInterface(with: HelperClientXPCProtocol.self)
        connection.invalidationHandler = { [weak self, unowned connection] in self?.manager.remove(connection) }
        manager.add(connection)
        connection.resume()
        log.info("client connected, pid \(connection.processIdentifier)")
        return true
    }
}

/// uid of the user logged in at the console, or nil at the login window.
func consoleUserID() -> uid_t? {
    var uid: uid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil, uid != 0 else { return nil }
    return uid
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: helperServiceName)
listener.delegate = delegate
listener.resume()
log.info("helper started")
RunLoop.main.run()

/// Root-owned list of accepted clients, written by install-helper.sh: one
/// "<signing identifier> <cdhash>" per line.
/// Computed: a stored top-level constant here would never be initialized,
/// because it comes after RunLoop.main.run() in main.swift.
var clientsFile: String { "/Library/PrivilegedHelperTools/com.eliteforge.helper.clients" }

/// A code signing requirement matching only the recorded binaries, or nil if
/// none are recorded. Lines that don't look right are skipped, so the file
/// can't inject requirement syntax.
func clientRequirement() -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: clientsFile),
          (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
          let text = try? String(contentsOfFile: clientsFile, encoding: .utf8) else { return nil }
    let allowedIDs: Set<String> = ["com.eliteforge.app", "com.eliteforge.forgectl"]
    let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    let clauses = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
        let parts = line.split(separator: " ")
        guard parts.count == 2, allowedIDs.contains(String(parts[0])),
              parts[1].count == 40, parts[1].unicodeScalars.allSatisfy(hex.contains) else { return nil }
        return "(identifier \"\(parts[0])\" and cdhash H\"\(parts[1].lowercased())\")"
    }
    return clauses.isEmpty ? nil : clauses.joined(separator: " or ")
}

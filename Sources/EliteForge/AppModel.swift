import AppKit
import EliteIPC
import EliteKit
import Foundation
import Observation

/// What the detail pane is editing.
enum EditorSource: Hashable {
    case slot(Int)
    case library(UUID)
}

enum SidebarItem: Hashable {
    case controller
    case slot(Int)
    case library(UUID)
}

enum HelperState: Equatable {
    case checking
    case notInstalled(String)
    case outdated(installed: Int)
    case ready
}

@MainActor
@Observable
final class AppModel {
    // Helper and controller
    var helperState: HelperState = .checking
    var status = ControllerStatus(helperVersion: 0)
    var input = InputState()
    var controllerName = ""
    /// Profiles currently stored on the controller, by slot.
    var slots: [Int: EliteProfile] = [:]
    /// Slots that have never been written (the controller flags them as blank).
    var blankSlots: Set<Int> = []
    /// Serial of the controller `slots` were read from.
    private var slotsSerial: String?

    // Library and editing
    var library = ProfileLibrary.load()
    var selection: SidebarItem? = .controller
    var draft: EliteProfile?
    var draftSource: EditorSource?
    var draftIsDirty = false
    /// Bumped when the draft is replaced rather than edited (switching
    /// profiles, Revert, a re-read, a reset), so editor state that isn't
    /// stored in the profile can start over.
    private(set) var draftRevision = 0
    /// Serial of the controller a slot draft was read from. Saving it to a
    /// different controller is refused, so edits for one can't overwrite another.
    private var draftSerial: String?

    // UI state
    var busyMessage: String?
    var errorMessage: String?
    var waitingForDefaultProfile = false
    /// Slot waiting for the user to confirm a reset to defaults.
    var slotPendingReset: Int?
    /// Set while asking the user to confirm resetting every slot.
    var confirmResetAll = false
    /// Slots a reset-all still has to do, waiting for the Default profile,
    /// tied to the controller it was started on.
    private var pendingResetSlots: (slots: [Int], serial: String?)?
    /// A save waiting for the user to switch to the Default profile, tied to
    /// the controller it was meant for.
    private var pendingWrite: (slot: Int, profile: EliteProfile, libraryID: UUID?, serial: String?)?

    private let helper = HelperClient()

    /// Xbox button light while the controller is on its Default profile. The
    /// Default profile can't store a colour, so the helper shows this one
    /// whenever EliteForge holds the controller over USB. nil leaves it white.
    var defaultLight: LightSettings? = AppModel.loadDefaultLight() {
        didSet {
            if let data = try? JSONEncoder().encode(defaultLight) {
                UserDefaults.standard.set(data, forKey: Self.defaultLightKey)
            }
            // Sliders change this many times a second; send the last value.
            defaultLightTask?.cancel()
            defaultLightTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                await sendDefaultLight()
            }
        }
    }
    private var defaultLightTask: Task<Void, Never>?
    private var lightPreviewTask: Task<Void, Never>?
    private var lightPreviewOwner: UUID?
    private static let defaultLightKey = "defaultProfileLight"

    private static func loadDefaultLight() -> LightSettings? {
        guard let data = UserDefaults.standard.data(forKey: defaultLightKey) else { return nil }
        return (try? JSONDecoder().decode(LightSettings?.self, from: data)) ?? nil
    }

    /// The colour the controller's Xbox button shows on the Default profile.
    var defaultLightColor: LightColor? {
        guard let light = defaultLight else { return nil }
        return (light.color ?? LightColor(red: 255, green: 255, blue: 255)).scaled(by: Int(light.brightness))
    }

    private func sendDefaultLight() async {
        guard isConfiguring else { return }
        _ = try? await helper.perform(.setDefaultLight(defaultLightColor))
    }

    /// True while this app is one of the helper's owners of the capture.
    /// The helper's `attached` is global: forgectl may hold the controller
    /// while this app doesn't.
    private(set) var ownsController = false
    var isConfiguring: Bool { ownsController && status.attached }
    /// Set when the user releases the controller for games, until they choose
    /// Reconnect. Releasing resets the controller, which briefly looks like an
    /// unplug, so unplugging doesn't clear it. Otherwise the app holds the
    /// controller whenever it's plugged in.
    var releasedByUser = false
    private var attaching = false
    /// The capture was lost while connecting; try again when that attempt ends.
    private var reconnectAfterAttach = false

    /// Firmware and IDs come from the controller's HELLO, which it only sends
    /// once per power-up, so remember them per serial number.
    var deviceInfo: DeviceInfo? {
        if let info = status.info { return info }
        guard let serial = status.serialNumber,
              let data = UserDefaults.standard.data(forKey: "deviceInfo." + serial) else { return nil }
        return try? JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    private func rememberDeviceInfo(_ status: ControllerStatus) {
        guard let info = status.info, let serial = status.serialNumber,
              let data = try? JSONEncoder().encode(info) else { return }
        UserDefaults.standard.set(data, forKey: "deviceInfo." + serial)
    }

    init() {
        helper.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        helper.onInterrupted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.status.attached { self.status.attached = false }
                self.endSession()
            }
        }
        Task { await checkHelper() }
    }

    // MARK: Helper

    func checkHelper() async {
        helperState = .checking
        do {
            let status = try await helper.status()
            self.status = status
            helperState = status.helperVersion == helperProtocolVersion ? .ready : .outdated(installed: status.helperVersion)
            connectIfPossible()
        } catch {
            helperState = .notInstalled(error.localizedDescription)
        }
    }

    func installHelper() async {
        busyMessage = "Installing helper…"
        defer { busyMessage = nil }
        // Same as uninstall: give the controller back first, and don't let
        // status events reconnect while the helper is being replaced.
        helperState = .checking
        if isConfiguring { await stopConfiguring() }
        endSession()
        do {
            helper.disconnect()
            try await Task.detached { try HelperInstaller.install() }.value
            try await Task.sleep(for: .milliseconds(500))
            await checkHelper()
        } catch {
            errorMessage = error.localizedDescription
            await checkHelper()
        }
    }

    /// Forgets this app's hold on the controller: anything still running or
    /// queued for the old session stops.
    private func endSession() {
        ownsController = false
        sessionGeneration += 1
        cancelPendingWrite()
        input = InputState()
    }

    func uninstallHelper() async {
        do {
            // Not .ready, so the detach's status event doesn't reconnect mid-uninstall.
            helperState = .checking
            if isConfiguring { await stopConfiguring() }
            endSession()
            helper.disconnect()
            try await Task.detached { try HelperInstaller.uninstall() }.value
            await checkHelper()
        } catch {
            errorMessage = error.localizedDescription
            // Cancelled or failed: the helper is still there.
            await checkHelper()
        }
    }

    private func handle(_ event: HelperEvent) {
        switch event {
        case .status(let newStatus):
            let wasAttached = status.attached
            status = newStatus
            rememberDeviceInfo(newStatus)
            if wasAttached, !newStatus.attached {
                // Released or unplugged: a queued save must not land on whatever connects next.
                endSession()
                // Lost during the initial reads: connectIfPossible skips while
                // attaching, so retry once that finishes.
                if attaching { reconnectAfterAttach = true }
            }
            // After clearing ownership, so a capture lost while the controller
            // stays plugged in is retaken.
            connectIfPossible()
            // Resumes run later; a release before then cancels them.
            let generation = sessionGeneration
            if waitingForDefaultProfile, isConfiguring, newStatus.activeSlot == 0, let pending = pendingResetSlots {
                waitingForDefaultProfile = false
                pendingResetSlots = nil
                if pending.serial == newStatus.serialNumber {
                    Task {
                        guard generation == sessionGeneration else { return }
                        await resetSlots(pending.slots)
                    }
                }
            }
            if waitingForDefaultProfile, isConfiguring, newStatus.activeSlot == 0 {
                waitingForDefaultProfile = false
                if let pending = pendingWrite {
                    pendingWrite = nil
                    if pending.serial == newStatus.serialNumber {
                        Task {
                            guard generation == sessionGeneration else { return }
                            await write(pending.profile, toSlot: pending.slot, libraryID: pending.libraryID, expectedSerial: pending.serial)
                        }
                    }
                }
            }
        case .input(let state):
            input = state
        case .trace:
            break
        }
    }

    // MARK: Configuration mode

    /// Captures the controller when it's plugged in, unless the user released it.
    func connectIfPossible() {
        guard canAutoConnect else { return }
        // Checked again when the task runs: a release or helper reinstall
        // may have happened in between.
        Task {
            guard canAutoConnect else { return }
            await startConfiguring()
        }
    }

    private var canAutoConnect: Bool {
        helperState == .ready && status.present && !ownsController && !releasedByUser && !attaching
    }

    /// Takes the controller back after the user released it.
    func reconnect() async {
        releasedByUser = false
        await startConfiguring()
    }

    /// Gives the controller to games until it's unplugged or the user reconnects.
    func releaseForGames() async {
        releasedByUser = true
        await stopConfiguring()
    }

    /// Takes the controller from macOS and reads everything off it.
    func startConfiguring() async {
        guard !attaching else { return }
        attaching = true
        busyMessage = "Connecting to the controller…"
        reconnectAfterAttach = false
        defer {
            busyMessage = nil
            attaching = false
            if reconnectAfterAttach {
                reconnectAfterAttach = false
                connectIfPossible()
            }
        }
        let generation = sessionGeneration
        do {
            guard case .status(let newStatus) = try await helper.perform(.attach) else { return }
            // Released while attaching: don't read, because reading recaptures.
            guard generation == sessionGeneration else { return }
            ownsController = true
            status = newStatus
            if newStatus.serialNumber != slotsSerial {
                // Another controller: its profiles haven't been read yet, so
                // don't show (or let anyone save edits based on) the old ones.
                slots = [:]
                blankSlots = []
                slotsSerial = newStatus.serialNumber
            }
            await sendDefaultLight()
            guard generation == sessionGeneration else { return }
            let name = try await helper.readName()
            guard generation == sessionGeneration else { return }
            controllerName = name
            try await readAllSlots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Gives the controller back to macOS so games can use it again.
    func stopConfiguring() async {
        sessionGeneration += 1
        ownsController = false
        // Queued saves must not resume while the detach is in flight.
        cancelPendingWrite()
        do {
            if case .status(let newStatus) = try await helper.perform(.detach) { status = newStatus }
        } catch {
            errorMessage = error.localizedDescription
        }
        input = InputState()
    }

    /// Bumped when the controller is released, so reads that are still in
    /// progress stop instead of capturing it again.
    private var sessionGeneration = 0

    func readAllSlots() async throws {
        let generation = sessionGeneration
        for slot in 1...3 {
            // Reading attaches through the helper; never do it for a session
            // that isn't ours, such as after Release Controller for Games.
            guard generation == sessionGeneration, isConfiguring, helperState == .ready else { return }
            busyMessage = "Reading profile \(slot)…"
            let pages = try await helper.readSlot(slot)
            guard generation == sessionGeneration else { return }
            if pages.normalMapping.first.map({ $0 & 0x01 == 0 }) ?? false {
                blankSlots.insert(slot)
            } else {
                blankSlots.remove(slot)
            }
            let name = library.slotAssignments[slot].flatMap { id in library.profiles.first { $0.id == id }?.name } ?? "Profile \(slot)"
            var profile = try ProfileCodec.decode(pages, name: name, id: slots[slot]?.id ?? UUID())
            profile.modified = Date()
            slots[slot] = profile
            slotsSerial = status.serialNumber
            if draftSource == .slot(slot), !draftIsDirty {
                draft = profile
                draftRevision += 1
                draftSerial = slotsSerial
            }
        }
    }

    // MARK: Selection and drafts

    func select(_ item: SidebarItem?) {
        selection = item
        switch item {
        case .slot(let slot):
            draft = slots[slot]
            draftSerial = slotsSerial
            draftSource = .slot(slot)
        case .library(let id):
            draft = library.profiles.first { $0.id == id }
            draftSource = .library(id)
        case .controller, nil:
            draft = nil
            draftSource = nil
        }
        draftRevision += 1
        draftIsDirty = false
    }

    func updateDraft(_ change: (inout EliteProfile) -> Void) {
        guard var profile = draft else { return }
        change(&profile)
        profile.modified = Date()
        draft = profile
        draftIsDirty = true
        if case .library(let id) = draftSource { saveLibraryProfile(profile, id: id) }
    }

    func revertDraft() { select(selection) }

    // MARK: Library

    func newProfile() {
        let profile = EliteProfile.factoryDefault(name: uniqueName("New setup"))
        library.profiles.append(profile)
        persistLibrary()
        select(.library(profile.id))
    }

    func duplicate(_ profile: EliteProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName(profile.name + " copy")
        library.profiles.append(copy)
        persistLibrary()
        select(.library(copy.id))
    }

    func addToLibrary(_ profile: EliteProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName(profile.name)
        library.profiles.append(copy)
        persistLibrary()
        select(.library(copy.id))
    }

    func delete(_ id: UUID) {
        library.profiles.removeAll { $0.id == id }
        library.slotAssignments = library.slotAssignments.filter { $0.value != id }
        persistLibrary()
        if selection == .library(id) { select(.controller) }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = library.profiles.firstIndex(where: { $0.id == id }) else { return }
        library.profiles[index].name = name
        persistLibrary()
        if draftSource == .library(id) { draft?.name = name }
    }

    func importProfile(from url: URL) {
        do {
            var profile = try ProfileFile.decode(Data(contentsOf: url))
            profile.name = uniqueName(profile.name)
            library.profiles.append(profile)
            persistLibrary()
            select(.library(profile.id))
        } catch {
            errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func export(_ profile: EliteProfile, to url: URL) {
        do {
            try ProfileFile.encode(profile).write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't export the setup: \(error.localizedDescription)"
        }
    }

    private func saveLibraryProfile(_ profile: EliteProfile, id: UUID) {
        guard let index = library.profiles.firstIndex(where: { $0.id == id }) else { return }
        library.profiles[index] = profile
        persistLibrary()
        draftIsDirty = false
    }

    private func persistLibrary() {
        do { try library.save() } catch { errorMessage = "Couldn't save your library: \(error.localizedDescription)" }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(library.profiles.map(\.name))
        if !names.contains(base) { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    func libraryName(forSlot slot: Int) -> String? {
        library.slotAssignments[slot].flatMap { id in library.profiles.first { $0.id == id }?.name }
    }

    // MARK: Writing to the controller

    /// Saves the draft: to its slot if it came from the controller, otherwise
    /// to the slot chosen by the caller.
    func saveDraft(toSlot slot: Int) async {
        guard let draft else { return }
        var libraryID: UUID?
        if case .library(let id) = draftSource { libraryID = id }
        // Slot edits may only go back to the controller they came from;
        // write() checks that after any reconnect.
        var source: String?
        if case .slot = draftSource { source = draftSerial }
        await write(draft, toSlot: slot, libraryID: libraryID, expectedSerial: source)
    }

    /// `expectedSerial` is the controller the profile is meant for; the write
    /// is refused if a different one is connected. nil writes to whichever is.
    func write(_ profile: EliteProfile, toSlot slot: Int, libraryID: UUID?, expectedSerial: String? = nil) async {
        // Writing captures the controller; a release while this runs must win,
        // including one during the initial connect.
        let generation = sessionGeneration
        if !isConfiguring { await startConfiguring() }
        guard isConfiguring, generation == sessionGeneration else { return }
        if let expectedSerial, expectedSerial != status.serialNumber {
            errorMessage = "These edits were made for a different controller, so they weren't saved to this one. Use More > Add to Library to keep them, or Revert to load this controller's profile."
            return
        }
        let target = expectedSerial ?? status.serialNumber
        if status.activeSlot != 0 {
            pendingWrite = (slot, profile, libraryID, target)
            waitingForDefaultProfile = true
            return
        }
        busyMessage = "Saving to profile \(slot)…"
        defer { busyMessage = nil }
        let pages = ProfileCodec.encode(profile)
        do {
            _ = try await helper.perform(.writeSlot(slot, pages, serial: target))
            // The session ended meanwhile; the next connect reads the slots again.
            guard generation == sessionGeneration else { return }
            var stored = profile
            stored.basePages = pages
            slots[slot] = stored
            blankSlots.remove(slot)
            library.slotAssignments[slot] = libraryID
            persistLibrary()
            if draftSource == .slot(slot) {
                // Saving the draft as it is keeps the editor's state; a reset,
                // or edits made while the save ran, replace the draft.
                if draft != profile { draftRevision += 1 }
                draft = stored
                draftIsDirty = false
                draftSerial = target
            }
        } catch {
            guard generation == sessionGeneration else { return }
            if error.localizedDescription == ControllerError.customProfileActive.errorDescription {
                pendingWrite = (slot, profile, libraryID, target)
                waitingForDefaultProfile = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPendingWrite() {
        pendingWrite = nil
        pendingResetSlots = nil
        waitingForDefaultProfile = false
    }

    func restoreSlotToDefaults(_ slot: Int) async {
        var profile = EliteProfile.factoryDefault(name: "Profile \(slot)")
        profile.id = slots[slot]?.id ?? UUID()
        await write(profile, toSlot: slot, libraryID: nil)
    }

    /// Restores slots 1-3 to factory settings, one after another.
    func resetAllSlots() async {
        await resetSlots([1, 2, 3])
    }

    /// Resets each slot in turn. If the controller leaves its Default profile
    /// part-way, the remaining slots wait and resume once it's back.
    private func resetSlots(_ remaining: [Int]) async {
        let generation = sessionGeneration
        if !isConfiguring { await startConfiguring() }
        guard isConfiguring, generation == sessionGeneration else { return }
        for (index, slot) in remaining.enumerated() {
            // Released part-way: stop instead of recapturing for the next slot.
            guard generation == sessionGeneration else { return }
            if status.activeSlot != 0 {
                pendingResetSlots = (Array(remaining[index...]), status.serialNumber)
                waitingForDefaultProfile = true
                return
            }
            await restoreSlotToDefaults(slot)
            guard generation == sessionGeneration else { return }
            if waitingForDefaultProfile {
                // write() queued this slot on its own; fold it back into the sequence.
                pendingWrite = nil
                pendingResetSlots = (Array(remaining[index...]), status.serialNumber)
                return
            }
            if errorMessage != nil { return }
        }
    }

    func renameController(_ name: String) async {
        busyMessage = "Renaming controller…"
        defer { busyMessage = nil }
        do {
            if status.activeSlot != 0 { throw ControllerError.customProfileActive }
            controllerName = try await helper.writeName(name, serial: status.serialNumber)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Live effects

    /// Shows `light` on the controller's Xbox button, scaled by brightness the
    /// way the Accessories app previews it, until `owner` ends the preview.
    func showLightPreview(_ light: LightSettings, owner: UUID) {
        lightPreviewOwner = owner
        sendLightPreview(light)
    }

    /// Brings back the controller's own light: the Default-profile colour if
    /// one is set and Default is active, else the active profile's. Does
    /// nothing if another view has taken over the preview since.
    func endLightPreview(owner: UUID) {
        guard lightPreviewOwner == owner else { return }
        lightPreviewOwner = nil
        sendLightPreview(nil)
    }

    /// Requests go out in order, and quick changes such as a slider drag
    /// send only the latest.
    private func sendLightPreview(_ light: LightSettings?) {
        let previous = lightPreviewTask
        previous?.cancel()
        lightPreviewTask = Task {
            await previous?.value
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, isConfiguring else { return }
            if let light {
                let base = light.color ?? LightColor(red: 255, green: 255, blue: 255)
                _ = try? await helper.perform(.previewLight(base.scaled(by: Int(light.brightness))))
            } else {
                _ = try? await helper.perform(.endLightPreview)
            }
        }
    }

    func rumble(leftGrip: UInt8 = 0, rightGrip: UInt8 = 0, leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0, seconds: Double = 0.8) async {
        do {
            try await playRumble(leftGrip: leftGrip, rightGrip: rightGrip, leftTrigger: leftTrigger, rightTrigger: rightTrigger, for: .seconds(seconds))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private let rumbles = RumbleSequencer()

    /// Every rumble goes through here, so overlapping ones don't stop each other early.
    private func playRumble(leftGrip: UInt8, rightGrip: UInt8, leftTrigger: UInt8, rightTrigger: UInt8, for duration: Duration) async throws {
        try await rumbles.play(for: duration) {
            _ = try await helper.perform(.rumble(leftGrip: leftGrip, rightGrip: rightGrip, leftTrigger: leftTrigger, rightTrigger: rightTrigger))
        } stop: {
            _ = try await helper.perform(.rumble(leftGrip: 0, rightGrip: 0, leftTrigger: 0, rightTrigger: 0))
        }
    }

    /// Identifies the controller in hand, like the Accessories app's buzz.
    func buzz() async {
        await rumble(leftGrip: 60, rightGrip: 60, leftTrigger: 60, rightTrigger: 60, seconds: 0.5)
    }

    // MARK: Calibration

    func readCalibration(_ target: CalibrationTarget) async throws -> CalibrationReading {
        try await helper.readCalibration(target)
    }

    func startCalibration(_ target: CalibrationTarget) async throws {
        _ = try await helper.perform(.startCalibration(target, serial: status.serialNumber))
    }

    /// A short buzz on all four motors, the way the Accessories app marks
    /// each finished calibration step (10) and the end (30).
    func calibrationPulse(strength: UInt8) async {
        try? await playRumble(leftGrip: strength, rightGrip: strength, leftTrigger: strength, rightTrigger: strength, for: .milliseconds(300))
    }
}

#if DEBUG
extension AppModel {
    /// For `--snapshots`: runs `body` as if the controller were connected and
    /// had a Default profile light, then puts back the stored light.
    func withSnapshotConnection(_ body: () -> Void) {
        let storedLight = UserDefaults.standard.data(forKey: Self.defaultLightKey)
        ownsController = true
        defaultLight = LightSettings(brightness: 80, color: LightColor(red: 0x00, green: 0xD0, blue: 0xFF))
        body()
        UserDefaults.standard.set(storedLight, forKey: Self.defaultLightKey)
    }
}
#endif

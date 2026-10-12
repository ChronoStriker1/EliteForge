import EliteKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.helperState {
            case .ready:
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
                } detail: {
                    detail
                        .toolbarBackground(.hidden, for: .windowToolbar)
                }
            case .checking:
                ProgressView("Looking for the helper…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notInstalled, .outdated:
                HelperSetupView()
            }
        }
        .overlay {
            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .sheet(isPresented: $model.waitingForDefaultProfile) {
            SwitchToDefaultSheet()
        }
        .confirmationDialog(
            "Reset profile \(model.slotPendingReset ?? 0) to default?",
            isPresented: Binding(get: { model.slotPendingReset != nil }, set: { if !$0 { model.slotPendingReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset Profile \(model.slotPendingReset ?? 0)", role: .destructive) {
                if let slot = model.slotPendingReset { Task { await model.restoreSlotToDefaults(slot) } }
                model.slotPendingReset = nil
            }
            Button("Cancel", role: .cancel) { model.slotPendingReset = nil }
        } message: {
            Text("Every button mapping, stick curve, trigger range, vibration and light setting in this profile goes back to the factory default. Setups in your library aren't affected.")
        }
        .confirmationDialog("Reset all three profiles to default?", isPresented: $model.confirmResetAll, titleVisibility: .visible) {
            Button("Reset All Profiles", role: .destructive) { Task { await model.resetAllSlots() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Profiles 1, 2 and 3 on the controller go back to factory settings. Setups in your library aren't affected.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .slot, .library:
            if model.draft != nil {
                ProfileEditorView()
            } else {
                ContentUnavailableView("Connect the controller", systemImage: "gamecontroller", description: Text("Start configuring to read the profiles stored on the controller."))
            }
        case .controller, nil:
            ControllerView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section("Controller") {
                HStack(spacing: 10) {
                    EliteControllerArt(input: model.input, showPaddles: false)
                        .frame(width: 54, height: 38)
                        .opacity(model.status.present ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.controllerName.isEmpty ? "Elite Series 2" : model.controllerName)
                            .font(.headline)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.isConfiguring ? Color.xboxGlow : (model.status.present ? Color.secondary : Color.red.opacity(0.7)))
                                .frame(width: 6, height: 6)
                            Text(controllerSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .tag(SidebarItem.controller)
            }

            Section("On the controller") {
                ForEach(1...3, id: \.self) { slot in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Profile \(slot)")
                            Text(slotSubtitle(slot))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        ProfileLEDs(slot: slot, size: 4)
                            .opacity(model.status.activeSlot == slot ? 1 : 0.55)
                    }
                    .tag(SidebarItem.slot(slot))
                    .contextMenu {
                        Button("Reset to Default…") { model.slotPendingReset = slot }
                            .disabled(!model.isConfiguring)
                    }
                }
            }

            Section("Library") {
                ForEach(model.library.profiles) { profile in
                    Label(profile.name, systemImage: "slider.horizontal.3")
                        .tag(SidebarItem.library(profile.id))
                        .contextMenu {
                            Button("Rename…") {
                                newName = profile.name
                                renaming = profile.id
                            }
                            Button("Duplicate") { model.duplicate(profile) }
                            Button("Export…") { export(profile) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(profile.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ConnectionFooter()
                .padding(10)
        }
        .toolbar {
            ToolbarItem {
                Button { model.newProfile() } label: { Label("New Setup", systemImage: "plus") }
                    .help("New setup")
            }
        }
        .alert("Rename setup", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let id = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { model.rename(id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var controllerSubtitle: String {
        if !model.status.present { return "Not connected over USB" }
        if model.isConfiguring { return "Connected" }
        return model.releasedByUser ? "Released for games" : "Connecting…"
    }

    private func slotSubtitle(_ slot: Int) -> String {
        guard model.isConfiguring || model.slots[slot] != nil else { return "—" }
        if model.blankSlots.contains(slot) { return "Empty" }
        if let name = model.libraryName(forSlot: slot) { return name }
        return model.slots[slot]?.hasDefaultSettings == true ? "Default settings" : "Custom"
    }

    private func export(_ profile: EliteProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProfileFile.fileExtension) ?? .json]
        panel.nameFieldStringValue = profile.name + "." + ProfileFile.fileExtension
        if panel.runModal() == .OK, let url = panel.url { model.export(profile, to: url) }
    }
}

/// Sidebar footer: whether EliteForge currently holds the controller.
struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(model.isConfiguring ? Color.xboxGlow : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.releasedByUser && model.status.present {
                    Button {
                        Task { await model.reconnect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .foregroundStyle(.white)
                    }
                    .glassButton(prominent: true)
                    .tint(.xbox)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassPanel(cornerRadius: 14)
    }

    private var icon: String {
        if !model.status.present { return "cable.connector.slash" }
        return model.isConfiguring ? "gamecontroller.fill" : "pause.circle"
    }

    private var message: String {
        if !model.status.present { return "Plug in the controller with a USB cable." }
        if model.isConfiguring { return "Games can't use the controller while EliteForge is open. Quit to play." }
        if model.releasedByUser { return "Released for games." }
        return "Connecting…"
    }
}

struct HelperSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            EliteControllerArt()
                .frame(maxWidth: 460, maxHeight: 300)
            Text(title)
                .font(.title2.bold())
            Text("macOS's built-in Xbox driver handles gameplay but blocks the commands that change the controller's profiles. EliteForge installs a small helper that borrows the controller over USB while you configure it, then hands it back to macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button(buttonTitle) { Task { await model.installHelper() } }
                .glassButton(prominent: true)
                .tint(.xbox)
                .controlSize(.large)
            Button("Check again") { Task { await model.checkHelper() } }
                .buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBackground())
    }

    private var title: String {
        if case .outdated = model.helperState { return "Update the helper" }
        return "Install the helper"
    }

    private var buttonTitle: String {
        if case .outdated = model.helperState { return "Update Helper…" }
        return "Install Helper…"
    }
}

struct SwitchToDefaultSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            ProfileLEDs(slot: 0, size: 14)
                .padding(14)
                .glassCapsule()
            Text("Switch to Profile 0 (Default)")
                .font(.title3.bold())
            Text("The controller only accepts changes on Profile 0 (Default). Press the profile button on the controller until none of the three profile lights are on. Saving continues automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            ProgressView()
                .controlSize(.small)
            Button("Cancel", role: .cancel) { model.cancelPendingWrite() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
    }
}

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
            }
            .padding(24)
            .glassPanel(cornerRadius: 18)
        }
    }
}

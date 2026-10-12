import EliteKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct EliteForgeApp: App {
    @State private var model = AppModel()

    init() {
        #if DEBUG
        DebugSnapshots.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("EliteForge") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
                .tint(.xbox)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Controller") {
                Button(model.isConfiguring ? "Release Controller for Games" : "Reconnect Controller") {
                    Task {
                        if model.isConfiguring { await model.releaseForGames() } else { await model.reconnect() }
                    }
                }
                .keyboardShortcut("k")
                .disabled(!model.status.present && !model.isConfiguring)
                Button("Reload Profiles from Controller") {
                    Task {
                        do { try await model.readAllSlots() } catch { model.errorMessage = error.localizedDescription }
                        model.busyMessage = nil
                    }
                }
                .keyboardShortcut("r")
                .disabled(!model.isConfiguring)
                Divider()
                Button("Reset All Profiles to Defaults…") { model.confirmResetAll = true }
                    .disabled(!model.isConfiguring)
            }
            CommandGroup(after: .newItem) {
                Button("New Setup") { model.newProfile() }
                    .keyboardShortcut("n")
                Button("Import Setup…") { importProfile() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.xbox)
        }
    }

    @MainActor
    private func importProfile() {
        let panel = NSOpenPanel()
        let extensions = [ProfileFile.fileExtension] + ProfileFile.legacyFileExtensions
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) } + [UTType.json]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { model.importProfile(from: url) }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Helper") {
                LabeledContent("Status", value: helperDescription)
                HStack {
                    Button("Reinstall Helper…") { Task { await model.installHelper() } }
                    Button("Remove Helper…") { Task { await model.uninstallHelper() } }
                }
                Text("The helper runs as root only while the app talks to it. It takes the controller from macOS during configuration and gives it back when you're done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Credits") {
                Text("Controller outline traced from “Xbox One Elite Wireless Controller Series 2 (Model 1797)” by mliu92, CC BY-SA 2.0.")
                    .font(.callout)
                Link("Photo on Flickr", destination: URL(string: "https://www.flickr.com/photos/mliu92/50621965382/")!)
                Text("Protocol research builds on lemonxah/xbelite2.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    private var helperDescription: String {
        switch model.helperState {
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .outdated(let version): "Out of date (version \(version))"
        case .ready: "Installed"
        }
    }
}

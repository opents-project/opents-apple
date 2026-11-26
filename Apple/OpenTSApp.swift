import SwiftUI

@main
struct OpenTSApp: App {
    @StateObject private var model = ServerModel()
    #if os(macOS)
    @StateObject private var updater = AppUpdater()
    @AppStorage(ChannelTreeDensity.storageKey) private var channelTreeDensity = ChannelTreeDensity.standard
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("OpenTS", id: "main") { ServerView(model: model) }
        .defaultSize(width: 820, height: 540)
        .commands {
            CommandGroup(after: .appInfo) { UpdateMenuItem(updater: updater) }
            CommandGroup(after: .sidebar) {
                Toggle("Standard Channel Spacing", isOn: channelSpacingChoice(.standard))
                    .keyboardShortcut("=", modifiers: .command)
                Toggle("Compact Channel Spacing", isOn: channelSpacingChoice(.compact))
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
        MenuBarExtra("OpenTS", systemImage: model.server.isEmpty ? "waveform" : "waveform.circle.fill") {
            StatusMenu(model: model, updater: updater)
        }
        #else
        WindowGroup { ServerView(model: model) }
        #endif
    }

    #if os(macOS)
    private func channelSpacingChoice(_ choice: ChannelTreeDensity) -> Binding<Bool> {
        Binding(get: { channelTreeDensity == choice }, set: { _ in channelTreeDensity = choice })
    }
    #endif
}

#if os(macOS)
private struct StatusMenu: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.reconnecting { Text("Reconnecting…") }
        else if model.active { if model.server.isEmpty { Text("Connecting…") } else { Text(verbatim: model.server) } }
        Button(model.active ? "Show OpenTS" : "Connect…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.active && model.server.isEmpty ? "Cancel Connection" : "Disconnect", action: model.disconnect)
            .disabled(!model.active)
        Divider()
        VoiceMenu(audio: model.audio).disabled(model.server.isEmpty || model.reconnecting)
        Divider()
        UpdateMenuItem(updater: updater)
        Button("Quit OpenTS") { model.disconnect(); NSApp.terminate(nil) }
    }
}
#endif

import SwiftUI

@main
struct OpenTSApp: App {
    @StateObject private var model = ServerModel()
    var body: some Scene {
        #if os(macOS)
        Window("OpenTS", id: "main") { ServerView(model: model) }
        .defaultSize(width: 820, height: 540)
        MenuBarExtra("OpenTS", systemImage: model.server.isEmpty ? "waveform" : "waveform.circle.fill") {
            StatusMenu(model: model)
        }
        #else
        WindowGroup { ServerView(model: model) }
        #endif
    }
}

#if os(macOS)
private struct StatusMenu: View {
    @ObservedObject var model: ServerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.active { Text(model.server.isEmpty ? "Connecting…" : model.server) }
        Button(model.active ? "Show OpenTS" : "Connect…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.active && model.server.isEmpty ? "Cancel Connection" : "Disconnect", action: model.disconnect)
            .disabled(!model.active)
        Divider()
        VoiceMenu(audio: model.audio).disabled(model.server.isEmpty)
        Divider()
        Button("Quit OpenTS") { model.disconnect(); NSApp.terminate(nil) }
    }
}
#endif

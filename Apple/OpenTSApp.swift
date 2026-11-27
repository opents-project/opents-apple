import SwiftUI

@main
struct OpenTSApp: App {
    @StateObject private var tabs = ServerTabs()
    #if os(macOS)
    @StateObject private var updater = AppUpdater()
    @AppStorage(ChannelTreeDensity.storageKey) private var channelTreeDensity = ChannelTreeDensity.standard
    @AppStorage(ServerBookmark.storageKey) private var bookmarkData = Data()
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("OpenTS", id: "main") { ServerTabsView(tabs: tabs) }
        .defaultSize(width: 820, height: 540)
        .commands {
            CommandGroup(after: .appInfo) { UpdateMenuItem(updater: updater) }
            CommandGroup(after: .sidebar) {
                Toggle("Standard Channel Spacing", isOn: channelSpacingChoice(.standard))
                    .keyboardShortcut("=", modifiers: .command)
                Toggle("Compact Channel Spacing", isOn: channelSpacingChoice(.compact))
                    .keyboardShortcut("-", modifiers: .command)
            }
            CommandMenu("Connections") {
                Button("Connect…") { tabs.requestConnection(forceNewTab: tabs.hasActiveConnection) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Disconnect from Current") { tabs.disconnect(tabs.selected.model) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!tabs.selected.model.active)
                Button("Disconnect from All", action: tabs.disconnectAll)
                    .disabled(!tabs.hasActiveConnection)
            }
            CommandMenu("Bookmarks") {
                let bookmarks = ServerBookmark.saved(from: bookmarkData)
                if bookmarks.isEmpty { Button("No Bookmarks") {}.disabled(true) }
                ForEach(bookmarks) { bookmark in
                    Button { tabs.connect(to: bookmark) } label: { Text(verbatim: bookmark.name) }
                }
            }
            PermissionCommands(tabs: tabs)
        }
        Window("Permissions", id: PermissionDirectoryWindow.windowID) {
            PermissionDirectoryWindow(tabs: tabs)
        }
        .defaultSize(width: 1080, height: 620)
        MenuBarExtra("OpenTS", systemImage: tabs.hasActiveConnection ? "waveform.circle.fill" : "waveform") {
            StatusMenu(tabs: tabs, model: tabs.selected.model, updater: updater)
        }
        #else
        WindowGroup { MobileServerTabsView(tabs: tabs) }
        #endif
    }

    #if os(macOS)
    private func channelSpacingChoice(_ choice: ChannelTreeDensity) -> Binding<Bool> {
        Binding(get: { channelTreeDensity == choice }, set: { _ in channelTreeDensity = choice })
    }
    #endif
}

#if os(macOS)
private struct PermissionCommands: Commands {
    @ObservedObject var tabs: ServerTabs
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Group permissions", action: show)
                .disabled(tabs.selected.model.groupPermissionSession == nil)
        }
    }

    private func show() {
        guard tabs.requestPermissionDirectory() else { return }
        openWindow(id: PermissionDirectoryWindow.windowID)
    }
}

private struct StatusMenu: View {
    @ObservedObject var tabs: ServerTabs
    @ObservedObject var model: ServerModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.reconnecting { Text("Reconnecting…") }
        else if model.active { if model.server.isEmpty { Text("Connecting…") } else { Text(verbatim: model.server) } }
        Button("Show OpenTS", action: showWindow)
        Button("Connect…") {
            tabs.requestConnection(forceNewTab: tabs.hasActiveConnection)
            showWindow()
        }
        Button(model.active && model.server.isEmpty ? "Cancel Connection" : "Disconnect") { tabs.disconnect(model) }
            .disabled(!model.active)
        Divider()
        VoiceMenu(audio: model.audio).disabled(model.server.isEmpty || model.reconnecting)
        Divider()
        UpdateMenuItem(updater: updater)
        Button("Quit OpenTS") { tabs.disconnectAll(); NSApp.terminate(nil) }
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

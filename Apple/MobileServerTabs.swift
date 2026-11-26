#if os(iOS)
import SwiftUI

struct MobileServerTabsView: View {
    @ObservedObject var tabs: ServerTabs

    var body: some View {
        ZStack {
            ForEach(tabs.entries) { tab in
                let selected = tab.id == tabs.selected.id
                ServerView(model: tab.model, tabSelected: selected, mobileTabs: tabs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(selected)
                    .disabled(!selected)
                    .accessibilityHidden(!selected)
                    .zIndex(selected ? 1 : 0)
            }
        }
        .sheet(item: $tabs.connection) { draft in
            ServerConnectionSheet(draft: draft, connect: tabs.connect)
        }
    }
}

extension View {
    @ViewBuilder
    func mobileServerConnectionToolbar(tabs: ServerTabs?, navigationTitle: String = "", subtitle: String? = nil) -> some View {
        if let tabs {
            if #available(iOS 27.1, *) {
                modifier(AdaptiveConnectionToolbar(tabs: tabs, title: navigationTitle, subtitle: subtitle))
            } else {
                self.navigationTitle(navigationTitle).toolbar {
                    ToolbarItem(placement: .principal) {
                        MobileServerConnectionMenu(tabs: tabs, subtitle: subtitle)
                    }
                }
            }
        } else {
            self.navigationTitle(navigationTitle)
        }
    }
}

@available(iOS 27.1, *)
private struct AdaptiveConnectionToolbar: ViewModifier {
    let tabs: ServerTabs
    let title: String
    let subtitle: String?
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    func body(content: Content) -> some View {
        if verticalEdge != nil {
            content.navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        MobileServerConnectionMenu(tabs: tabs, iconOnly: true)
                    }
                    .axisBehavior(.verticalPreferred)
                }
        } else {
            content.navigationTitle(title).toolbar {
                ToolbarItem(placement: .principal) {
                    MobileServerConnectionMenu(tabs: tabs, subtitle: subtitle)
                }
            }
        }
    }
}

struct MobileServerConnectionMenu: View {
    @ObservedObject var tabs: ServerTabs
    var subtitle: String? = nil
    var iconOnly = false

    var body: some View {
        let selected = tabs.selected
        let title = tabs.label(for: selected).title
        Menu {
            if tabs.entries.count > 1 {
                Section("Connections") {
                    ForEach(tabs.entries) { tab in
                        let label = tabs.label(for: tab)
                        Button {
                            tabs.select(tab)
                        } label: {
                            Label {
                                Text(verbatim: label.subtitle.map { "\(label.title) · \($0)" } ?? label.title)
                            } icon: {
                                Image(systemName: tab.id == selected.id ? "checkmark" : "server.rack")
                            }
                        }
                    }
                }
            }
            Section {
                Button("New Connection", systemImage: "plus") { tabs.requestConnection() }
                Button("Disconnect from Current", systemImage: "bolt.horizontal.circle") {
                    selected.model.disconnect()
                }
                .disabled(!selected.model.active)
                if tabs.entries.count > 1 {
                    Button("Disconnect from All", systemImage: "bolt.slash") { tabs.disconnectAll() }
                        .disabled(!tabs.hasActiveConnection)
                    Button("Remove Connection", systemImage: "xmark", role: .destructive) { tabs.close(selected) }
                }
            } header: {
                if iconOnly { Text(verbatim: title) }
            }
        } label: {
            if iconOnly {
                Label("Connections", systemImage: "server.rack")
                    .accessibilityValue(Text(verbatim: title))
            } else {
                HStack(spacing: 5) {
                    VStack(spacing: 1) {
                        Text(verbatim: title).font(.headline).lineLimit(1)
                        if let subtitle, subtitle != title {
                            Text(verbatim: subtitle).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
        }
        .accessibilityHint("Connections")
    }
}

struct MobileServerConnectionsSection: View {
    @ObservedObject var tabs: ServerTabs
    var showsAudioControls = false

    var body: some View {
        Section {
            ForEach(tabs.entries) { tab in
                connectionRow(tab)
            }
        } header: {
            HStack {
                Text("Connections")
                Spacer()
                Button("New Connection", systemImage: "plus") {
                    tabs.requestConnection(forceNewTab: true)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
    }

    private func connectionRow(_ tab: ServerTabs.Tab) -> some View {
        let label = tabs.label(for: tab)
        let selected = tabs.selected.id == tab.id
        let model = tab.model
        return HStack(spacing: 2) {
            Button {
                tabs.select(tab)
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if model.reconnecting || (model.active && model.server.isEmpty) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "server.rack")
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        }
                    }
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: label.title).fontWeight(selected ? .semibold : .regular)
                        if let subtitle = label.subtitle {
                            Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.unreadChat {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                            .accessibilityLabel("Unread Messages")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(Text(model.reconnecting ? "Reconnecting…" : model.active ? "Connected" : "Disconnected"))
            if showsAudioControls {
                MobileConnectionAudioActions(audio: model.audio,
                                             connectionName: label.subtitle.map { "\(label.title) · \($0)" } ?? label.title,
                                             reconnecting: model.reconnecting)
            }
        }
        .frame(minHeight: showsAudioControls ? 48 : 44)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .selectionDisabled()
        .contextMenu {
            Button("Disconnect", systemImage: "bolt.horizontal.circle", action: model.disconnect)
                .disabled(!model.active)
            Button("Remove Connection", systemImage: "xmark", role: .destructive) { tabs.close(tab) }
        }
    }
}

private struct MobileConnectionAudioActions: View {
    @ObservedObject var audio: VoiceAudio
    let connectionName: String
    let reconnecting: Bool

    var body: some View {
        let available = audio.voice != nil && !reconnecting
        let microphone = audio.microphoneEnabledForTab
        let output = audio.outputEnabledForTab
        Button {
            Task { await audio.setMicrophone(!microphone) }
        } label: {
            Image(systemName: available ? (microphone ? "mic.fill" : "mic.slash.fill") : "mic.badge.xmark")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(available ? (microphone ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.55))
        .accessibilityLabel(available ? Text(microphone ? "Mute Microphone" : "Enable Microphone") : Text("Microphone unavailable"))
        .accessibilityHint(Text("Connection: \(connectionName)"))
        .disabled(!available)

        Button(action: audio.toggleOutput) {
            Image(systemName: available ? (output ? "speaker.wave.2.fill" : "speaker.slash.fill") : "speaker.slash")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(available ? (output ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.55))
        .accessibilityLabel(available ? Text(output ? "Mute Output" : "Enable Output") : Text("Output unavailable"))
        .accessibilityHint(Text("Connection: \(connectionName)"))
        .disabled(!available)
    }
}
#endif

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
        return Button {
            tabs.select(tab)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: label.title).fontWeight(selected ? .semibold : .regular)
                        if let subtitle = label.subtitle {
                            Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                } icon: {
                    if tab.model.reconnecting || (tab.model.active && tab.model.server.isEmpty) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "server.rack")
                            .foregroundStyle(tab.model.active ? Color.accentColor : Color.secondary)
                    }
                }
                Spacer()
                if tab.model.unreadChat {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .accessibilityLabel("Unread Messages")
                }
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Disconnect", systemImage: "bolt.horizontal.circle", action: tab.model.disconnect)
                .disabled(!tab.model.active)
            Button("Remove Connection", systemImage: "xmark", role: .destructive) { tabs.close(tab) }
        }
    }
}
#endif

#if os(macOS)
import Combine
import SwiftUI

@MainActor
final class ServerTabs: ObservableObject {
    struct Tab: Identifiable {
        let id = UUID()
        let model: ServerModel
    }

    struct Connection: Identifiable {
        let id = UUID()
        let sourceID: Tab.ID
        let opensNewTab: Bool
        let canReplace: Bool
        var address: String
        var nickname: String
        var identityUID: String?
    }

    @Published private(set) var entries: [Tab]
    @Published private(set) var selected: Tab
    @Published var connection: Connection?
    private var observers: [Tab.ID: AnyCancellable] = [:]

    var hasActiveConnection: Bool { entries.contains { $0.model.active } }

    init() {
        let tab = Tab(model: ServerModel())
        entries = [tab]
        selected = tab
        observe(tab)
    }

    func select(_ tab: Tab) {
        guard selected.id != tab.id, entries.contains(where: { $0.id == tab.id }) else { return }
        selected.model.setTabSelected(false)
        tab.model.setTabSelected(true)
        selected = tab
    }

    func close(_ tab: Tab) {
        guard entries.count > 1, let index = entries.firstIndex(where: { $0.id == tab.id }) else { return }
        if selected.id == tab.id {
            let next = index + 1 < entries.count ? index + 1 : index - 1
            select(entries[next])
        }
        tab.model.disconnect()
        observers[tab.id] = nil
        entries.remove(at: index)
    }

    func requestConnection(forceNewTab: Bool = false) {
        connection = makeConnection(forceNewTab: forceNewTab)
    }

    func connect(to bookmark: ServerBookmark) {
        var draft = makeConnection(forceNewTab: hasActiveConnection)
        draft.address = bookmark.address
        draft.nickname = bookmark.nickname
        connect(draft, inNewTab: draft.opensNewTab)
    }

    func connect(_ draft: Connection, inNewTab: Bool) {
        let model: ServerModel
        if inNewTab || selected.id != draft.sourceID {
            let tab = Tab(model: ServerModel())
            tab.model.setTabSelected(false)
            entries.append(tab)
            observe(tab)
            select(tab)
            model = tab.model
        } else {
            model = selected.model
            if model.active { model.disconnect() }
        }
        model.address = draft.address
        model.nickname = draft.nickname
        model.selectedIdentityUID = draft.identityUID
        connection = nil
        model.connect()
    }

    func disconnectAll() {
        for tab in entries { tab.model.disconnect() }
    }

    func label(for tab: Tab) -> (title: String, subtitle: String?) {
        let title = baseTitle(for: tab)
        let matching = entries.filter { baseTitle(for: $0) == title }
        guard matching.count > 1 else { return (title, nil) }

        let place = tab.model.currentRoom?.name ?? tab.model.nickname
        let samePlace = matching.filter { ($0.model.currentRoom?.name ?? $0.model.nickname) == place }
        guard samePlace.count > 1 else { return (title, place) }

        let nickname = tab.model.nickname
        let sameNickname = samePlace.filter { $0.model.nickname == nickname }
        if sameNickname.count > 1, let index = sameNickname.firstIndex(where: { $0.id == tab.id }) {
            let nicknameOrPlace = place == nickname ? place : "\(place) · \(nickname)"
            return (title, "\(nicknameOrPlace) · \(index + 1)")
        }
        return (title, place == nickname ? place : "\(place) · \(nickname)")
    }

    private func baseTitle(for tab: Tab) -> String {
        let model = tab.model
        if !model.server.isEmpty { return model.server }
        let address = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? String(localized: "Connect…") : address
    }

    private func makeConnection(forceNewTab: Bool) -> Connection {
        let model = selected.model
        return Connection(sourceID: selected.id, opensNewTab: forceNewTab || model.active, canReplace: model.active,
                          address: model.address, nickname: model.nickname, identityUID: model.selectedIdentityUID)
    }

    private func observe(_ tab: Tab) {
        observers[tab.id] = tab.model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

struct ServerTabsView: View {
    @ObservedObject var tabs: ServerTabs

    var body: some View {
        ZStack {
            ForEach(tabs.entries) { tab in
                let selected = tab.id == tabs.selected.id
                ServerView(model: tab.model, tabSelected: selected,
                           connections: tabs.entries.count > 1 ? ServerConnectionsSection(tabs: tabs) : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(selected)
                    .disabled(!selected)
                    .accessibilityHidden(!selected)
                    .zIndex(selected ? 1 : 0)
            }
        }
        .navigationTitle(tabs.selected.model.windowTitle)
        .sheet(item: $tabs.connection) { draft in
            ServerConnectionSheet(draft: draft, connect: tabs.connect)
        }
    }
}

struct ServerConnectionsSection: View {
    @ObservedObject var tabs: ServerTabs

    var body: some View {
        Section {
            ForEach(tabs.entries) { tab in
                let label = tabs.label(for: tab)
                let selected = tab.id == tabs.selected.id
                ServerConnectionRow(title: label.title, subtitle: label.subtitle, model: tab.model, selected: selected) {
                    tabs.select(tab)
                }
                .selectionDisabled()
                .contextMenu {
                    let disconnectTitle: LocalizedStringKey = tab.model.active && tab.model.server.isEmpty
                        ? "Cancel Connection" : "Disconnect"
                    Button(disconnectTitle, systemImage: "bolt.horizontal.circle", action: tab.model.disconnect)
                        .disabled(!tab.model.active)
                    Button("Remove Connection", systemImage: "xmark", role: .destructive) { tabs.close(tab) }
                }
            }
        } header: {
            HStack {
                Text("Connections")
                Spacer()
                Button {
                    tabs.requestConnection(forceNewTab: true)
                } label: {
                    Label("New Connection", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Connection")
            }
        }
    }
}

private struct ServerConnectionRow: View {
    let title: String
    let subtitle: String?
    @ObservedObject var model: ServerModel
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                connectionIcon.frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).fontWeight(selected ? .semibold : .regular)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                if model.unreadChat {
                    Circle().fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(subtitle.map { "\(title) · \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(status)
    }

    @ViewBuilder
    private var connectionIcon: some View {
        if model.reconnecting || (model.active && model.server.isEmpty) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
                .frame(height: 14)
        } else {
            Image(systemName: model.error == nil ? "server.rack" : "exclamationmark.circle")
                .foregroundStyle(model.active ? Color.accentColor : Color.secondary)
        }
    }

    private var status: Text {
        if model.reconnecting { return Text("Reconnecting…") }
        if model.active && model.server.isEmpty { return Text("Connecting…") }
        if let error = model.error { return Text(verbatim: error) }
        if !model.active { return Text("Disconnected") }
        if model.unreadChat { return Text("Unread Messages") }
        return Text(verbatim: "")
    }
}

private struct ServerConnectionSheet: View {
    @State var draft: ServerTabs.Connection
    let connect: (ServerTabs.Connection, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var managingIdentities = false

    private var canConnect: Bool {
        ![draft.address, draft.nickname].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connect to a server") {
                    TextField("Address or server nickname", text: $draft.address)
                        .autocorrectionDisabled()
                    TextField("Your nickname", text: $draft.nickname)
                    Button("Identities", systemImage: "person.text.rectangle") { managingIdentities = true }
                        .sheet(isPresented: $managingIdentities) { IdentityImportView(selectedUID: $draft.identityUID) }
                }
                BookmarkSection(address: $draft.address, nickname: $draft.nickname)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if draft.canReplace {
                    Button("Replace Current Connection") { connect(draft, false) }
                        .disabled(!canConnect)
                }
                Button {
                    connect(draft, draft.opensNewTab)
                } label: {
                    if draft.opensNewTab { Text("New Connection") }
                    else { Text("Connect") }
                }
                .disabled(!canConnect)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 360)
    }
}
#endif

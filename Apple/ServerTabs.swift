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
    #if os(macOS)
    struct PermissionDirectory: Identifiable {
        let id = UUID()
        let session: Session
        let generation: UInt64
        let server: String
    }

    @Published var permissionDirectory: PermissionDirectory?
    private var audioLease: (token: UUID, target: Tab)?
    #endif

    var hasActiveConnection: Bool { entries.contains { $0.model.active } }

    init() {
        let tab = Tab(model: ServerModel())
        entries = [tab]
        selected = tab
        observe(tab)
    }

    func select(_ tab: Tab) {
        guard selected.id != tab.id, entries.contains(where: { $0.id == tab.id }) else { return }
        #if os(macOS)
        finishAudioLease(restoreSelection: false)
        #endif
        selected.model.setTabSelected(false)
        tab.model.setTabSelected(true)
        selected = tab
    }

    func close(_ tab: Tab) {
        guard entries.count > 1, let index = entries.firstIndex(where: { $0.id == tab.id }) else { return }
        if selected.id == tab.id {
            let next = index + 1 < entries.count ? index + 1 : index - 1
            select(entries[next])
        } else {
            #if os(macOS)
            finishAudioLease()
            #endif
        }
        tab.model.disconnect()
        observers[tab.id] = nil
        entries.remove(at: index)
    }

    func requestConnection(forceNewTab: Bool = false) {
        #if os(macOS)
        finishAudioLease()
        #endif
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
            #if os(macOS)
            finishAudioLease()
            #endif
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
        #if os(macOS)
        finishAudioLease(restoreSelection: false)
        #endif
        for tab in entries { tab.model.disconnect() }
        #if os(macOS)
        selected.model.audio.setTabSelected(true)
        #endif
    }

    #if os(macOS)
    func requestPermissionDirectory() -> Bool {
        let model = selected.model
        guard let session = model.groupPermissionSession else { return false }
        if let permissionDirectory, permissionDirectory.session === session,
           permissionDirectory.generation == model.groupPermissionGeneration { return true }
        permissionDirectory = PermissionDirectory(session: session, generation: model.groupPermissionGeneration,
                                                   server: model.server)
        return true
    }

    func leaseAudio(for tab: Tab) -> UUID? {
        guard audioLease == nil, entries.contains(where: { $0.id == tab.id }),
              tab.model.active, !tab.model.server.isEmpty else { return nil }
        let token = UUID()
        audioLease = (token, tab)
        if selected.id != tab.id {
            selected.model.audio.setTabSelected(false)
            tab.model.audio.setTabSelected(true)
        }
        return token
    }

    func ownsAudioLease(_ token: UUID) -> Bool { audioLease?.token == token }

    func releaseAudio(_ token: UUID) {
        guard ownsAudioLease(token) else { return }
        finishAudioLease()
    }

    func disconnect(_ model: ServerModel) {
        let disconnectsSelection = model === selected.model
        finishAudioLease(restoreSelection: !disconnectsSelection)
        model.disconnect()
        if disconnectsSelection { model.audio.setTabSelected(true) }
    }

    private func finishAudioLease(restoreSelection: Bool = true) {
        guard let lease = audioLease else { return }
        audioLease = nil
        lease.target.model.audio.press(false)
        if selected.id != lease.target.id {
            lease.target.model.audio.setTabSelected(false)
            if restoreSelection { selected.model.audio.setTabSelected(true) }
        }
    }
    #endif

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

#if os(macOS)
struct ServerTabsView: View {
    @ObservedObject var tabs: ServerTabs

    var body: some View {
        ZStack {
            ForEach(tabs.entries) { tab in
                let selected = tab.id == tabs.selected.id
                ServerView(model: tab.model, tabSelected: selected, tabs: tabs,
                           connections: tabs.entries.count > 1 || tab.model.active
                               ? ServerConnectionsSection(tabs: tabs, showsChannelTree: !tab.model.server.isEmpty)
                               : nil)
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
    let showsChannelTree: Bool

    var body: some View {
        Section {
            ForEach(tabs.entries) { tab in
                let label = tabs.label(for: tab)
                let selected = tab.id == tabs.selected.id
                ServerConnectionRow(title: label.title, subtitle: label.subtitle ?? tab.model.currentRoom?.name,
                                    model: tab.model, audio: tab.model.audio, selected: selected,
                                    showsChannelTree: showsChannelTree) {
                    tabs.select(tab)
                }
                .selectionDisabled()
                .contextMenu {
                    if tab.model.audio.voice != nil && !tab.model.reconnecting {
                        ConnectionAudioActions(audio: tab.model.audio, inMenu: true)
                        Divider()
                    }
                    let disconnectTitle: LocalizedStringKey = tab.model.active && tab.model.server.isEmpty
                        ? "Cancel Connection" : "Disconnect"
                    Button(disconnectTitle, systemImage: "bolt.horizontal.circle") { tabs.disconnect(tab.model) }
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
    @ObservedObject var audio: VoiceAudio
    let selected: Bool
    let showsChannelTree: Bool
    let open: () -> Void
    private var leadingExpansion: CGFloat { showsChannelTree ? 16 : 6 }

    var body: some View {
        HStack(spacing: 5) {
            Button(action: open) {
                HStack(spacing: 8) {
                    connectionIcon.frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title)
                            .font(.body)
                            .fontWeight(selected ? .semibold : .regular)
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if model.unreadChat {
                        Circle().fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(subtitle.map { "\(title) · \($0)" } ?? title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(status)
            if audio.voice != nil && !model.reconnecting {
                ConnectionAudioActions(audio: audio)
            }
        }
        .frame(height: 36)
        // Match the channel highlight across the disclosure inset and trailing spacing.
        .padding(.leading, leadingExpansion)
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                .padding(.vertical, 2)
        }
        .padding(.leading, -leadingExpansion)
        .padding(.trailing, -6)
    }

    @ViewBuilder
    private var connectionIcon: some View {
        if model.reconnecting || (model.active && model.server.isEmpty) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
                .frame(height: 14)
        } else {
            Image(systemName: model.error == nil ? "server.rack" : "exclamationmark.circle")
                // Connection rows keep standard sizing even when the channel list is compact.
                .font(.system(size: 13))
                .imageScale(.medium)
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

private struct ConnectionAudioActions: View {
    @ObservedObject var audio: VoiceAudio
    var inMenu = false

    var body: some View {
        let microphone = audio.microphoneEnabledForTab
        let output = audio.outputEnabledForTab
        action(microphone ? "Mute Microphone" : "Enable Microphone", icon: microphone ? "mic" : "mic.slash", enabled: microphone) {
            Task { await audio.setMicrophone(!microphone) }
        }
        action(output ? "Mute Output" : "Enable Output", icon: output ? "speaker.wave.2" : "speaker.slash", enabled: output) {
            audio.toggleOutput()
        }
    }

    @ViewBuilder
    private func action(_ title: LocalizedStringKey, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        if inMenu {
            Button(title, systemImage: icon, action: perform)
        } else {
            Button(action: perform) {
                Label(title, systemImage: icon)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(enabled ? Color.secondary : Color.primary)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(Text(title))
        }
    }
}

#endif

struct ServerConnectionSheet: View {
    @State var draft: ServerTabs.Connection
    let connect: (ServerTabs.Connection, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var managingIdentities = false

    private var canConnect: Bool {
        ![draft.address, draft.nickname].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Connect…")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                    ToolbarItem(placement: .confirmationAction) { connectButton }
                }
        }
        #else
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                cancelButton
                Spacer()
                if draft.canReplace { replaceButton }
                connectButton
            }
            .padding(14)
        }
        .frame(width: 480, height: 360)
        #endif
    }

    private var form: some View {
        Form {
            Section("Connect to a server") {
                TextField("Address or server nickname", text: $draft.address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Your nickname", text: $draft.nickname)
                Button("Identities", systemImage: "person.text.rectangle") { managingIdentities = true }
                    .sheet(isPresented: $managingIdentities) { IdentityImportView(selectedUID: $draft.identityUID) }
            }
            BookmarkSection(address: $draft.address, nickname: $draft.nickname)
            #if os(iOS)
            if draft.canReplace { Section { replaceButton } }
            #endif
        }
        .formStyle(.grouped)
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
    }

    private var replaceButton: some View {
        Button("Replace Current Connection") { connect(draft, false) }
            .disabled(!canConnect)
    }

    private var connectButton: some View {
        let title: LocalizedStringKey = draft.opensNewTab ? "New Connection" : "Connect"
        return Button(title) { connect(draft, draft.opensNewTab) }
            .disabled(!canConnect)
            .keyboardShortcut(.defaultAction)
    }
}

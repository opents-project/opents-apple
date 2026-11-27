import SwiftUI

struct ServerView: View {
    @ObservedObject var model: ServerModel
    var tabSelected = true
    #if os(macOS)
    var tabs: ServerTabs? = nil
    var connections: ServerConnectionsSection? = nil
    @AppStorage(ChannelTreeDensity.storageKey) private var channelTreeDensity = ChannelTreeDensity.standard
    #else
    var mobileTabs: ServerTabs? = nil
    @Environment(\.horizontalSizeClass) private var widthClass
    #endif
    #if DEBUG
    @State private var showingFilesPreview = false
    @State private var showingLogPreview = false
    #endif
    #if DEBUG && os(macOS)
    @State private var showingPermissionPreview = false
    #endif
    @State private var managingIdentities = false
    @State private var testingMicrophone = false

    var body: some View {
        if model.server.isEmpty {
            #if os(macOS)
            if let connections {
                NavigationSplitView {
                    List { connections }
                        .listStyle(.sidebar)
                        .environment(\.sidebarRowSize, channelTreeDensity == .compact ? .small : .medium)
                        .toolbar(removing: .sidebarToggle)
                        .navigationSplitViewColumnWidth(min: 170, ideal: 245, max: 440)
                } detail: {
                    connectionForm
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                connectionForm
            }
            #else
            if let mobileTabs, mobileTabs.entries.count > 1 {
                if UIDevice.current.userInterfaceIdiom == .pad && widthClass == .regular {
                    NavigationSplitView {
                        List { MobileServerConnectionsSection(tabs: mobileTabs) }
                            .listStyle(.sidebar)
                            .navigationSplitViewColumnWidth(min: 170, ideal: 245, max: 440)
                    } detail: {
                        mobileConnectionForm(tabs: mobileTabs)
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    NavigationStack { mobileConnectionForm(tabs: mobileTabs) }
                }
            } else {
                connectionForm
            }
            #endif
        } else {
            #if os(macOS)
            ConnectedServerView(model: model, tabSelected: tabSelected, tabs: tabs, connections: connections)
            #else
            ConnectedServerView(model: model, tabSelected: tabSelected, mobileTabs: mobileTabs)
            #endif
        }
    }

    #if os(iOS)
    private func mobileConnectionForm(tabs: ServerTabs) -> some View {
        connectionForm
            .navigationBarTitleDisplayMode(.inline)
            .mobileServerConnectionToolbar(tabs: tabSelected ? tabs : nil)
    }
    #endif

    private var connectionForm: some View {
        Form {
            Section("Connect to a server") {
                TextField("Address or server nickname", text: $model.address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Your nickname", text: $model.nickname)
                #if os(iOS)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                #endif
                Button("Microphone test", systemImage: "mic") { testingMicrophone = true }
                    .sheet(isPresented: $testingMicrophone) { MicrophoneTestView() }
                Button("Identities", systemImage: "person.text.rectangle") { managingIdentities = true }
                    .sheet(isPresented: $managingIdentities) { IdentityImportView(selectedUID: $model.selectedIdentityUID) }
            }
            .disabled(model.active)
            if model.active {
                ProgressView(model.reconnecting ? "Reconnecting…" : "Connecting…")
                Button("Cancel", action: model.disconnect)
            } else {
                Button("Connect", action: model.connect)
                    .disabled([model.address, model.nickname].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    .keyboardShortcut(.defaultAction)
            }
            BookmarkSection(address: $model.address, nickname: $model.nickname)
                .disabled(model.active)
            #if DEBUG
            Button("Offline files") { showingFilesPreview = true }
                .sheet(isPresented: $showingFilesPreview) { OfflineFilesView() }
            Button("Offline server log") { showingLogPreview = true }
                .sheet(isPresented: $showingLogPreview) { OfflineServerLogView() }
            #endif
            #if DEBUG && os(macOS)
            Button("Offline permission preview") { showingPermissionPreview = true }
                .sheet(isPresented: $showingPermissionPreview) { OfflinePermissionsView() }
            #endif
            #if os(macOS)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            #endif
        }
        .formStyle(.grouped)
    }
}

#if os(macOS)
enum ChannelTreeDensity: String {
    case standard, compact

    static let storageKey = "channelTreeDensity"
}
#endif

extension ChannelNode {
    var isExpandable: Bool { children?.isEmpty == false || !room.memberDetails.isEmpty }
}

struct ChannelRows: View {
    let nodes: [ChannelNode]
    let current: UInt64?
    @Binding var expanded: Set<UInt64>
    let audio: VoiceAudio
    let generation: UInt64
    @Binding var selection: SidebarSelection?

    var body: some View {
        ForEach(nodes) { node in
            if node.isExpandable {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })) {
                    if !node.room.memberDetails.isEmpty {
                        MemberPlaybackList(members: node.room.memberDetails, audio: audio,
                                           generation: generation, selection: $selection)
                    }
                    if let children = node.children {
                        ChannelRows(nodes: children, current: current, expanded: $expanded, audio: audio,
                                    generation: generation, selection: $selection)
                    }
                } label: { link(node) }
                .id(node.id)
            } else {
                link(node).id(node.id)
            }
        }
    }

    private func link(_ node: ChannelNode) -> some View {
        NavigationLink(value: SidebarSelection.channel(node.id)) {
            HStack {
                Label {
                    Text(node.room.name)
                        #if os(macOS)
                        .font(.body)
                        #endif
                } icon: {
                    Image(systemName: current == node.id ? "person.wave.2.fill" : "bubble.left")
                }
                Spacer(minLength: 4)
                if node.room.subscribed || current == node.id {
                    if !node.room.members.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "person.fill")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                            Text(node.room.members.count, format: .number)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Visible members (\(node.room.members.count))"))
                    }
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                        .accessibilityLabel("Member count unavailable")
                        .help("Member count unavailable")
                }
            }
        }
    }
}

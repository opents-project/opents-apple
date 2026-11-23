import SwiftUI

struct ServerView: View {
    @ObservedObject var model: ServerModel
    @State private var selection: UInt64?
    @State private var expanded: Set<UInt64> = []

    @State private var lockedRoom: Room?
    @State private var password = ""
    #if DEBUG
    @State private var showingFilesPreview = false
    @State private var showingLogPreview = false
    @State private var showingPermissionPreview = false
    #endif
    @State private var showingChat = false
    @State private var showingIdentity = false

    private func requestJoin(_ room: Room) {
        guard model.currentChannel != room.id, !model.joining else { return }
        if room.passwordRequired { password = ""; lockedRoom = room }
        else { model.join(room) }
    }

    var body: some View {
        if model.server.isEmpty {
            Form {
                Section("Connect to a server") {
                    TextField("Address or server nickname", text: $model.address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Your nickname", text: $model.nickname)
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
                Button("Offline permission preview") { showingPermissionPreview = true }
                    .sheet(isPresented: $showingPermissionPreview) { OfflinePermissionsView() }
                #endif
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
        } else {
            NavigationSplitView {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ChannelRows(nodes: model.channels, current: model.currentChannel, expanded: $expanded)
                    }
                    #if os(macOS)
                    .contextMenu(forSelectionType: UInt64.self) { ids in
                        if let id = ids.first, let room = find(id, in: model.channels) {
                            Button("Join Channel") { requestJoin(room) }
                                .disabled(model.currentChannel == id || model.joining)
                        }
                    } primaryAction: { ids in
                        if let id = ids.first, let room = find(id, in: model.channels) { requestJoin(room) }
                    }
                    #endif
                    .task(id: currentPath) {
                        guard let path = currentPath, let id = path.last else { return }
                        expanded.formUnion(path.dropLast())
                        selection = id
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .navigationTitle(model.server)
                .toolbar {
                    Button("Text chat", systemImage: "text.bubble") { showingChat = true }
                    Button("My Identity", systemImage: "person.text.rectangle") { showingIdentity = true }
                    Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", action: model.disconnect)
                }
                .popover(isPresented: $showingIdentity) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TeamSpeak Identity UID").font(.headline)
                        Text(model.identityUID).font(.body.monospaced()).textSelection(.enabled)
                    }.padding()
                }
            } detail: {
                if let selection, let room = find(selection, in: model.channels) {
                    Form {
                        if model.currentChannel == room.id {
                            Label("Current Channel", systemImage: "checkmark.circle.fill")
                        } else {
                            Button("Join Channel") { requestJoin(room) }
                                .disabled(model.joining)
                        }
                        LabeledContent("Audio codec", value: room.codec.replacingOccurrences(of: "Opus", with: "Opus "))
                        LabeledContent("Channel type", value: NSLocalizedString(room.kind, comment: "Channel type"))
                        if room.subscribed || !room.members.isEmpty {
                            Section("Visible members (\(room.members.count))") {
                                MemberPlaybackList(members: room.memberDetails, audio: model.audio)
                            }
                        }
                    }.formStyle(.grouped).navigationTitle(room.name)
                } else {
                    ContentUnavailableView("Select a channel", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .sheet(isPresented: $showingChat) { ChatView(model: model) }
            .safeAreaInset(edge: .bottom) { VoiceControls(audio: model.audio) }
            .alert("Channel Password", isPresented: Binding(get: { lockedRoom != nil }, set: { if !$0 { lockedRoom = nil } }), presenting: lockedRoom) { room in
                SecureField("Password", text: $password)
                Button("Join") { model.join(room, password: password); password = "" }
                Button("Cancel", role: .cancel) { password = "" }
            } message: { Text($0.name) }
            .alert("Couldn’t Join Channel", isPresented: Binding(get: { model.joinError != nil }, set: { if !$0 { model.joinError = nil } })) {
                Button("OK") { model.joinError = nil }
            } message: { Text(model.joinError ?? "") }
            .onDisappear { expanded = []; selection = nil; lockedRoom = nil; password = "" }
        }
    }

    private var currentPath: [UInt64]? {
        model.currentChannel.flatMap { ChannelNode.path(to: $0, in: model.channels) }
    }

    private func find(_ id: UInt64, in nodes: [ChannelNode]) -> Room? {
        for node in nodes {
            if node.id == id { return node.room }
            if let match = find(id, in: node.children ?? []) { return match }
        }
        return nil
    }
}

private struct ChannelRows: View {
    let nodes: [ChannelNode]
    let current: UInt64?
    @Binding var expanded: Set<UInt64>

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })) {
                    ChannelRows(nodes: children, current: current, expanded: $expanded)
                } label: { link(node) }
                .id(node.id)
            } else {
                link(node).id(node.id)
            }
        }
    }

    private func link(_ node: ChannelNode) -> some View {
        NavigationLink(value: node.id) {
            HStack {
                Label(node.room.name, systemImage: current == node.id ? "person.wave.2.fill" : "bubble.left")
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

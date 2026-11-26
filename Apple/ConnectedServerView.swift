import SwiftUI

struct ConnectedServerView: View {
    @ObservedObject var model: ServerModel
    @State private var selection: UInt64?
    @State private var expanded: Set<UInt64> = []
    @State private var compactColumn = Self.startsInChannelList
        ? NavigationSplitViewColumn.sidebar : .detail
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showingChat = false
    @State private var chatSelection: ChatScope?
    @State private var editorTarget: ChannelEditorTarget?
    @State private var showingGroupPermissions = false
    @State private var showingIdentity = false
    @State private var lockedRoom: Room?
    @State private var password = ""
    #if os(macOS)
    @State private var showRecovery = false
    #endif
    @State private var revealRequest = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    #endif

    private static var startsInChannelList: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private struct Location: Equatable {
        let channel: UInt64?
        let retrying: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 600
            let alongside = geometry.size.width >= 980
            VStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
                    sidebar
                        .navigationTitle(model.server)
                        .navigationSplitViewColumnWidth(min: 170, ideal: 245, max: 440)
                        #if os(iOS)
                        .toolbar { if widthClass == .compact || UIDevice.current.userInterfaceIdiom == .phone { actions(closeChatReplacesDetail: !alongside) } }
                        #endif
                } detail: {
                    HStack(spacing: 0) {
                        if !showingChat || alongside {
                            channelDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if showingChat {
                            if alongside { Divider() }
                            ChatView(model: model, selection: $chatSelection)
                                .frame(maxWidth: alongside ? 370 : .infinity, maxHeight: .infinity)
                        }
                    }
                    .navigationTitle(showingChat && !alongside ? String(localized: "Text chat") : selectedRoom?.name ?? model.server)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { actions(closeChatReplacesDetail: !alongside) }
                }
                .navigationSplitViewStyle(.balanced)
                #if os(iOS)
                .environment(\.horizontalSizeClass, UIDevice.current.userInterfaceIdiom == .phone ? .compact : widthClass)
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VoiceControls(model: model, audio: model.audio, compact: narrow, revealChannel: revealCurrent)
            }
        }
        .onChange(of: Location(channel: model.currentChannel, retrying: model.reconnecting), initial: true) { old, new in
            guard !new.retrying, let id = new.channel else { return }
            if Self.startsInChannelList, compactColumn == .sidebar {
                if let path = ChannelNode.path(to: id, in: model.channels) {
                    expanded.formUnion(path.dropLast())
                }
                return
            }
            if old.retrying, selection != old.channel, selectedRoom != nil { return }
            if selection == nil || old.channel != id { locate(id) }
        }
        #if os(macOS)
        .task(id: model.reconnecting) {
            if model.reconnecting {
                showRecovery = true
            } else if showRecovery {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                showRecovery = false
            }
        }
        #endif
        .onChange(of: selectedRoom?.id) { _, selected in
            if selected == nil, selection != nil, let current = model.currentChannel { locate(current) }
        }
        .sheet(item: $editorTarget) { target in
            ChannelManagementView(model: model, target: target)
        }
        .sheet(isPresented: $showingGroupPermissions) {
            if let session = model.groupPermissionSession {
                LiveGroupPermissionsView(session: session, generation: model.groupPermissionGeneration)
            }
        }
        .onChange(of: model.reconnecting) { _, reconnecting in
            if reconnecting { showingGroupPermissions = false }
        }
        .sheet(isPresented: $showingIdentity) {
            VStack(alignment: .leading, spacing: 12) {
                Text("TeamSpeak Identity UID").font(.headline)
                Text(model.identityUID).font(.body.monospaced()).textSelection(.enabled)
                Button("Done") { showingIdentity = false }
            }.padding().presentationDetents([.medium])
        }
        .alert("Channel Password", isPresented: Binding(get: { lockedRoom != nil }, set: { if !$0 { lockedRoom = nil } }), presenting: lockedRoom) { room in
            SecureField("Password", text: $password)
            Button("Join") { model.join(room, password: password); password = "" }
            Button("Cancel", role: .cancel) { password = "" }
        } message: { Text($0.name) }
        .alert("Couldn’t Join Channel", isPresented: Binding(get: { model.joinError != nil }, set: { if !$0 { model.joinError = nil } })) {
            Button("OK") { model.joinError = nil }
        } message: { Text(model.joinError ?? "") }
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                #if os(macOS)
                if model.reconnecting {
                    Label("Reconnecting…", systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                } else if showRecovery {
                    Label("Reconnected", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ChannelRows(nodes: model.channels, current: model.currentChannel, expanded: $expanded)
                #else
                Section {
                    ChannelRows(nodes: model.channels, current: model.currentChannel, expanded: $expanded)
                } header: { serverStatus }
                #endif
            }
            #if os(macOS)
            .contextMenu(forSelectionType: UInt64.self) { ids in
                if let id = ids.first, let room = model.room(id) {
                    Button("Join Channel") { requestJoin(room) }
                        .disabled(model.currentChannel == id || model.joining || model.reconnecting)
                }
            } primaryAction: { ids in
                if let id = ids.first, let room = model.room(id) { requestJoin(room) }
            }
            #endif
            .task(id: revealRequest) {
                guard let id = selection else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var serverStatus: some View {
        HStack {
            if model.reconnecting { Label("Reconnecting…", systemImage: "arrow.clockwise") }
            else { Label("Connected", systemImage: "network") }
            Spacer()
            if let me = model.currentRoom?.memberDetails.first(where: \.isSelf) {
                MemberConnectionQuality(member: me, voice: model.audio.voice, compact: true)
            }
        }
    }

    @ToolbarContentBuilder private func actions(closeChatReplacesDetail: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingChat.toggle()
                compactColumn = !showingChat && selection == nil && Self.startsInChannelList
                    ? .sidebar : .detail
            } label: {
                if showingChat && closeChatReplacesDetail {
                    Text("Back to channel")
                } else {
                    Label(showingChat ? "Close chat" : "Text chat", systemImage: showingChat ? "text.bubble.fill" : "text.bubble")
                }
            }
            #if os(macOS)
            ToolbarDevices(audio: model.audio)
            #endif
            Menu {
                Button("Show current channel", systemImage: "person.wave.2", action: revealCurrent)
                Section {
                    Button("Create channel", systemImage: "plus") {
                        editorTarget = ChannelEditorTarget(parent: 0, room: nil, generation: model.generation)
                    }
                    if let room = selectedRoom {
                        Button("Create subchannel", systemImage: "plus.rectangle.on.folder") {
                            editorTarget = ChannelEditorTarget(parent: room.id, room: nil, generation: model.generation)
                        }
                        Button("Edit channel", systemImage: "pencil") {
                            editorTarget = ChannelEditorTarget(parent: room.parent, room: room, generation: model.generation)
                        }
                    }
                }.disabled(model.reconnecting)
                Button("Group permissions", systemImage: "person.2.badge.gearshape") { showingGroupPermissions = true }
                    .disabled(model.groupPermissionSession == nil)
                Button("My Identity", systemImage: "person.text.rectangle") { showingIdentity = true }
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", action: model.disconnect)
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    @ViewBuilder private var channelDetail: some View {
        if let room = selectedRoom {
            Form {
                if model.currentChannel == room.id {
                    Label("Current Channel", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("Join Channel") { requestJoin(room) }.disabled(model.joining || model.reconnecting)
                }
                if room.subscribed || room.id == model.currentChannel || !room.members.isEmpty {
                    Section {
                        if room.memberDetails.isEmpty {
                            Text("No visible members").foregroundStyle(.secondary)
                        } else {
                            MemberPlaybackList(members: room.memberDetails, audio: model.audio) { member in
                                guard let uid = member.uid else { return }
                                let peer = ChatScope.direct(clientId: member.clientId, uid: uid)
                                model.chat.directNames[peer] = member.name
                                chatSelection = peer
                                showingChat = true
                                compactColumn = .detail
                            }
                        }
                    } header: { Text("Visible members (\(room.members.count))") }
                }
                ChannelDescription(model: model, room: room).id(room.id)
                ChannelFilesButton(model: model, room: room).id(room.id)
                DisclosureGroup("Channel info") {
                    LabeledContent("Audio codec", value: room.codec.replacingOccurrences(of: "Opus", with: "Opus "))
                    if !room.audioSupported { Label("Audio unavailable for this codec", systemImage: "speaker.slash") }
                    LabeledContent("Channel type", value: NSLocalizedString(room.kind, comment: "Channel type"))
                }
            }.formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a channel", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private var selectedRoom: Room? { selection.flatMap(model.room) }

    private func locate(_ id: UInt64) {
        guard let path = ChannelNode.path(to: id, in: model.channels) else { return }
        expanded.formUnion(path.dropLast())
        selection = id
        revealRequest += 1
    }

    private func revealCurrent() {
        guard let id = model.currentChannel else { return }
        showingChat = false
        locate(id)
        compactColumn = .detail
    }

    private func requestJoin(_ room: Room) {
        guard model.currentChannel != room.id, !model.joining, !model.reconnecting else { return }
        if room.passwordRequired { password = ""; lockedRoom = room }
        else { model.join(room) }
    }
}

private struct ChannelDescription: View {
    @ObservedObject var model: ServerModel
    let room: Room
    @State private var loadError: String?
    @State private var loading = false

    var body: some View {
        Section("Channel description") {
            if let description = room.description {
                if description.isEmpty {
                    Text("No channel description").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: description).textSelection(.enabled)
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
                    .disabled(loading || model.reconnecting)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading channel description")
            }
        }
        .task(id: room.description == nil && !model.reconnecting) {
            if room.description == nil && !model.reconnecting { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        loadError = await model.readChannelDescription(room.id)
    }
}

#if os(macOS)
private struct ToolbarDevices: View {
    @ObservedObject var audio: VoiceAudio
    var body: some View {
        HStack(spacing: 0) { DeviceButtons(audio: audio) }
            .labelStyle(.iconOnly).disabled(audio.voice == nil)
    }
}
#endif

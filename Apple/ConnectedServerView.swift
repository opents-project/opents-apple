import SwiftUI

struct ConnectedServerView: View {
    @ObservedObject var model: ServerModel
    @State private var selection: UInt64?
    @State private var expansionServerKey: String?
    @State private var savedExpansion: Set<UInt64> = []
    @State private var revealedAncestors: Set<UInt64> = []
    @State private var confirmedChannel: UInt64?
    @State private var scrollRequest: ChannelScrollRequest?
    @State private var compactColumn = Self.startsInChannelList
        ? NavigationSplitViewColumn.sidebar : .detail
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showingChat = false
    @State private var chatSelection: ChatScope?
    @State private var editorTarget: ChannelEditorTarget?
    @State private var fileTarget: ChannelFileTarget?
    @State private var showingGroupPermissions = false
    @State private var showingIdentity = false
    @State private var lockedRoom: Room?
    @State private var password = ""
    #if os(macOS)
    @State private var showRecovery = false
    @AppStorage(ChannelTreeDensity.storageKey) private var channelTreeDensity = ChannelTreeDensity.standard
    private static let toolbarButtonSize: CGFloat = 24
    #endif
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
        let serverKey: String?
        let path: [UInt64]?
        let retrying: Bool
    }

    private struct ChannelScrollRequest: Equatable {
        let serverKey: String?
        let channel: UInt64
        let nonce = UUID()
    }

    private struct ChannelFileTarget: Identifiable {
        let room: Room
        let session: Session
        var id: UInt64 { room.id }
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
                        .toolbar {
                            ToolbarItem(placement: .navigation) { channelTreeMenu }
                            #if os(iOS)
                            if widthClass == .compact || Self.startsInChannelList {
                                actions(closeChatReplacesDetail: !alongside)
                            }
                            #endif
                        }
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
        .onChange(of: location, initial: true) { old, new in
            updateLocation(new, followingReconnect: old.retrying)
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
        .sheet(item: $fileTarget) { target in
            ChannelFilesView(session: target.session, room: target.room)
        }
        .sheet(isPresented: $showingGroupPermissions) {
            if let session = model.groupPermissionSession {
                LiveGroupPermissionsView(session: session, generation: model.groupPermissionGeneration)
            }
        }
        .onChange(of: model.reconnecting) { _, reconnecting in
            if reconnecting {
                showingGroupPermissions = false
                fileTarget = nil
            }
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
                ChannelRows(nodes: model.channels, current: model.currentChannel, expanded: channelExpansion)
                #else
                Section {
                    ChannelRows(nodes: model.channels, current: model.currentChannel, expanded: channelExpansion)
                } header: { serverStatus }
                #endif
            }
            #if os(macOS)
            .environment(\.sidebarRowSize, channelTreeDensity == .compact ? .small : .medium)
            #endif
            .contextMenu(forSelectionType: UInt64.self, menu: channelContextMenu, primaryAction: sidebarPrimaryAction)
            .task(id: scrollRequest) {
                guard let request = scrollRequest else { return }
                await Task.yield()
                guard !Task.isCancelled, request == scrollRequest, !model.reconnecting,
                      request.serverKey == model.channelTreeServerKey,
                      let path = ChannelNode.path(to: request.channel, in: model.channels),
                      path.dropLast().allSatisfy(expanded.contains) else { return }
                proxy.scrollTo(request.channel, anchor: .center)
            }
        }
    }

    private var sidebarPrimaryAction: ((Set<UInt64>) -> Void)? {
        #if os(macOS)
        { ids in
            if let room = ids.first.flatMap(model.room) { requestJoin(room) }
        }
        #else
        nil
        #endif
    }

    @ViewBuilder private func channelContextMenu(_ ids: Set<UInt64>) -> some View {
        if ids.isEmpty {
            channelTreeActions
        } else if ids.count == 1, let room = ids.first.flatMap(model.room) {
            channelRowActions(room)
        }
    }

    private var channelTreeMenu: some View {
        Menu {
            channelTreeActions
        } label: {
            Label("Channel list actions", systemImage: "list.bullet")
        }
        .labelStyle(.iconOnly)
        .help("Channel list actions")
    }

    private var channelTreeActions: some View {
        let generation = model.generation
        return Group {
            Button("Create channel", systemImage: "plus") {
                guard !model.reconnecting, model.generation == generation else { return }
                editorTarget = ChannelEditorTarget(parent: 0, room: nil, generation: generation)
            }
            .disabled(model.reconnecting)
            channelExpansionActions
        }
    }

    private func channelRowActions(_ room: Room) -> some View {
        let generation = model.generation
        func liveRoom() -> Room? {
            guard !model.reconnecting, model.generation == generation else { return nil }
            return model.room(room.id)
        }
        return Group {
            if room.id != model.currentChannel {
                Button("Join Channel", systemImage: "arrow.right.circle") {
                    if let room = liveRoom() { requestJoin(room) }
                }
                .disabled(model.joining || model.reconnecting)
            }
            Button("Edit channel", systemImage: "pencil") {
                guard let room = liveRoom() else { return }
                editorTarget = ChannelEditorTarget(parent: room.parent, room: room, generation: generation)
            }
            .disabled(model.reconnecting)
            Button("Create subchannel", systemImage: "plus.rectangle.on.folder") {
                guard let room = liveRoom() else { return }
                editorTarget = ChannelEditorTarget(parent: room.id, room: nil, generation: generation)
            }
            .disabled(model.reconnecting)
            Button("Open channel files", systemImage: "folder") {
                if let room = liveRoom() { openChannelFiles(room) }
            }
            .disabled(model.reconnecting || model.fileSession == nil)
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
            #if os(macOS)
            HStack(spacing: 0) {
                chatButton(closeChatReplacesDetail: closeChatReplacesDetail)
                DeviceButtons(audio: model.audio, minimumSize: Self.toolbarButtonSize)
            }
            .labelStyle(.iconOnly)
            #else
            chatButton(closeChatReplacesDetail: closeChatReplacesDetail)
            #endif
            Menu {
                Button("Show current channel", systemImage: "person.wave.2", action: revealCurrent)
                Button("Group permissions", systemImage: "person.2.badge.gearshape") { showingGroupPermissions = true }
                    .disabled(model.groupPermissionSession == nil)
                Button("My Identity", systemImage: "person.text.rectangle") { showingIdentity = true }
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", action: model.disconnect)
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    private func chatButton(closeChatReplacesDetail: Bool) -> some View {
        let returningToChannel = showingChat && closeChatReplacesDetail
        let title: LocalizedStringKey = returningToChannel ? "Back to channel" : (showingChat ? "Close chat" : "Text chat")
        let icon = returningToChannel ? "chevron.left" : (showingChat ? "text.bubble.fill" : "text.bubble")
        return Button {
            showingChat.toggle()
            compactColumn = !showingChat && selection == nil && Self.startsInChannelList
                ? .sidebar : .detail
        } label: {
            #if os(macOS)
            Label(title, systemImage: icon)
                .frame(minWidth: Self.toolbarButtonSize, minHeight: Self.toolbarButtonSize)
            #else
            if returningToChannel { Text(title) }
            else { Label(title, systemImage: icon) }
            #endif
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
                Button("Channel files", systemImage: "folder") { openChannelFiles(room) }
                    .disabled(model.reconnecting || model.fileSession == nil)
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

    private var location: Location {
        Location(
            serverKey: model.channelTreeServerKey,
            path: model.currentChannel.flatMap { ChannelNode.path(to: $0, in: model.channels) },
            retrying: model.reconnecting
        )
    }

    private var expanded: Set<UInt64> { savedExpansion.union(revealedAncestors) }

    private var channelExpansion: Binding<Set<UInt64>> {
        let key = expansionServerKey
        return Binding(get: { expanded }, set: { next in
            guard key == expansionServerKey, key == model.channelTreeServerKey else { return }
            let previous = expanded
            guard next != previous else { return }
            let closed = previous.subtracting(next).filter { model.room($0) != nil }
            savedExpansion.formUnion(next.subtracting(previous))
            savedExpansion.subtract(closed)
            revealedAncestors.subtract(closed)
            saveExpansion(for: key)
        })
    }

    private var channelExpansionActions: some View {
        let key = expansionServerKey
        return Section {
            Button("Expand All Channels", systemImage: "chevron.down") {
                guard key == expansionServerKey, key == model.channelTreeServerKey else { return }
                var branches = Set<UInt64>()
                func expand(_ nodes: [ChannelNode]) {
                    for node in nodes {
                        if let children = node.children {
                            branches.insert(node.id)
                            expand(children)
                        }
                    }
                }
                expand(model.channels)
                savedExpansion.formUnion(branches)
                saveExpansion(for: key)
            }
            Button("Collapse All Channels", systemImage: "chevron.up") {
                guard key == expansionServerKey, key == model.channelTreeServerKey else { return }
                savedExpansion.removeAll()
                revealedAncestors.removeAll()
                scrollRequest = nil
                saveExpansion(for: key)
            }
        }
    }

    private func saveExpansion(for key: String?) {
        if let key { model.saveChannelExpansion(savedExpansion, for: key) }
    }

    private func updateLocation(_ location: Location, followingReconnect: Bool) {
        guard !location.retrying else { return }
        if expansionServerKey != location.serverKey {
            expansionServerKey = location.serverKey
            savedExpansion = location.serverKey.flatMap { model.savedChannelExpansion(for: $0) } ?? []
            revealedAncestors = []
            confirmedChannel = nil
            scrollRequest = nil
        }
        guard let path = location.path, let id = path.last, id != confirmedChannel else { return }
        let previous = confirmedChannel
        confirmedChannel = id
        let keepBrowsing = followingReconnect && previous != nil && selection != previous && selectedRoom != nil
        let showingPhoneSidebar = Self.startsInChannelList && compactColumn == .sidebar
        locate(id, select: !keepBrowsing && !showingPhoneSidebar)
    }

    private func locate(_ id: UInt64, select: Bool = true) {
        guard let path = ChannelNode.path(to: id, in: model.channels) else { return }
        revealedAncestors.formUnion(path.dropLast())
        if select { selection = id }
        scrollRequest = ChannelScrollRequest(serverKey: expansionServerKey, channel: id)
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

    private func openChannelFiles(_ room: Room) {
        guard !model.reconnecting, let session = model.fileSession else { return }
        fileTarget = ChannelFileTarget(room: room, session: session)
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

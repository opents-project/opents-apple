import SwiftUI

struct ConnectedServerView: View {
    @ObservedObject var model: ServerModel
    var tabSelected = true
    #if os(macOS)
    var tabs: ServerTabs? = nil
    var connections: ServerConnectionsSection? = nil
    #else
    var mobileTabs: ServerTabs? = nil
    #endif
    @State private var selection: SidebarSelection?
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
    @State private var permissionGroup: ListedGroup?
    @State private var playbackTarget: MemberSelection?
    @State private var showingIdentity = false
    @State private var lockedRoom: Room?
    @State private var password = ""
    #if os(macOS)
    @State private var showRecovery = false
    @State private var showingPushToTalk = false
    @AppStorage(ChannelTreeDensity.storageKey) private var channelTreeDensity = ChannelTreeDensity.standard
    private static let toolbarButtonSize: CGFloat = 24
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass

    private var usesMobileConnectionsSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && widthClass == .regular
    }

    private var usesCompactNavigation: Bool { Self.startsInChannelList || widthClass == .compact }
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

    private func detailTitle(chatAlongside: Bool) -> String {
        #if os(macOS)
        if showingPushToTalk { return String(localized: "Push to Talk Panel") }
        #endif
        return showingChat && !chatAlongside
            ? String(localized: "Text chat")
            : selectedMember?.member.name ?? selectedRoom?.name ?? model.server
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 600
            let alongside = geometry.size.width >= 980
            VStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
                    sidebar
                        #if os(macOS)
                        .toolbar(removing: .sidebarToggle)
                        #else
                        .navigationBarTitleDisplayMode(mobileTabs == nil ? .automatic : .inline)
                        .mobileServerConnectionToolbar(tabs: tabSelected && !usesMobileConnectionsSidebar ? mobileTabs : nil,
                                                       navigationTitle: model.server)
                        #endif
                        .navigationSplitViewColumnWidth(min: 170, ideal: 245, max: 440)
                        #if os(iOS)
                        .toolbar {
                            if tabSelected {
                                ToolbarItem(placement: .navigation) { channelTreeMenu }
                                if usesCompactNavigation {
                                    actions(closeChatReplacesDetail: !alongside)
                                }
                            }
                        }
                        #endif
                } detail: {
                    detailContent(chatAlongside: alongside)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .mobileServerConnectionToolbar(tabs: tabSelected && !usesMobileConnectionsSidebar ? mobileTabs : nil,
                                                   navigationTitle: detailTitle(chatAlongside: alongside),
                                                   subtitle: detailTitle(chatAlongside: alongside))
                    #endif
                    .toolbar {
                        if tabSelected {
                            actions(closeChatReplacesDetail: !alongside)
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
                #if os(macOS)
                .toolbar {
                    if tabSelected { ToolbarItem(placement: .navigation) { sidebarVisibilityButton } }
                }
                .onChange(of: detailTitle(chatAlongside: alongside), initial: true) { _, title in
                    model.updateWindowTitle(title)
                }
                #else
                .environment(\.horizontalSizeClass, UIDevice.current.userInterfaceIdiom == .phone ? .compact : widthClass)
                .onChange(of: compactColumn) { _, column in
                    if usesCompactNavigation && column == .sidebar { showingChat = false }
                }
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
        .onChange(of: selection) { _, target in
            if case .member? = target {
                showingChat = false
                #if os(macOS)
                showingPushToTalk = false
                #endif
                compactColumn = .detail
            }
        }
        .onChange(of: selection != nil && selectedRoom == nil && selectedMember == nil && !model.reconnecting) { _, missing in
            if missing, let current = model.currentChannel { locate(current) }
        }
        .sheet(item: $editorTarget) { target in
            ChannelManagementView(model: model, target: target)
        }
        .sheet(item: $fileTarget) { target in
            ChannelFilesView(session: target.session, room: target.room)
        }
        .sheet(isPresented: $showingGroupPermissions) {
            if let session = model.groupPermissionSession {
                LiveGroupPermissionsView(session: session, generation: model.groupPermissionGeneration,
                                         initialGroup: permissionGroup)
            }
        }
        .sheet(item: $playbackTarget) { target in
            if let member = findMember(target)?.member, let voice = model.audio.voice {
                MemberPlaybackSettings(member: member, voice: voice)
            }
        }
        .onChange(of: playbackTarget.flatMap { findMember($0)?.member.clientId }) { _, client in
            if client == nil { playbackTarget = nil }
        }
        .onChange(of: model.reconnecting) { _, reconnecting in
            if reconnecting {
                showingGroupPermissions = false
                playbackTarget = nil
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
        .alert("Couldn’t Join Channel", isPresented: Binding(get: { tabSelected && model.joinError != nil }, set: { if !$0, tabSelected { model.joinError = nil } })) {
            Button("OK") { model.joinError = nil }
        } message: { Text(model.joinError ?? "") }
    }

    @ViewBuilder private func detailContent(chatAlongside: Bool) -> some View {
        #if os(macOS)
        if let tabs, showingPushToTalk {
            PushToTalkPanel(tabs: tabs)
        } else {
            channelAndChat(alongside: chatAlongside)
        }
        #else
        channelAndChat(alongside: chatAlongside)
        #endif
    }

    private func channelAndChat(alongside: Bool) -> some View {
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
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                #if os(macOS)
                if let connections { connections }
                Section {
                    if model.reconnecting {
                        Label("Reconnecting…", systemImage: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    } else if showRecovery {
                        Label("Reconnected", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    channelRows
                } header: {
                    HStack {
                        Text("Channels")
                        Spacer()
                        channelTreeMenu
                    }
                }
                #else
                if let mobileTabs, usesMobileConnectionsSidebar {
                    MobileServerConnectionsSection(tabs: mobileTabs)
                }
                Section {
                    channelRows
                } header: {
                    if model.reconnecting { Label("Reconnecting…", systemImage: "arrow.clockwise") }
                }
                #endif
            }
            #if os(macOS)
            .environment(\.sidebarRowSize, channelTreeDensity == .compact ? .small : .medium)
            #endif
            .contextMenu(forSelectionType: SidebarSelection.self, menu: sidebarContextMenu, primaryAction: sidebarPrimaryAction)
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

    private var channelRows: some View {
        ChannelRows(nodes: model.channels, current: model.currentChannel, expanded: channelExpansion,
                    audio: model.audio, generation: model.generation, selection: $selection)
    }

    #if os(macOS)
    private var sidebarVisibilityButton: some View {
        let hidden = columns == .detailOnly
        let title: LocalizedStringKey = hidden ? "Show Sidebar" : "Hide Sidebar"
        return Button {
            columns = hidden ? .all : .detailOnly
        } label: {
            Label(title, systemImage: "sidebar.left")
        }
    }
    #endif

    private var sidebarPrimaryAction: ((Set<SidebarSelection>) -> Void)? {
        #if os(macOS)
        { items in
            guard items.count == 1, case .channel(let id)? = items.first, let room = model.room(id) else { return }
            requestJoin(room)
        }
        #else
        nil
        #endif
    }

    @ViewBuilder private func sidebarContextMenu(_ items: Set<SidebarSelection>) -> some View {
        if items.isEmpty {
            channelTreeActions
        } else if items.count == 1, let item = items.first {
            switch item {
            case .channel(let id):
                if let room = model.room(id) { channelRowActions(room) }
            case .member(let target):
                if let member = findMember(target)?.member {
                    if !member.isSelf, member.uid != nil {
                        Button("Private message", systemImage: "bubble.left") {
                            if let current = findMember(target)?.member { startPrivateChat(current) }
                        }
                    }
                    if !member.isSelf, member.databaseId != 0, model.audio.voice != nil {
                        Button("Playback settings", systemImage: "slider.horizontal.3") {
                            if findMember(target) != nil { playbackTarget = target }
                        }
                    }
                    #if os(macOS)
                    if !member.serverGroups.isEmpty || member.channelGroup != nil {
                        Menu("Group permissions", systemImage: "person.2.badge.gearshape") {
                            if !member.serverGroups.isEmpty {
                                Section("Server groups") {
                                    ForEach(member.serverGroups, id: \.id) { group in
                                        memberGroupButton(group, target: target)
                                    }
                                }
                            }
                            if let group = member.channelGroup {
                                Section("Channel group") { memberGroupButton(group, target: target) }
                            }
                        }
                        .disabled(model.groupPermissionSession == nil)
                    }
                    #endif
                }
            }
        }
    }

    #if os(macOS)
    private func memberGroupButton(_ group: ListedGroup, target: MemberSelection) -> some View {
        Button {
            guard let member = findMember(target)?.member else { return }
            let groups = group.kind == .server ? member.serverGroups : [member.channelGroup].compactMap { $0 }
            guard let current = groups.first(where: { $0.id == group.id }) else { return }
            permissionGroup = current
            showingGroupPermissions = true
        } label: { Text(verbatim: group.name) }
    }
    #endif

    private var channelTreeMenu: some View {
        Menu {
            channelTreeActions
        } label: {
            Label("Channel list actions", systemImage: "list.bullet")
                .labelStyle(.iconOnly)
                #if os(macOS)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
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

    @ToolbarContentBuilder private func actions(closeChatReplacesDetail: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(macOS)
            HStack(spacing: 0) {
                chatButton(closeChatReplacesDetail: closeChatReplacesDetail)
                if tabs != nil { pushToTalkButton }
            }
            .labelStyle(.iconOnly)
            #else
            if !usesCompactNavigation || !showingChat || !closeChatReplacesDetail {
                chatButton(closeChatReplacesDetail: closeChatReplacesDetail)
            }
            #endif
            Menu {
                Button("Show current channel", systemImage: "person.wave.2", action: revealCurrent)
                Button("Group permissions", systemImage: "person.2.badge.gearshape") {
                    permissionGroup = nil
                    showingGroupPermissions = true
                }
                    .disabled(model.groupPermissionSession == nil)
                Button("My Identity", systemImage: "person.text.rectangle") { showingIdentity = true }
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right") {
                    #if os(macOS)
                    if let tabs { tabs.disconnect(model) } else { model.disconnect() }
                    #else
                    model.disconnect()
                    #endif
                }
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    #if os(macOS)
    private var pushToTalkButton: some View {
        Button {
            showingPushToTalk.toggle()
            compactColumn = .detail
        } label: {
            Label("Push to Talk Panel", systemImage: showingPushToTalk ? "waveform.circle.fill" : "waveform")
                .frame(minWidth: Self.toolbarButtonSize, minHeight: Self.toolbarButtonSize)
        }
        .help("Push to Talk Panel")
        .accessibilityAddTraits(showingPushToTalk ? .isSelected : [])
    }
    #endif

    private func chatButton(closeChatReplacesDetail: Bool) -> some View {
        #if os(macOS)
        let chatVisible = showingChat && !showingPushToTalk
        #else
        let chatVisible = showingChat
        #endif
        let returningToChannel = chatVisible && closeChatReplacesDetail
        let title: LocalizedStringKey = returningToChannel ? "Back to channel" : (chatVisible ? "Close chat" : "Text chat")
        let icon = returningToChannel ? "chevron.left" : (chatVisible ? "text.bubble.fill" : "text.bubble")
        let toggleChat = {
            showingChat = !chatVisible
            #if os(macOS)
            showingPushToTalk = false
            #endif
            compactColumn = !showingChat && selection == nil && Self.startsInChannelList
                ? .sidebar : .detail
        }
        return Button {
            #if os(iOS)
            if Self.startsInChannelList {
                // Change columns without morphing the toolbar over the chat composer.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction, toggleChat)
                return
            }
            #endif
            toggleChat()
        } label: {
            #if os(macOS)
            Label(title, systemImage: icon)
                .frame(minWidth: Self.toolbarButtonSize, minHeight: Self.toolbarButtonSize)
            #else
            Label(title, systemImage: icon).labelStyle(.iconOnly)
            #endif
        }
    }

    @ViewBuilder private var channelDetail: some View {
        if let result = selectedMember {
            ServerMemberDetails(member: result.member, channel: result.room.name)
        } else if let room = selectedRoom {
            Form {
                if model.currentChannel == room.id {
                    Label("Current Channel", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("Join Channel") { requestJoin(room) }.disabled(model.joining || model.reconnecting)
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

    private var selectedRoom: Room? {
        guard case .channel(let id)? = selection else { return nil }
        return model.room(id)
    }

    private var selectedMember: (member: RoomMember, room: Room)? {
        guard case .member(let target)? = selection else { return nil }
        return findMember(target)
    }

    private func findMember(_ target: MemberSelection) -> (member: RoomMember, room: Room)? {
        guard target.generation == model.generation else { return nil }
        func find(in nodes: [ChannelNode]) -> (RoomMember, Room)? {
            for node in nodes {
                if let member = node.room.memberDetails.first(where: target.matches) { return (member, node.room) }
                if let children = node.children, let match = find(in: children) { return match }
            }
            return nil
        }
        return find(in: model.channels)
    }

    private func startPrivateChat(_ member: RoomMember) {
        guard let uid = member.uid else { return }
        let peer = ChatScope.direct(clientId: member.clientId, uid: uid)
        model.chat.directNames[peer] = member.name
        chatSelection = peer
        showingChat = true
        #if os(macOS)
        showingPushToTalk = false
        #endif
        compactColumn = .detail
    }

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
                        if node.isExpandable { branches.insert(node.id) }
                        if let children = node.children { expand(children) }
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
        let keepBrowsing = followingReconnect && previous != nil && selection != previous.map(SidebarSelection.channel) && selectedRoom != nil
        let showingPhoneSidebar = Self.startsInChannelList && compactColumn == .sidebar
        locate(id, select: !keepBrowsing && !showingPhoneSidebar)
    }

    private func locate(_ id: UInt64, select: Bool = true) {
        guard let path = ChannelNode.path(to: id, in: model.channels) else { return }
        revealedAncestors.formUnion(path)
        if select { selection = .channel(id) }
        scrollRequest = ChannelScrollRequest(serverKey: expansionServerKey, channel: id)
    }

    private func revealCurrent() {
        guard let id = model.currentChannel else { return }
        showingChat = false
        #if os(macOS)
        showingPushToTalk = false
        #endif
        #if os(iOS)
        if Self.startsInChannelList || widthClass == .compact {
            selection = nil
            compactColumn = .sidebar
            locate(id, select: false)
            return
        }
        #endif
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

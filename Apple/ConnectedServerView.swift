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
    #if os(iOS)
    @State private var widePhoneSplit = false
    #endif
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
    @State private var memberGroupAssignment: MemberGroupAssignmentTarget?
    @State private var changingChannelGroup = false
    @State private var channelGroupError: String?
    @State private var ownChannelGroupChange: ChannelGroupChange?
    @State private var showRecovery = false
    @State private var showingPushToTalk = false
    @AppStorage(ChannelTreeDensity.storageKey) private var channelTreeDensity = ChannelTreeDensity.standard
    private static let toolbarButtonSize: CGFloat = 24
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass

    private var usesMobileConnectionsSidebar: Bool {
        widthClass == .regular && (UIDevice.current.userInterfaceIdiom == .pad || widePhoneSplit)
    }

    private var usesCompactNavigation: Bool { usesPhoneColumnNavigation || widthClass == .compact }
    #endif

    private var usesPhoneColumnNavigation: Bool {
        #if os(iOS)
        Self.startsInChannelList && !widePhoneSplit
        #else
        false
        #endif
    }

    private var showsBottomDeviceButtons: Bool {
        #if os(iOS)
        mobileTabs == nil || !usesMobileConnectionsSidebar || columns == .detailOnly
        #else
        false
        #endif
    }

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

    #if os(macOS)
    private struct ChannelGroupChange {
        let target: MemberGroupAssignmentTarget
        let group: ListedGroup
    }
    #endif

    private func detailTitle(chatAlongside: Bool) -> String {
        #if os(macOS)
        if showingPushToTalk { return String(localized: "Push to Talk Panel") }
        #endif
        return showingChat && !chatAlongside
            ? String(localized: "Text chat")
            : selectedMember?.member.name ?? selectedRoom?.name ?? model.server
    }

    #if os(iOS)
    @ViewBuilder private func mobileDetail(chatAlongside: Bool, splitWidth: CGFloat?) -> some View {
        if let splitWidth {
            detailContent(chatAlongside: chatAlongside)
                .navigationSplitViewColumnWidth(min: splitWidth * 0.35,
                                                ideal: splitWidth * 0.435,
                                                max: splitWidth * 0.46)
        } else {
            detailContent(chatAlongside: chatAlongside)
        }
    }
    #endif

    private func splitSidebar(alongside: Bool, minWidth: CGFloat, idealWidth: CGFloat, maxWidth: CGFloat) -> some View {
        sidebar
            #if os(macOS)
            .toolbar(removing: .sidebarToggle)
            #else
            .navigationBarTitleDisplayMode(mobileTabs == nil ? .automatic : .inline)
            .mobileServerConnectionToolbar(tabs: tabSelected && !usesMobileConnectionsSidebar ? mobileTabs : nil,
                                           navigationTitle: model.server)
            #endif
            .navigationSplitViewColumnWidth(min: minWidth, ideal: idealWidth, max: maxWidth)
            #if os(iOS)
            .toolbar {
                if tabSelected {
                    ToolbarItem(placement: .navigation) { channelTreeMenu }
                    if usesCompactNavigation { actions(closeChatReplacesDetail: !alongside) }
                }
            }
            #endif
    }

    private func splitDetail(alongside: Bool, splitWidth: CGFloat?) -> some View {
        #if os(iOS)
        mobileDetail(chatAlongside: alongside, splitWidth: splitWidth)
            .navigationBarTitleDisplayMode(.inline)
            .mobileServerConnectionToolbar(tabs: tabSelected && !usesMobileConnectionsSidebar ? mobileTabs : nil,
                                           navigationTitle: detailTitle(chatAlongside: alongside),
                                           subtitle: detailTitle(chatAlongside: alongside))
            .toolbar {
                if tabSelected { actions(closeChatReplacesDetail: !alongside) }
            }
        #else
        detailContent(chatAlongside: alongside)
            .toolbar {
                if tabSelected { actions(closeChatReplacesDetail: !alongside) }
            }
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 600
            let alongside = geometry.size.width >= 980
            #if os(iOS)
            let widePhonePosture = UIDevice.current.userInterfaceIdiom == .phone
                && widthClass == .regular && heightClass == .regular && geometry.size.width >= 600
            let splitWidth: CGFloat? = widePhonePosture ? geometry.size.width : nil
            #else
            let splitWidth: CGFloat? = nil
            #endif
            let sidebarMinimumWidth = splitWidth.map { $0 * 0.55 } ?? 170
            let sidebarIdealWidth = splitWidth.map { $0 * 0.565 } ?? 245
            let sidebarMaximumWidth = splitWidth.map { $0 * 0.58 } ?? 440
            VStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
                    splitSidebar(alongside: alongside, minWidth: sidebarMinimumWidth,
                                 idealWidth: sidebarIdealWidth, maxWidth: sidebarMaximumWidth)
                } detail: {
                    splitDetail(alongside: alongside, splitWidth: splitWidth)
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
                .environment(\.horizontalSizeClass,
                             UIDevice.current.userInterfaceIdiom == .phone && !widePhonePosture ? .compact : widthClass)
                .onChange(of: compactColumn) { _, column in
                    if usesCompactNavigation && column == NavigationSplitViewColumn.sidebar { showingChat = false }
                }
                .onChange(of: widePhonePosture, initial: true) { _, split in
                    widePhoneSplit = split
                    if split {
                        compactColumn = .detail
                        if selection == nil, !showingChat, let current = model.currentChannel {
                            locate(current)
                        }
                    }
                }
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VoiceControls(model: model, audio: model.audio, compact: narrow, revealChannel: revealCurrent,
                              showsDeviceButtons: showsBottomDeviceButtons)
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
        #if os(macOS)
        .sheet(item: $memberGroupAssignment) { target in
            MemberGroupAssignmentView(model: model, target: target)
        }
        .onChange(of: tabSelected) { _, selected in
            if !selected {
                memberGroupAssignment = nil
                ownChannelGroupChange = nil
                channelGroupError = nil
            }
        }
        .alert("Change Your Groups?", isPresented: Binding(get: { tabSelected && ownChannelGroupChange != nil }, set: { visible in
            if !visible { ownChannelGroupChange = nil }
        }), presenting: ownChannelGroupChange) { change in
            Button("Cancel", role: .cancel) { }
            Button("Change Group") {
                ownChannelGroupChange = nil
                Task { await setChannelGroup(change, confirmed: true) }
            }
        } message: { change in
            Text("Switch your channel group to \(change.group.name)? This may change your permissions in this channel.")
        }
        .alert("Couldn’t Change Group", isPresented: Binding(get: { tabSelected && channelGroupError != nil }, set: { visible in
            if !visible { channelGroupError = nil }
        }), presenting: channelGroupError) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(verbatim: error)
        }
        #endif
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
                #if os(macOS)
                memberGroupAssignment = nil
                ownChannelGroupChange = nil
                channelGroupError = nil
                #endif
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
                    MobileServerConnectionsSection(tabs: mobileTabs, showsAudioControls: true)
                }
                Section {
                    channelRows
                } header: {
                    if model.reconnecting {
                        Label("Reconnecting…", systemImage: "arrow.clockwise")
                    } else if mobileTabs != nil && usesMobileConnectionsSidebar {
                        Text("Channels")
                    }
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
                if let match = findMember(target) {
                    let member = match.member
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
                    if member.databaseId != 0, let session = model.groupPermissionSession {
                        let assignment = MemberGroupAssignmentTarget(member: target, session: session, channel: match.room.id)
                        Button("Set Server Group", systemImage: "person.2.badge.gearshape") {
                            guard tabSelected, assignment.liveMember(in: model) != nil else { return }
                            memberGroupAssignment = assignment
                        }
                        channelGroupMenu(for: member, target: assignment)
                    }
                    #endif
                }
            }
        }
    }

    #if os(macOS)
    private func channelGroupMenu(for member: RoomMember, target: MemberGroupAssignmentTarget) -> some View {
        Menu("Set Channel Group", systemImage: "person.wave.2") {
            let groups = model.channelGroups
            if let current = member.channelGroup, !groups.contains(where: { $0.id == current.id }) {
                channelGroupItem(current, selected: true, target: target)
            } else if groups.isEmpty {
                Text("No assignable groups.")
            }
            ForEach(groups, id: \.id) { group in
                channelGroupItem(group, selected: member.channelGroup?.id == group.id, target: target)
            }
        }
        .disabled(changingChannelGroup)
    }

    private func channelGroupItem(_ group: ListedGroup, selected: Bool, target: MemberGroupAssignmentTarget) -> some View {
        Toggle(isOn: Binding(get: { selected }, set: { chosen in
            guard chosen else { return }
            Task { await setChannelGroup(ChannelGroupChange(target: target, group: group)) }
        })) {
            Text(verbatim: group.name)
        }
        .disabled(selected)
    }

    @MainActor private func setChannelGroup(_ change: ChannelGroupChange, confirmed: Bool = false) async {
        let target = change.target
        guard tabSelected, !changingChannelGroup, ownChannelGroupChange == nil,
              model.channelGroups.contains(where: { $0.id == change.group.id }),
              let member = target.liveMember(in: model), member.channelGroup?.id != change.group.id else { return }
        if member.isSelf, !confirmed {
            ownChannelGroupChange = change
            return
        }
        changingChannelGroup = true
        defer { changingChannelGroup = false }
        let selection = target.member
        let response = await target.session.setMemberChannelGroup(group: change.group.id, clientId: selection.clientID,
                                                                   databaseId: selection.databaseID, channel: target.channel,
                                                                   generation: selection.generation)
        guard model.groupPermissionSession === target.session, model.groupPermissionGeneration == selection.generation else { return }
        channelGroupError = response.error
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
                panelToggle("Text chat", systemImage: "text.bubble", isShowing: $showingChat, otherPanel: $showingPushToTalk)
                if tabs != nil {
                    panelToggle("Push to Talk Panel", systemImage: "waveform", isShowing: $showingPushToTalk, otherPanel: $showingChat)
                }
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
    private func panelToggle(_ title: LocalizedStringKey, systemImage: String, isShowing: Binding<Bool>,
                             otherPanel: Binding<Bool>) -> some View {
        Toggle(isOn: Binding(get: { isShowing.wrappedValue }, set: { visible in
            otherPanel.wrappedValue = false
            isShowing.wrappedValue = visible
            compactColumn = .detail
        })) {
            Label(title, systemImage: systemImage)
                .frame(width: Self.toolbarButtonSize, height: Self.toolbarButtonSize)
        }
        .toggleStyle(.button)
        .help(Text(title))
        .accessibilityAddTraits(isShowing.wrappedValue ? .isSelected : [])
    }
    #else
    private func chatButton(closeChatReplacesDetail: Bool) -> some View {
        let chatVisible = showingChat
        let returningToChannel = chatVisible && closeChatReplacesDetail
        let title: LocalizedStringKey = returningToChannel ? "Back to channel" : (chatVisible ? "Close chat" : "Text chat")
        let icon = returningToChannel ? "chevron.left" : (chatVisible ? "text.bubble.fill" : "text.bubble")
        let toggleChat = {
            showingChat = !chatVisible
            compactColumn = !showingChat && selection == nil && usesPhoneColumnNavigation
                ? .sidebar : .detail
        }
        return Button {
            if usesPhoneColumnNavigation {
                // Change columns without morphing the toolbar over the chat composer.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction, toggleChat)
                return
            }
            toggleChat()
        } label: {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
        }
    }
    #endif

    @ViewBuilder private var channelDetail: some View {
        if case .member(let target)? = selection, let result = findMember(target) {
            let inheritedSource = inheritedGroupSource(for: result.member, in: result.room)
            let canRequestDetails = tabSelected && model.groupPermissionSession != nil && target.databaseID != 0
            ServerMemberDetails(member: result.member, channel: result.room.name, inheritedGroupSource: inheritedSource)
                .id(target)
                .task(id: canRequestDetails ? target : nil) {
                    guard canRequestDetails, !Task.isCancelled, selection == .member(target),
                          findMember(target) != nil, let session = model.groupPermissionSession else { return }
                    session.requestMemberDetails(clientId: target.clientID, databaseId: target.databaseID,
                                                 generation: target.generation)
                }
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

    private func inheritedGroupSource(for member: RoomMember, in room: Room) -> String? {
        guard member.channelGroup != nil, let source = member.inheritedChannelGroupFrom, source != 0, source != room.id else { return nil }
        return model.room(source)?.name ?? "#\(source)"
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
        return target.find(in: model.channels)
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
        let showingPhoneSidebar = usesPhoneColumnNavigation && compactColumn == .sidebar
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
        if usesCompactNavigation {
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

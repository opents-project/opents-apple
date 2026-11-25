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
    @State private var managingIdentities = false
    @State private var testingMicrophone = false

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
                        if !room.audioSupported && model.currentChannel != room.id {
                            Label("Audio unavailable for this codec", systemImage: "speaker.slash")
                        }
                        LabeledContent("Channel type", value: NSLocalizedString(room.kind, comment: "Channel type"))
                        if room.subscribed || !room.members.isEmpty {
                            Section {
                                MemberPlaybackList(members: room.memberDetails, audio: model.audio)
                            } header: {
                                ViewThatFits(in: .horizontal) {
                                    HStack {
                                        Text("Visible members (\(room.members.count))")
                                        Spacer(minLength: 8)
                                        ConnectionQualityButton(audio: model.audio)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Visible members (\(room.members.count))")
                                        ConnectionQualityButton(audio: model.audio)
                                    }
                                }
                            }
                        }
                    }.formStyle(.grouped).navigationTitle(room.name)
                } else {
                    ContentUnavailableView("Select a channel", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .sheet(isPresented: $showingChat) { ChatView(model: model) }
            .safeAreaInset(edge: .bottom) {
                if let id = model.currentChannel, let room = find(id, in: model.channels), !room.audioSupported {
                    Label("Audio unavailable for this codec", systemImage: "speaker.slash")
                        .frame(maxWidth: .infinity).padding(10).background(.bar)
                } else { VoiceControls(audio: model.audio) }
            }
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

private struct ConnectionQualityButton: View {
    @ObservedObject var audio: VoiceAudio
    @State private var showingDetails = false

    private func ping(_ quality: ConnectionQuality?) -> String {
        guard let quality, let ms = quality.pingMs else { return "—" }
        return ms.formatted(.number.precision(.fractionLength(0))) + " ± "
            + quality.deviationMs.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private func loss(_ quality: ConnectionQuality?) -> String {
        quality?.incomingLoss?.formatted(.percent.precision(.fractionLength(0...1))) ?? "—"
    }

    private func rate(_ count: UInt64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .decimal) + "/s"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let quality = audio.voice?.connectionQuality()
            Button { showingDetails = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                    Text(verbatim: ping(quality))
                    Text("Loss \(loss(quality))")
                }
                .font(.caption).monospacedDigit().fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("My connection"))
            .accessibilityValue(Text("\(ping(quality)), packet loss \(loss(quality))"))
        }
        .popover(isPresented: $showingDetails) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let quality = audio.voice?.connectionQuality()
                VStack(alignment: .leading, spacing: 8) {
                    Text("My connection").font(.headline)
                    LabeledContent("Ping ± variation", value: ping(quality))
                    LabeledContent("Incoming packet loss", value: loss(quality))
                    LabeledContent("Receive rate", value: rate(quality?.incomingBytesPerSecond))
                    LabeledContent("Send rate", value: rate(quality?.outgoingBytesPerSecond))
                }
                .monospacedDigit().padding().frame(idealWidth: 300)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

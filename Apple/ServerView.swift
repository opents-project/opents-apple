import SwiftUI

struct ServerView: View {
    @ObservedObject var model: ServerModel
    @State private var selection: UInt64?

    @State private var lockedRoom: Room?
    @State private var password = ""

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
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
        } else {
            NavigationSplitView {
                List(selection: $selection) {
                    OutlineGroup(model.channels, children: \.children) { channel in
                        NavigationLink(value: channel.id) { Label(channel.room.name, systemImage: model.currentChannel == channel.id ? "person.wave.2.fill" : "bubble.left") }
                    }
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
                .navigationTitle(model.server)
                .toolbar { Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", action: model.disconnect) }
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
                        LabeledContent("Channel type", value: room.kind)
                        if room.subscribed || !room.members.isEmpty {
                            Section("Visible members (\(room.members.count))") {
                                ForEach(Array(room.members.enumerated()), id: \.offset) { _, name in
                                    Label(name, systemImage: "person")
                                }
                            }
                        }
                    }.formStyle(.grouped).navigationTitle(room.name)
                } else {
                    ContentUnavailableView("Select a channel", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .safeAreaInset(edge: .bottom) { VoiceControls(audio: model.audio) }
            .alert("Channel Password", isPresented: Binding(get: { lockedRoom != nil }, set: { if !$0 { lockedRoom = nil } }), presenting: lockedRoom) { room in
                SecureField("Password", text: $password)
                Button("Join") { model.join(room, password: password); password = "" }
                Button("Cancel", role: .cancel) { password = "" }
            } message: { Text($0.name) }
            .alert("Couldn’t Join Channel", isPresented: Binding(get: { model.joinError != nil }, set: { if !$0 { model.joinError = nil } })) {
                Button("OK") { model.joinError = nil }
            } message: { Text(model.joinError ?? "") }
            .onDisappear { selection = nil; lockedRoom = nil; password = "" }
        }
    }

    private func find(_ id: UInt64, in nodes: [ChannelNode]) -> Room? {
        for node in nodes {
            if node.id == id { return node.room }
            if let match = find(id, in: node.children ?? []) { return match }
        }
        return nil
    }
}

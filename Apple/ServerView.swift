import SwiftUI

struct ServerView: View {
    @ObservedObject var model: ServerModel
    @State private var selection: UInt64?

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
                    ProgressView("Connecting…")
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
                        NavigationLink(value: channel.id) { Label(channel.room.name, systemImage: "bubble.left") }
                    }
                }
                .navigationTitle(model.server)
                .toolbar { Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", action: model.disconnect) }
            } detail: {
                if let selection, let room = find(selection, in: model.channels) {
                    Form {
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
            .onDisappear { selection = nil }
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

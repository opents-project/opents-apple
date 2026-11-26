import SwiftUI

struct ServerView: View {
    @ObservedObject var model: ServerModel
    #if DEBUG
    @State private var showingFilesPreview = false
    @State private var showingLogPreview = false
    @State private var showingPermissionPreview = false
    #endif
    @State private var managingIdentities = false
    @State private var testingMicrophone = false

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
            ConnectedServerView(model: model)
        }
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
    let startChat: (RoomMember) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isExpandable {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })) {
                    if !node.room.memberDetails.isEmpty {
                        MemberPlaybackList(members: node.room.memberDetails, audio: audio, startChat: startChat)
                    }
                    if let children = node.children {
                        ChannelRows(nodes: children, current: current, expanded: $expanded, audio: audio, startChat: startChat)
                    }
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

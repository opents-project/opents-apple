import SwiftUI

struct ChannelEditorTarget: Identifiable {
    let id = UUID()
    let parent: UInt64
    let room: Room?
    let generation: UInt64
}

struct ChannelActionTarget: Identifiable {
    let room: Room
    let generation: UInt64
    var id: UInt64 { room.id }
}

struct ChannelManagementView: View {
    @ObservedObject var model: ServerModel
    let target: ChannelEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var descriptionDraft: String?
    @State private var descriptionError: String?
    @State private var loadingDescription = false
    @State private var lifetime: ChannelLifetime
    @State private var codec: ManagedCodec?
    @State private var passwordAction = PasswordAction.preserve
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?

    private enum PasswordAction { case preserve, replace, clear }

    init(model: ServerModel, target: ChannelEditorTarget) {
        self.model = model
        self.target = target
        _name = State(initialValue: target.room?.name ?? "")
        _descriptionDraft = State(initialValue: target.room == nil ? "" : nil)
        _lifetime = State(initialValue: Self.lifetime(for: target.room))
        _codec = State(initialValue: Self.codec(for: target.room))
    }

    private static func lifetime(for room: Room?) -> ChannelLifetime {
        switch room?.kind {
        case "Permanent": return .permanent
        case "SemiPermanent": return .semiPermanent
        default: return .temporary
        }
    }

    private static func codec(for room: Room?) -> ManagedCodec? {
        switch room?.codec {
        case "OpusVoice": return .voice
        case "OpusMusic": return .music
        default: return nil
        }
    }

    private var change: ChannelChange? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let room = target.room else {
            return .create(parent: target.parent, name: name, lifetime: lifetime, codec: codec, password: password, description: descriptionDraft ?? "")
        }
        let newPassword: String?
        switch passwordAction {
        case .preserve: newPassword = nil
        case .replace:
            guard !password.isEmpty else { return nil }
            newPassword = password
        case .clear: newPassword = ""
        }
        let newName = name == room.name ? nil : name
        let newLifetime = lifetime == Self.lifetime(for: room) ? nil : lifetime
        let newCodec = codec == Self.codec(for: room) ? nil : codec
        let newDescription = descriptionDraft == initialDescription ? nil : descriptionDraft
        guard newName != nil || newLifetime != nil || newCodec != nil || newPassword != nil || newDescription != nil else { return nil }
        return .edit(channel: room.id, name: newName, lifetime: newLifetime, codec: newCodec, password: newPassword, description: newDescription)
    }

    private var initialDescription: String? {
        target.room.flatMap { model.room($0.id)?.description }
    }

    private func loadDescription() async {
        guard let room = target.room, initialDescription == nil, !loadingDescription else { return }
        loadingDescription = true
        defer { loadingDescription = false }
        descriptionError = await model.readChannelDescription(room.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                if target.room == nil {
                    LabeledContent("Parent channel", value: model.room(target.parent)?.name ?? model.server)
                }
                TextField("Channel name", text: $name)
                Picker("Channel type", selection: $lifetime) {
                    Text("Temporary").tag(ChannelLifetime.temporary)
                    Text("Semi-permanent").tag(ChannelLifetime.semiPermanent)
                    Text("Permanent").tag(ChannelLifetime.permanent)
                }
                Picker("Audio codec", selection: $codec) {
                    if target.room == nil { Text("Server default").tag(nil as ManagedCodec?) }
                    if let room = target.room, Self.codec(for: room) == nil {
                        Text(room.codec).tag(nil as ManagedCodec?)
                    }
                    Text("Opus Voice").tag(Optional(ManagedCodec.voice))
                    Text("Opus Music").tag(Optional(ManagedCodec.music))
                }
                if let room = target.room {
                    Picker("Channel Password", selection: $passwordAction) {
                        Text("Keep current setting").tag(PasswordAction.preserve)
                        Text("Set new password").tag(PasswordAction.replace)
                        if room.passwordRequired { Text("Remove password").tag(PasswordAction.clear) }
                    }
                }
                if target.room == nil || passwordAction == .replace {
                    SecureField(target.room == nil ? "Password (optional)" : "New password", text: $password)
                }
                Section("Channel description") {
                    if target.room == nil || initialDescription != nil || descriptionDraft != nil {
                        TextEditor(text: Binding(
                            get: { descriptionDraft ?? initialDescription ?? "" },
                            set: { descriptionDraft = $0 }
                        ))
                        .frame(minHeight: 80)
                        .accessibilityLabel("Channel description")
                    } else if let descriptionError {
                        Text(descriptionError).foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadDescription() } }.disabled(loadingDescription)
                    } else {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Loading channel description")
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .disabled(saving)
            .navigationTitle(target.room == nil ? Text("Create channel") : Text("Edit channel"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let change else { return }
                        saving = true
                        error = nil
                        Task {
                            error = await model.changeChannel(change, generation: target.generation)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(saving || change == nil || model.reconnecting || model.generation != target.generation)
                }
            }
        }
        .task { await loadDescription() }
        .interactiveDismissDisabled(saving)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
    }
}

struct ChannelPlacementView: View {
    @ObservedObject var model: ServerModel
    let target: ChannelActionTarget
    @Environment(\.dismiss) private var dismiss
    @State private var parent: UInt64
    @State private var predecessor: UInt64
    @State private var moving = false
    @State private var error: String?

    init(model: ServerModel, target: ChannelActionTarget) {
        self.model = model
        self.target = target
        _parent = State(initialValue: target.room.parent)
        _predecessor = State(initialValue: target.room.predecessor)
    }

    private struct ParentChannel: Identifiable {
        let id: UInt64
        let path: String
        let children: [ChannelNode]
    }

    private var parents: [ParentChannel] {
        func list(_ nodes: [ChannelNode], under prefix: String) -> [ParentChannel] {
            nodes.flatMap { node -> [ParentChannel] in
                guard node.id != target.room.id else { return [] }
                let path = prefix.isEmpty ? node.room.name : "\(prefix) › \(node.room.name)"
                let children = node.children ?? []
                return [ParentChannel(id: node.id, path: path, children: children)] + list(children, under: path)
            }
        }
        return [ParentChannel(id: 0, path: model.server, children: model.channels)] + list(model.channels, under: "")
    }

    private var canMove: Bool {
        guard !moving, !model.reconnecting, model.generation == target.generation,
              let room = model.room(target.room.id),
              let destination = parents.first(where: { $0.id == parent }),
              parent != room.parent || predecessor != room.predecessor else { return false }
        return predecessor == 0 || destination.children.contains { $0.id == predecessor && $0.id != room.id }
    }

    var body: some View {
        let destinations = parents
        let siblings = destinations.first(where: { $0.id == parent })?.children ?? []
        NavigationStack {
            Form {
                LabeledContent("Channel name", value: target.room.name)
                Picker("Parent channel", selection: $parent) {
                    ForEach(destinations) { option in
                        Text(verbatim: option.path).tag(option.id)
                    }
                }
                Picker("Channel position", selection: $predecessor) {
                    Text("First in list").tag(UInt64(0))
                    ForEach(siblings.filter { $0.id != target.room.id }) { node in
                        Text("After \(node.room.name)").tag(node.id)
                    }
                }
                if let error {
                    Text(NSLocalizedString(error, comment: "Channel move error"))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .disabled(moving)
            .navigationTitle("Move channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(moving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { Task { await move() } }.disabled(!canMove)
                }
            }
        }
        .onChange(of: parent) { _, _ in predecessor = 0 }
        .interactiveDismissDisabled(moving)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 235)
        #endif
    }

    private func move() async {
        guard canMove else { return }
        moving = true
        error = await model.changeChannel(.move(channel: target.room.id, parent: parent, predecessor: predecessor),
                                          generation: target.generation)
        moving = false
        if error == nil { dismiss() }
    }
}

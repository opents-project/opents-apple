import SwiftUI

struct ChannelEditorTarget: Identifiable {
    let id = UUID()
    let parent: UInt64
    let room: Room?
    let generation: UInt64
}

struct ChannelManagementView: View {
    @ObservedObject var model: ServerModel
    let target: ChannelEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
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
            return .create(parent: target.parent, name: name, lifetime: lifetime, codec: codec, password: password)
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
        guard newName != nil || newLifetime != nil || newCodec != nil || newPassword != nil else { return nil }
        return .edit(channel: room.id, name: newName, lifetime: newLifetime, codec: newCodec, password: newPassword)
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
        .interactiveDismissDisabled(saving)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
    }
}

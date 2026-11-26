import SwiftUI

struct LiveGroupPermissionsView: View {
    let session: Session
    let generation: UInt64
    let initialGroup: ListedGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var kind = GroupKind.server
    @State private var groups = [ListedGroup]()
    @State private var loading = true
    @State private var error: String?

    init(session: Session, generation: UInt64, initialGroup: ListedGroup? = nil) {
        self.session = session
        self.generation = generation
        self.initialGroup = initialGroup
    }

    var body: some View {
        NavigationStack {
            if let initialGroup {
                GroupPermissionList(session: session, generation: generation, group: initialGroup, allowsEditing: false)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    }
            } else {
                groupDirectory
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private var groupDirectory: some View {
        List {
            Picker("Group type", selection: $kind) {
                Text("Server groups").tag(GroupKind.server)
                Text("Channel groups").tag(GroupKind.channel)
            }.pickerStyle(.segmented).disabled(loading)
            if loading { ProgressView() }
            else if let error { Text(verbatim: error).foregroundStyle(.red) }
            else if groups.isEmpty { Text("No groups returned.") }
            else {
                ForEach(groups, id: \.id) { group in
                    NavigationLink {
                        GroupPermissionList(session: session, generation: generation, group: group)
                    } label: {
                        LabeledContent { Text(verbatim: "#\(group.id)") } label: { Text(verbatim: group.name) }
                    }
                }
            }
        }
        .navigationTitle("Group permissions")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        }
        .task(id: kind) { await load() }
    }

    @MainActor private func load() async {
        let requestedKind = kind
        loading = true
        groups = []
        let response = await session.listGroups(kind: requestedKind, generation: generation)
        guard !Task.isCancelled, requestedKind == kind else { return }
        error = response.error
        groups = response.groups
        loading = false
    }
}

private struct GroupPermissionList: View {
    let session: Session
    let generation: UInt64
    let group: ListedGroup
    var allowsEditing = true
    @State private var permissions = [GroupPermission]()
    @State private var error: String?
    @State private var loading = true
    @State private var editor: PermissionEditorTarget?

    var body: some View {
        List {
            if loading { ProgressView() }
            else if let error { Text(verbatim: error).foregroundStyle(.red) }
            else if permissions.isEmpty { Text("No permissions returned.") }
            else {
                ForEach(permissions, id: \.id) { permission in
                    if allowsEditing {
                        Button { editor = PermissionEditorTarget(permission: permission) } label: {
                            permissionRow(permission)
                        }.buttonStyle(.plain)
                    } else {
                        permissionRow(permission)
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
                if allowsEditing {
                    Button("Add permission", systemImage: "plus") { editor = PermissionEditorTarget(permission: nil) }
                        .disabled(loading || error != nil)
                }
            }
        }
        .task { await load() }
        .sheet(item: $editor) { target in
            GroupPermissionEditor(session: session, generation: generation, group: group, initial: target.permission, existingIDs: Set(permissions.map(\.id))) {
                editor = nil
                await load()
            }
        }
    }

    private func permissionRow(_ permission: GroupPermission) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: permission.name ?? "#\(permission.id)")
                if permission.negated { Text("Negated").font(.caption) }
                if permission.skip { Text("Skip").font(.caption) }
            }
            Spacer()
            Text(verbatim: String(permission.value)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @MainActor private func load() async {
        loading = true
        let response = await session.listGroupPermissions(kind: group.kind, group: group.id, generation: generation)
        guard !Task.isCancelled else { return }
        error = response.error
        permissions = response.permissions
        loading = false
    }
}

private struct PermissionEditorTarget: Identifiable {
    let id = UUID()
    let permission: GroupPermission?
}

private struct GroupPermissionEditor: View {
    let session: Session
    let generation: UInt64
    let group: ListedGroup
    let initial: GroupPermission?
    let existingIDs: Set<UInt32>
    let saved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var value = ""
    @State private var negated = false
    @State private var skip = false
    @State private var saving = false
    @State private var removing = false
    @State private var error: String?

    private var valid: Bool {
        guard let id = UInt32(identifier), id > 0, Int32(value) != nil else { return false }
        return initial != nil || !existingIDs.contains(id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let initial { LabeledContent("Permission ID", value: String(initial.id)) }
                    else { TextField("Permission ID", text: $identifier) }
                    TextField("Permission value", text: $value)
                    if group.kind == .server {
                        Toggle("Negated", isOn: $negated)
                        Toggle("Skip", isOn: $skip)
                    }
                } header: { Text(verbatim: group.name) }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
                if initial != nil {
                    Button("Remove permission", role: .destructive) { removing = true }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            .navigationTitle("Group permission")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await submit(remove: false) } }.disabled(!valid || saving) }
            }
            .confirmationDialog("Remove permission?", isPresented: $removing) {
                Button("Remove permission", role: .destructive) { Task { await submit(remove: true) } }
            } message: { Text(verbatim: "\(group.name) · #\(identifier)") }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            if let initial {
                identifier = String(initial.id)
                value = String(initial.value)
                negated = initial.negated
                skip = initial.skip
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 300)
        #endif
    }

    @MainActor private func submit(remove: Bool) async {
        guard !saving, valid, let id = UInt32(identifier), let number = Int32(value) else { return }
        saving = true
        let response: GroupPermissionResponse
        if remove {
            response = await session.removeGroupPermission(kind: group.kind, group: group.id, permissionId: id, generation: generation)
        } else {
            let row = GroupPermission(id: id, name: nil, value: number, negated: group.kind == .server && negated, skip: group.kind == .server && skip)
            response = await session.setGroupPermission(kind: group.kind, group: group.id, permission: row, generation: generation)
        }
        error = response.error
        if error == nil { await saved() }
        saving = false
    }
}

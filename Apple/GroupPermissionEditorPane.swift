import SwiftUI

#if os(macOS)
struct GroupPermissionEditorPane: View {
    let kind: GroupKind
    let permissions: [GroupPermission]
    let definitions: [UInt32: PermissionDefinition]
    let setPermission: (GroupPermission) -> Void
    let removePermission: (UInt32) -> Void

    @State private var mode: EditorMode = .common
    @State private var search = ""
    @State private var editing: PermissionDraftTarget?
    @State private var removing: GroupPermission?
    @State private var expandedCommonSections: Set<String> = [CommonPermissionSection.basicsTitle]

    private enum EditorMode: String, CaseIterable, Identifiable {
        case common = "Common"
        case advanced = "Advanced"
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .common: "Common"
            case .advanced: "Advanced"
            }
        }
    }

    private var isServer: Bool {
        if case .server = kind { return true }
        return false
    }

    private var assignedByID: [UInt32: GroupPermission] {
        Dictionary(permissions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var orderedPermissions: [GroupPermission] {
        permissions.sorted { lhs, rhs in
            let left = definitions[lhs.id]?.name ?? lhs.name ?? ""
            let right = definitions[rhs.id]?.name ?? rhs.name ?? ""
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private var filteredPermissions: [GroupPermission] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return orderedPermissions }
        return orderedPermissions.filter { permission in
            let definition = definitions[permission.id]
            return String(permission.id).contains(term.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
                || definition?.name.localizedCaseInsensitiveContains(term) == true
                || definition?.description?.localizedCaseInsensitiveContains(term) == true
                || permission.name?.localizedCaseInsensitiveContains(term) == true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Permission view", selection: $mode) {
                ForEach(EditorMode.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Permission view")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if mode == .common {
                commonPermissions
            } else {
                advancedPermissions
            }
        }
        .background(.background)
        .sheet(item: $editing) { target in
            PermissionDraftEditor(
                kind: kind,
                initial: target.permission,
                preselectedID: target.definitionID,
                definitions: definitions,
                assignedIDs: Set(permissions.map(\.id)),
                onSave: setPermission
            )
        }
        .confirmationDialog(
            "Remove this permission?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { permission in
            Button("Remove Permission", role: .destructive) {
                removePermission(permission.id)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { permission in
            Text(permissionTitle(permission))
        }
        .frame(minWidth: 420, minHeight: 340)
    }

    private var commonPermissions: some View {
        let byName = Dictionary(definitions.values.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let configured = assignedByID
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(CommonPermissionSection.sections, id: \.title) { section in
                    let available = section.names.compactMap { byName[$0] }
                    if !available.isEmpty {
                        commonSection(section, available: available, configured: configured)
                    }
                }

                if !CommonPermissionSection.sections.contains(where: { $0.names.contains { byName[$0] != nil } }) {
                    ContentUnavailableView("No common permissions available", systemImage: "checklist",
                                           description: Text("The server did not provide definitions for the curated common permissions."))
                        .padding(20)
                }
            }
        }
    }

    private func commonSection(_ section: CommonPermissionSection, available: [PermissionDefinition],
                               configured: [UInt32: GroupPermission]) -> some View {
        let expanded = Binding(get: { expandedCommonSections.contains(section.title) }, set: { visible in
            if visible { expandedCommonSections.insert(section.title) }
            else { expandedCommonSections.remove(section.title) }
        })
        return DisclosureGroup(isExpanded: expanded) {
            ForEach(available, id: \.id) { definition in
                commonRow(definition)
            }
        } label: {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(section.title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !expanded.wrappedValue, let summary = commonSummary(section, available: available, configured: configured) {
                    summary.font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(summary)
                }
            }
            .frame(minHeight: 24)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    private func commonSummary(_ section: CommonPermissionSection, available: [PermissionDefinition],
                               configured: [UInt32: GroupPermission]) -> Text? {
        let configuredCount = available.filter { configured[$0.id] != nil }.count
        guard configuredCount > 0 else { return nil }
        if section.title == CommonPermissionSection.moderationTitle {
            let thresholds = CommonPermissionSection.moderationThresholds.compactMap { name in
                available.first(where: { $0.name == name }).flatMap { configured[$0.id]?.value }
            }
            if thresholds.count == CommonPermissionSection.moderationThresholds.count,
               let power = thresholds.first, thresholds.allSatisfy({ $0 == power }) {
                return Text("Required power to kick, ban, or move: \(Int(power))")
            }
        }
        return Text("\(configuredCount) configured")
    }

    @ViewBuilder private func commonRow(_ definition: PermissionDefinition) -> some View {
        let current = assignedByID[definition.id]
        if definition.name == "i_group_show_name_in_tree" {
            namingModeRow(definition, current: current)
        } else if definition.name.hasPrefix("b_") {
            booleanRow(definition, current: current)
        } else {
            powerRow(definition, current: current)
        }
    }

    private func booleanRow(_ definition: PermissionDefinition, current: GroupPermission?) -> some View {
        let selection = Binding<CommonBooleanState>(
            get: { booleanState(current) },
            set: { newValue in updateBoolean(definition, current: assignedByID[definition.id], state: newValue) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                commonTitle(definition)
                Spacer(minLength: 8)
                Picker(definition.name, selection: selection) {
                    Text("Unset").tag(CommonBooleanState.unset)
                    Text("Allow").tag(CommonBooleanState.allow)
                    Text("Deny").tag(CommonBooleanState.deny)
                }
                .labelsHidden()
                .frame(width: 124)
            }
        }
        .padding(.trailing, 4)
        .padding(.vertical, 7)
    }

    private func powerRow(_ definition: PermissionDefinition, current: GroupPermission?) -> some View {
        HStack(spacing: 12) {
            commonTitle(definition)
            Spacer(minLength: 8)
            if let current {
                Text(verbatim: String(current.value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                editing = PermissionDraftTarget(permission: current, definitionID: definition.id)
            } label: {
                if current == nil { Text("Set value") }
                else { Text("Edit value") }
            }
            if let current {
                Button("Clear setting") { removePermission(current.id) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.trailing, 4)
        .padding(.vertical, 7)
    }

    private func namingModeRow(_ definition: PermissionDefinition, current: GroupPermission?) -> some View {
        let selection = Binding<GroupNamingChoice>(
            get: { GroupNamingChoice(value: current?.value, assigned: current != nil) },
            set: { choice in
                switch choice {
                case .unset:
                    removePermission(definition.id)
                case .hidden, .beforeName, .afterName:
                    setPermission(GroupPermission(id: definition.id, name: definition.name,
                                                  value: choice.value,
                                                  negated: isServer ? (current?.negated ?? false) : false,
                                                  skip: isServer ? (current?.skip ?? false) : false))
                case .other:
                    break
                }
            }
        )
        return HStack(spacing: 12) {
            commonTitle(definition)
            Spacer(minLength: 8)
            Picker(definition.name, selection: selection) {
                Text("Unset").tag(GroupNamingChoice.unset)
                Text("Hidden").tag(GroupNamingChoice.hidden)
                Text("Before name").tag(GroupNamingChoice.beforeName)
                Text("After name").tag(GroupNamingChoice.afterName)
                if case .other(let value) = selection.wrappedValue {
                    Text("Other value (#\(value))").tag(GroupNamingChoice.other(value))
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.trailing, 4)
        .padding(.vertical, 7)
    }

    private func commonTitle(_ definition: PermissionDefinition) -> some View {
        let title = CommonPermissionSection.label(for: definition.name) ?? definition.name
        let help = definition.description.flatMap { $0.isEmpty ? nil : $0 } ?? definition.name
        return Text(LocalizedStringKey(title))
            .help(Text(verbatim: help))
    }

    private var advancedPermissions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search names, descriptions, or IDs", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Button("Add Permission") { editing = PermissionDraftTarget(permission: nil, definitionID: nil) }
                    .disabled(!definitions.isEmpty && definitions.values.allSatisfy { assignedByID[$0.id] != nil })
            }
            .padding(12)

            Divider()

            if filteredPermissions.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No permissions assigned" : "No matching permissions",
                                       systemImage: "checklist")
            } else {
                List(filteredPermissions, id: \.id) { permission in
                    advancedRow(permission)
                }
                .listStyle(.plain)
            }
        }
    }

    private func advancedRow(_ permission: GroupPermission) -> some View {
        let definition = definitions[permission.id]
        return HStack(alignment: .top, spacing: 12) {
            PermissionTitle(definition: definition, fallbackName: permission.name, id: permission.id)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Value: \(permission.value)").monospacedDigit()
                if isServer && permission.negated { Text("Negated").foregroundStyle(.secondary) }
                if isServer && permission.skip { Text("Skip").foregroundStyle(.secondary) }
            }
            .font(.caption)
            Menu {
                Button("Edit…", systemImage: "pencil") {
                    editing = PermissionDraftTarget(permission: permission, definitionID: permission.id)
                }
                Button("Remove…", systemImage: "trash", role: .destructive) { removing = permission }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 3)
    }

    private func booleanState(_ permission: GroupPermission?) -> CommonBooleanState {
        guard let permission else { return .unset }
        return permission.value != 0 ? .allow : .deny
    }

    private func updateBoolean(_ definition: PermissionDefinition, current: GroupPermission?, state: CommonBooleanState) {
        switch state {
        case .unset:
            removePermission(definition.id)
        case .allow:
            guard booleanState(current) != .allow else { return }
            setPermission(GroupPermission(id: definition.id, name: definition.name,
                                          value: 1, negated: current?.negated ?? false,
                                          skip: current?.skip ?? false))
        case .deny:
            guard booleanState(current) != .deny else { return }
            setPermission(GroupPermission(id: definition.id, name: definition.name,
                                          value: 0, negated: current?.negated ?? false,
                                          skip: current?.skip ?? false))
        }
    }

    private func permissionTitle(_ permission: GroupPermission) -> String {
        definitions[permission.id]?.name ?? permission.name ?? "Permission #\(permission.id)"
    }
}

private enum CommonBooleanState: String, CaseIterable, Identifiable {
    case unset, allow, deny
    var id: Self { self }
}

private enum GroupNamingChoice: Hashable {
    case unset, hidden, beforeName, afterName, other(Int32)

    init(value: Int32?, assigned: Bool) {
        guard assigned, let value else { self = .unset; return }
        switch value {
        case 0: self = .hidden
        case 1: self = .beforeName
        case 2: self = .afterName
        default: self = .other(value)
        }
    }

    var value: Int32 {
        switch self {
        case .hidden: 0
        case .beforeName: 1
        case .afterName: 2
        case .unset, .other: 0
        }
    }
}

private struct CommonPermissionSection {
    let title: String
    let names: [String]

    static let basicsTitle = "Basics"
    static let moderationTitle = "Member moderation"
    static let moderationThresholds = [
        "i_client_needed_kick_from_server_power", "i_client_needed_ban_power", "i_client_needed_move_power"
    ]

    static let sections = [
        CommonPermissionSection(title: basicsTitle, names: [
            "i_client_talk_power", "i_client_needed_talk_power",
            "b_client_channel_textmessage_send", "b_client_server_textmessage_send"
        ]),
        CommonPermissionSection(title: "Server", names: [
            "b_virtualserver_modify_name", "b_virtualserver_modify_welcomemessage",
            "b_virtualserver_servergroup_create", "b_virtualserver_servergroup_delete"
        ]),
        CommonPermissionSection(title: "Groups and members", names: [
            "i_group_member_add_power", "i_group_needed_member_add_power",
            "i_group_member_remove_power", "i_group_needed_member_remove_power",
            "i_group_show_name_in_tree"
        ]),
        CommonPermissionSection(title: moderationTitle, names: [
            "i_client_kick_from_server_power", "i_client_needed_kick_from_server_power",
            "i_client_ban_power", "i_client_needed_ban_power", "i_client_move_power",
            "i_client_needed_move_power", "b_client_use_reserved_slot"
        ]),
        CommonPermissionSection(title: "Channel management", names: [
            "i_channel_join_power", "i_channel_needed_join_power", "i_channel_modify_power",
            "i_channel_needed_modify_power", "b_channel_create_child", "b_channel_modify_topic"
        ]),
        CommonPermissionSection(title: "Communication", names: [
            "i_client_whisper_power",
            "i_client_private_textmessage_power", "i_client_needed_private_textmessage_power",
            "b_client_request_talker", "b_client_skip_channelgroup_permissions"
        ]),
        CommonPermissionSection(title: "File transfer", names: [
            "i_ft_file_browse_power", "i_ft_file_upload_power", "i_ft_file_download_power",
            "i_ft_file_delete_power", "i_ft_file_rename_power", "i_ft_directory_create_power"
        ])
    ]

    static func label(for name: String) -> String? { labels[name] }

    private static let labels: [String: String] = [
        "b_virtualserver_modify_name": "Modify server name",
        "b_virtualserver_modify_welcomemessage": "Modify welcome message",
        "b_virtualserver_servergroup_create": "Create server groups",
        "b_virtualserver_servergroup_delete": "Delete server groups",
        "i_group_member_add_power": "Group member add power",
        "i_group_needed_member_add_power": "Required power to add group members",
        "i_group_member_remove_power": "Group member remove power",
        "i_group_needed_member_remove_power": "Required power to remove group members",
        "i_group_show_name_in_tree": "Show group name in channel tree",
        "i_client_kick_from_server_power": "Kick from server power",
        "i_client_needed_kick_from_server_power": "Required power to kick from server",
        "i_client_ban_power": "Client ban power",
        "i_client_needed_ban_power": "Required power to ban clients",
        "i_client_move_power": "Client move power",
        "i_client_needed_move_power": "Required power to move clients",
        "b_client_use_reserved_slot": "Use a reserved slot",
        "i_channel_join_power": "Channel join power",
        "i_channel_needed_join_power": "Required power to join channels",
        "i_channel_modify_power": "Channel modify power",
        "i_channel_needed_modify_power": "Required power to modify channels",
        "b_channel_create_child": "Create sub-channels",
        "b_channel_modify_topic": "Modify channel topic",
        "i_client_talk_power": "Client talk power",
        "i_client_needed_talk_power": "Required power to speak",
        "i_client_whisper_power": "Client whisper power",
        "i_client_private_textmessage_power": "Private message power",
        "i_client_needed_private_textmessage_power": "Required power to send private messages",
        "b_client_channel_textmessage_send": "Send channel messages",
        "b_client_server_textmessage_send": "Send server messages",
        "b_client_request_talker": "Request talk power",
        "b_client_skip_channelgroup_permissions": "Ignore channel group permissions",
        "i_ft_file_browse_power": "File browse power",
        "i_ft_file_upload_power": "File upload power",
        "i_ft_file_download_power": "File download power",
        "i_ft_file_delete_power": "File delete power",
        "i_ft_file_rename_power": "File rename power",
        "i_ft_directory_create_power": "Create directory power"
    ]
}

private struct PermissionTitle: View {
    let definition: PermissionDefinition?
    var label: String? = nil
    var fallbackName: String? = nil
    var id: UInt32? = nil
    var showsIdentifier = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let label { Text(LocalizedStringKey(label)) }
                else { Text(readableName) }
            }
            .font(.body)
            if let description = definition?.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if showsIdentifier {
                Text("#\(definition?.id ?? id ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }

    private var readableName: String {
        definition?.name ?? fallbackName ?? "Permission #\(id ?? 0)"
    }
}

private struct PermissionDraftTarget: Identifiable {
    let id = UUID()
    let permission: GroupPermission?
    let definitionID: UInt32?
}

private struct PermissionDraftEditor: View {
    let kind: GroupKind
    let initial: GroupPermission?
    let preselectedID: UInt32?
    let definitions: [UInt32: PermissionDefinition]
    let assignedIDs: Set<UInt32>
    let onSave: (GroupPermission) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var manualID = ""
    @State private var selectedID: UInt32?
    @State private var value = ""
    @State private var negated = false
    @State private var skip = false

    private var isServer: Bool {
        if case .server = kind { return true }
        return false
    }

    private var choices: [PermissionDefinition] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return definitions.values
            .filter { definition in
                (definition.id == initial?.id || !assignedIDs.contains(definition.id))
                    && (term.isEmpty || definition.name.localizedCaseInsensitiveContains(term)
                        || definition.description?.localizedCaseInsensitiveContains(term) == true
                        || String(definition.id) == term.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
            }
            .sorted { $0.id < $1.id }
    }

    private var selectedDefinition: PermissionDefinition? {
        selectedID.flatMap { definitions[$0] }
    }

    private var valid: Bool {
        selectedID != nil && Int32(value) != nil
    }

    private var validManualID: UInt32? {
        guard let id = UInt32(manualID), id > 0, !assignedIDs.contains(id) else { return nil }
        return id
    }

    var body: some View {
        VStack(spacing: 0) {
            if initial == nil && preselectedID == nil {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search names, descriptions, or IDs", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(12)
                Divider()
                if definitions.isEmpty {
                    Form {
                        Text("The server permission catalog is unavailable. Enter an ID supplied by the server or administrator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Permission ID", text: $manualID)
                            .textFieldStyle(.roundedBorder)
                        Button("Use ID") {
                            selectedID = validManualID
                            if value.isEmpty { value = "0" }
                        }
                        .disabled(validManualID == nil)
                    }
                    .formStyle(.grouped)
                    .frame(maxHeight: 190)
                } else {
                    if choices.isEmpty {
                        ContentUnavailableView("No matching permissions", systemImage: "magnifyingglass")
                    } else {
                        List(choices, id: \.id) { definition in
                            Button {
                                selectedID = definition.id
                                value = "0"
                            } label: {
                                HStack {
                                    PermissionTitle(definition: definition)
                                    Spacer()
                                    if selectedID == definition.id { Image(systemName: "checkmark") }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                }
            } else if let initial {
                PermissionTitle(definition: selectedDefinition, fallbackName: initial.name, id: initial.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else if let preselectedID, let definition = definitions[preselectedID] {
                PermissionTitle(definition: definition, label: CommonPermissionSection.label(for: definition.name),
                               showsIdentifier: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }

            Divider()
            Form {
                TextField("Permission value", text: $value)
                    .textFieldStyle(.roundedBorder)
                if isServer {
                    Toggle("Negated", isOn: $negated)
                    Toggle("Skip", isOn: $skip)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 160)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save to Draft") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(12)
        }
        .frame(width: 480, height: initial == nil && preselectedID == nil ? 500 : 260)
        .onAppear {
            if let initial {
                selectedID = initial.id
                value = String(initial.value)
                negated = initial.negated
                skip = initial.skip
            } else if let preselectedID {
                selectedID = preselectedID
                value = "0"
            }
        }
    }

    private func save() {
        guard let id = selectedID, let parsed = Int32(value) else { return }
        let definition = definitions[id]
        let useFlags = isServer
        onSave(GroupPermission(
            id: id,
            name: definition?.name ?? initial?.name,
            value: parsed,
            negated: useFlags ? negated : false,
            skip: useFlags ? skip : false
        ))
        dismiss()
    }
}
#endif

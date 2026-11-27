import SwiftUI

#if os(macOS)
struct PermissionDirectoryWindow: View {
    static let windowID = "permissions"
    @ObservedObject var tabs: ServerTabs
    @Environment(\.dismissWindow) private var dismissWindow

    private var directory: ServerTabs.PermissionDirectory? {
        guard let request = tabs.permissionDirectory else { return nil }
        let model = tabs.selected.model
        guard model.groupPermissionSession === request.session,
              model.groupPermissionGeneration == request.generation else { return nil }
        return request
    }

    var body: some View {
        Group {
            if let directory {
                LiveGroupPermissionsView(session: directory.session, generation: directory.generation,
                                         serverName: directory.server, model: tabs.selected.model,
                                         isCurrent: { self.directory?.id == directory.id })
                    .id(directory.id)
            }
        }
        .onChange(of: directory?.id, initial: true) { _, id in
            if id == nil {
                tabs.permissionDirectory = nil
                dismissWindow(id: Self.windowID)
            }
        }
    }
}

private struct LiveGroupPermissionsView: View {
    let session: Session
    let generation: UInt64
    let serverName: String
    @ObservedObject var model: ServerModel
    let isCurrent: @MainActor () -> Bool

    @State private var kind = GroupKind.server
    @State private var groups: [ListedGroup] = []
    @State private var defaultGroup: UInt64?
    @State private var groupID: UInt64?
    @State private var rules: [UInt32: GroupPermission] = [:]
    @State private var drafts: [UInt32: RuleChange] = [:]
    @State private var definitions: [UInt32: PermissionDefinition] = [:]
    @State private var loadedDefinitions = false
    @State private var roster: [ServerGroupMember] = []
    @State private var directoryError: String?
    @State private var ruleError: String?
    @State private var rosterError: String?
    @State private var actionError: String?
    @State private var loadingRules = false
    @State private var loadingRoster = false
    @State private var busy = false
    @State private var pendingNavigation: Navigation?
    @State private var groupNameChange: NameChange?
    @State private var groupToDelete: ListedGroup?
    @State private var memberToChange: MembershipRequest?

    private enum RuleChange {
        case set(GroupPermission)
        case remove
    }

    private enum Navigation {
        case kind(GroupKind)
        case select(UInt64?)
        case reload
        case name(NameChange)
        case delete(ListedGroup)
    }

    private enum NameChange: Identifiable {
        case create
        case rename(ListedGroup)
        case copy(ListedGroup)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let group): "rename-\(group.id)"
            case .copy(let group): "copy-\(group.id)"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .create: "Add group"
            case .rename: "Rename group"
            case .copy: "Copy group"
            }
        }

        var initialName: String {
            if case .rename(let group) = self { return group.name }
            return ""
        }
    }

    private enum RosterChange {
        case add(RoomMember)
        case remove(ServerGroupMember)
    }

    private struct MembershipRequest {
        let group: ListedGroup
        let change: RosterChange
    }

    private var selectedGroup: ListedGroup? { groups.first { $0.id == groupID } }

    private var editableRules: [GroupPermission] {
        var result = rules
        for (id, draft) in drafts {
            switch draft {
            case .set(let permission): result[id] = permission
            case .remove: result[id] = nil
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 260)
        } detail: {
            if kind == .server {
                HSplitView {
                    editor.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    if let selectedGroup {
                        ServerGroupRosterView(members: roster, candidates: visibleMembers, loading: loadingRoster,
                                              error: rosterError, isDefault: selectedGroup.id == defaultGroup,
                                              disabled: busy, reload: { Task { await refreshRoster() } },
                                              add: { requestMembership(.add($0)) },
                                              remove: { requestMembership(.remove($0)) })
                            .id(selectedGroup.id)
                            .frame(minWidth: 190, idealWidth: 225, maxWidth: 320, maxHeight: .infinity)
                    }
                }
            } else {
                editor
            }
        }
        .navigationTitle("Permissions · \(serverName)")
        .frame(minWidth: 820, minHeight: 470)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button("Refresh", systemImage: "arrow.clockwise") { request(.reload) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .accessibilityLabel("Refresh")
                        .disabled(busy)
                    Button("Discard") { drafts.removeAll(); actionError = nil }
                        .buttonStyle(.bordered)
                        .disabled(drafts.isEmpty || busy)
                    Button("Apply") { Task { await applyDrafts() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(drafts.isEmpty || busy)
                }
                .controlSize(.small)
            }
        }
        .task { await reloadDirectory() }
        .alert("Discard unsaved permission changes?", isPresented: Binding(get: { pendingNavigation != nil }, set: { visible in
            if !visible { pendingNavigation = nil }
        }), presenting: pendingNavigation) { action in
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) {
                pendingNavigation = nil
                drafts.removeAll()
                navigate(action)
            }
        }
        .sheet(item: $groupNameChange) { change in
            GroupNameSheet(title: change.title, initialName: change.initialName) { name in
                groupNameChange = nil
                Task { await updateName(change, name: name) }
            }
        }
        .alert("Delete group?", isPresented: Binding(get: { groupToDelete != nil }, set: { visible in
            if !visible { groupToDelete = nil }
        }), presenting: groupToDelete) { group in
            Button("Cancel", role: .cancel) { }
            Button("Delete group", role: .destructive) {
                groupToDelete = nil
                Task { await deleteGroup(group) }
            }
        } message: { group in
            Text(verbatim: group.name)
        }
        .alert("Change Your Groups?", isPresented: Binding(get: { memberToChange != nil }, set: { visible in
            if !visible { memberToChange = nil }
        }), presenting: memberToChange) { request in
            Button("Cancel", role: .cancel) { }
            Button("Change Group") {
                memberToChange = nil
                Task { await updateMembership(request, confirmed: true) }
            }
        } message: { request in
            switch request.change {
            case .add:
                Text("Add yourself to \(request.group.name)? This may change your permissions on this server.")
            case .remove:
                Text("Remove yourself from \(request.group.name)? This may change your permissions on this server.")
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Group type", selection: Binding(get: { kind }, set: { request(.kind($0)) })) {
                Text("Server groups").tag(GroupKind.server)
                Text("Channel groups").tag(GroupKind.channel)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Group type")
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .disabled(busy)

            List(selection: Binding(get: { groupID }, set: { request(.select($0)) })) {
                if let directoryError {
                    Text(verbatim: directoryError).foregroundStyle(.red)
                } else if groups.isEmpty {
                    if busy { ProgressView().controlSize(.small) }
                    else { Text("No groups returned.").foregroundStyle(.secondary) }
                }
                ForEach(groups, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: group.name).lineLimit(1)
                        if group.id == defaultGroup {
                            Text("Default group").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(group.id)
                    .contextMenu {
                        Button("Rename group") { request(.name(.rename(group))) }
                        Button("Copy group") { request(.name(.copy(group))) }
                        Button("Delete group", role: .destructive) { request(.delete(group)) }
                            .disabled(group.id == defaultGroup)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(busy)

            Divider()
            Button("Add group", systemImage: "plus") { request(.name(.create)) }
                .disabled(busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedGroup {
                HStack {
                    Text(verbatim: selectedGroup.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                if loadingRules {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let ruleError {
                    if ruleError.hasPrefix("PermissionsClientInsufficient") {
                        ContentUnavailableView("Permission denied", systemImage: "lock",
                                               description: Text(verbatim: ruleError))
                    } else {
                        ContentUnavailableView("Group permissions", systemImage: "exclamationmark.triangle",
                                               description: Text(verbatim: ruleError))
                    }
                } else {
                    GroupPermissionEditorPane(kind: kind, permissions: editableRules, definitions: definitions,
                                              setPermission: setDraft, removePermission: removeDraft)
                        .id(selectedGroup.id)
                        .disabled(busy)
                }
            } else {
                ContentUnavailableView("Select a group", systemImage: "person.2")
            }
            if let actionError {
                Divider()
                ScrollView {
                    Text(verbatim: actionError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 92)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleMembers: [RoomMember] {
        func members(in nodes: [ChannelNode]) -> [RoomMember] {
            nodes.flatMap { $0.room.memberDetails + members(in: $0.children ?? []) }
        }
        var seen = Set(roster.map(\.databaseId))
        return members(in: model.channels)
            .filter { $0.databaseId != 0 && seen.insert($0.databaseId).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func request(_ action: Navigation) {
        guard !busy, isCurrent() else { return }
        switch action {
        case .kind(let requested) where requested == kind: return
        case .select(let requested) where requested == groupID: return
        default: break
        }
        if drafts.isEmpty { navigate(action) }
        else { pendingNavigation = action }
    }

    private func navigate(_ action: Navigation) {
        actionError = nil
        switch action {
        case .kind(let requested):
            kind = requested
            resetSelection()
            groups = []
            defaultGroup = nil
            Task { await reloadDirectory() }
        case .select(let id):
            Task { await selectGroup(id) }
        case .reload:
            Task { await reloadDirectory(preferred: groupID) }
        case .name(let change): groupNameChange = change
        case .delete(let group): groupToDelete = group
        }
    }

    private func setDraft(_ permission: GroupPermission) {
        guard !busy, isCurrent() else { return }
        if let current = rules[permission.id], current.value == permission.value,
           current.negated == permission.negated, current.skip == permission.skip {
            drafts[permission.id] = nil
        } else {
            drafts[permission.id] = .set(permission)
        }
    }

    private func removeDraft(_ id: UInt32) {
        guard !busy, isCurrent() else { return }
        drafts[id] = rules[id] == nil ? nil : .remove
    }

    private func resetSelection() {
        groupID = nil
        rules = [:]
        drafts = [:]
        roster = []
        ruleError = nil
        rosterError = nil
    }

    private func reloadDirectory(preferred: UInt64? = nil) async {
        guard !busy, isCurrent(), !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        await loadDirectory(preferred: preferred)
    }

    // All calls that touch the shared group command stream run under busy.
    private func loadDirectory(preferred: UInt64?, newName: String? = nil) async {
        let requestedKind = kind
        let previousIDs = Set(groups.map(\.id))
        directoryError = nil
        let response = await session.listPermissionDirectoryGroups(kind: requestedKind, generation: generation)
        guard isCurrent(), !Task.isCancelled, kind == requestedKind else { return }
        if let error = response.error { directoryError = error; return }
        groups = response.groups
        defaultGroup = response.defaultGroup
        let created = newName.flatMap { name in groups.first { $0.name == name && !previousIDs.contains($0.id) }?.id }
        let remembered = preferred.flatMap { id in groups.first { $0.id == id }?.id }
        await loadSelection(created ?? remembered ?? groups.first?.id)
    }

    private func selectGroup(_ id: UInt64?) async {
        guard !busy, isCurrent(), !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        await loadSelection(id)
    }

    private func loadSelection(_ id: UInt64?) async {
        resetSelection()
        groupID = id
        guard let group = selectedGroup else { return }
        loadingRules = true
        defer { loadingRules = false }
        if !loadedDefinitions {
            let catalog = await session.permissionCatalog(generation: generation)
            guard isCurrent(), !Task.isCancelled, groupID == group.id, kind == group.kind else { return }
            definitions = Dictionary(catalog.definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            loadedDefinitions = catalog.error == nil
        }
        let response = await session.listGroupPermissions(kind: group.kind, group: group.id, generation: generation)
        guard isCurrent(), !Task.isCancelled, groupID == group.id, kind == group.kind else { return }
        ruleError = response.error
        rules = Dictionary(response.permissions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loadingRules = false
        await loadRoster(for: group)
    }

    private func refreshRoster() async {
        guard !busy, let selectedGroup, isCurrent() else { return }
        busy = true
        defer { busy = false }
        await loadRoster(for: selectedGroup)
    }

    private func loadRoster(for group: ListedGroup) async {
        guard group.kind == .server, group.id != defaultGroup, isCurrent(), !Task.isCancelled else { return }
        loadingRoster = true
        defer { loadingRoster = false }
        let response = await session.listServerGroupMembers(group: group.id, generation: generation)
        guard isCurrent(), !Task.isCancelled, groupID == group.id, kind == .server else { return }
        rosterError = response.error
        if response.error == nil { roster = response.members }
    }

    private func applyDrafts() async {
        guard !busy, !drafts.isEmpty, let group = selectedGroup, isCurrent(), !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        actionError = nil
        var failures: [String] = []
        for (id, change) in drafts.sorted(by: { $0.key < $1.key }) {
            guard isCurrent(), !Task.isCancelled, groupID == group.id, kind == group.kind else { return }
            let response: GroupPermissionResponse
            switch change {
            case .set(let permission):
                response = await session.setGroupPermission(kind: group.kind, group: group.id,
                                                            permission: permission, generation: generation)
            case .remove:
                response = await session.removeGroupPermission(kind: group.kind, group: group.id,
                                                               permissionId: id, generation: generation)
            }
            guard isCurrent(), !Task.isCancelled, groupID == group.id, kind == group.kind else { return }
            if let error = response.error {
                failures.append("#\(id) · \(error)")
            } else {
                switch change {
                case .set(let permission): rules[id] = permission
                case .remove: rules[id] = nil
                }
                drafts[id] = nil
            }
        }
        actionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func updateName(_ change: NameChange, name: String) async {
        guard !busy, isCurrent(), !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        let currentKind = kind
        let response: GroupPermissionResponse
        let preferred: UInt64?
        let newName: String?
        switch change {
        case .create:
            response = await session.createGroup(kind: kind, name: name, generation: generation)
            preferred = groupID
            newName = name
        case .rename(let group):
            guard group.kind == kind, groups.contains(where: { $0.id == group.id }) else { return }
            response = await session.renameGroup(kind: group.kind, group: group.id, name: name, generation: generation)
            preferred = group.id
            newName = nil
        case .copy(let group):
            guard group.kind == kind, groups.contains(where: { $0.id == group.id }) else { return }
            response = await session.copyGroup(kind: group.kind, group: group.id, name: name, generation: generation)
            preferred = groupID
            newName = name
        }
        guard isCurrent(), !Task.isCancelled, currentKind == kind else { return }
        actionError = response.error
        if response.error == nil { await loadDirectory(preferred: preferred, newName: newName) }
    }

    private func deleteGroup(_ group: ListedGroup) async {
        guard !busy, isCurrent(), !Task.isCancelled, group.kind == kind, group.id != defaultGroup,
              groups.contains(where: { $0.id == group.id }) else { return }
        busy = true
        defer { busy = false }
        let response = await session.deleteGroup(kind: group.kind, group: group.id, generation: generation)
        guard isCurrent(), !Task.isCancelled, group.kind == kind else { return }
        actionError = response.error
        if response.error == nil { await loadDirectory(preferred: groupID) }
    }

    private func requestMembership(_ change: RosterChange) {
        guard !busy, isCurrent(), let group = selectedGroup else { return }
        let request = MembershipRequest(group: group, change: change)
        Task { await updateMembership(request) }
    }

    private func updateMembership(_ request: MembershipRequest, confirmed: Bool = false) async {
        let group = request.group
        guard !busy, isCurrent(), !Task.isCancelled, groupID == group.id,
              group.kind == .server, kind == .server, group.id != defaultGroup else { return }
        let response: GroupPermissionResponse
        let confirmedMember: ServerGroupMember
        switch request.change {
        case .add(let candidate):
            let snapshot = session.snapshot()
            guard snapshot.audioGeneration == generation, !snapshot.reconnecting,
                  candidate.databaseId != 0,
                  let member = snapshot.rooms.lazy.flatMap(\.memberDetails).first(where: {
                      $0.clientId == candidate.clientId && $0.databaseId == candidate.databaseId
                  }), !member.serverGroups.contains(where: { $0.id == group.id }) else { return }
            if member.isSelf, !confirmed { memberToChange = request; return }
            busy = true
            confirmedMember = ServerGroupMember(databaseId: member.databaseId, name: member.name, isSelf: member.isSelf)
            response = await session.setMemberServerGroup(group: group.id, clientId: member.clientId,
                                                          databaseId: member.databaseId, member: true, generation: generation)
        case .remove(let member):
            guard let current = roster.first(where: { $0.databaseId == member.databaseId }) else { return }
            if current.isSelf, !confirmed { memberToChange = request; return }
            busy = true
            confirmedMember = current
            response = await session.removeServerGroupMember(group: group.id, databaseId: member.databaseId, generation: generation)
        }
        defer { busy = false }
        guard isCurrent(), !Task.isCancelled, groupID == group.id, kind == .server else { return }
        rosterError = response.error
        if response.error == nil {
            roster.removeAll { $0.databaseId == confirmedMember.databaseId }
            if case .add = request.change { roster.append(confirmedMember) }
            await loadRoster(for: group)
        }
    }
}

private struct GroupNameSheet: View {
    let title: LocalizedStringKey
    @State private var name: String
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: LocalizedStringKey, initialName: String, submit: @escaping (String) -> Void) {
        self.title = title
        self.submit = submit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Group name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { submit(trimmedName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
#endif

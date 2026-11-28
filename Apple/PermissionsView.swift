import SwiftUI

struct PermissionsView: View {
    let state: PermissionsState

    var body: some View {
        if let error = state.groups.errorMessage {
            Section("Groups") { Text(error).foregroundStyle(.secondary) }
        } else {
            groupSection("Server groups", kind: .server)
            groupSection("Channel groups", kind: .channel)
        }
        PermissionOverviewSection(state: state.overview)
    }

    private func groupSection(_ title: LocalizedStringKey, kind: GroupKind) -> some View {
        Section(title) {
            let rows = state.groups(of: kind) ?? []
            if rows.isEmpty { Text("No groups returned.").foregroundStyle(.secondary) }
            ForEach(rows, id: \.id) { group in
                LabeledContent { Text(verbatim: "#\(group.id)") } label: { Text(verbatim: group.name) }
            }
        }
    }

}

private struct PermissionOverviewSection: View {
    let state: PermissionRead<PermissionOverview>
    var search = ""

    var body: some View {
        Section("Effective permissions") {
            if let error = state.errorMessage {
                Text(error).foregroundStyle(.secondary)
            } else if case let .loaded(overview) = state {
                LabeledContent("Client database ID", value: String(overview.clientDbId))
                LabeledContent("Channel ID", value: String(overview.channelId))
                if overview.permissions.isEmpty {
                    Text("No permissions returned.").foregroundStyle(.secondary)
                } else {
                    if overview.permissions.contains(where: { $0.effectiveValue == nil }) {
                        Text("Some effective values could not be determined from the server’s assignments.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    let permissions = overview.permissions.filter(matchesSearch)
                    if permissions.isEmpty {
                        Text("No matching permissions").foregroundStyle(.secondary)
                    }
                    ForEach(permissions, id: \.id, content: permissionRow)
                }
            }
        }
    }

    private func matchesSearch(_ permission: EffectivePermission) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            || (permission.name?.localizedCaseInsensitiveContains(query) ?? false)
            || "#\(permission.id)".contains(query)
    }

    private func permissionRow(_ permission: EffectivePermission) -> some View {
        DisclosureGroup {
            ForEach(Array(permission.assignments.enumerated()), id: \.offset) { _, assignment in
                VStack(alignment: .leading) {
                    LabeledContent { Text(verbatim: String(assignment.value)) } label: { source(assignment.source) }
                    HStack {
                        if assignment.setsEffectiveValue { Text("Sets effective value") }
                        if assignment.negated { Text("Negated") }
                        if assignment.skip { Text("Skip") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } label: {
            VStack(alignment: .leading) {
                Text(verbatim: permission.name.map { "\($0) (#\(permission.id))" } ?? "#\(permission.id)")
                if let value = permission.effectiveValue {
                    Text("Effective value: \(String(value))").font(.caption)
                } else {
                    Text("Effective value unavailable").font(.caption)
                }
            }
        }
    }

    private func source(_ value: PermissionSource) -> Text {
        switch value {
        case .serverGroup(let id): Text("Server group #\(String(id))")
        case .client(let id): Text("Client #\(String(id))")
        case .channel(let id): Text("Channel #\(String(id))")
        case .channelGroup(let channel, let group): Text("Channel #\(String(channel)), group #\(String(group))")
        case .channelClient(let channel, let client): Text("Channel #\(String(channel)), client #\(String(client))")
        }
    }
}

#if os(macOS)
struct MemberPermissionsView: View {
    @ObservedObject var model: ServerModel
    let target: MemberGroupAssignmentTarget
    @Environment(\.dismiss) private var dismiss
    @State private var result: PermissionRead<PermissionOverview>?
    @State private var attempt = 0
    @State private var search = ""

    private var member: (member: RoomMember, room: Room)? { target.displayedMember(in: model) }

    var body: some View {
        NavigationStack {
            Form {
                if let member {
                    Section {
                        LabeledContent("Member", value: member.member.name)
                        LabeledContent("Channel", value: member.room.name)
                    }
                    if let result {
                        PermissionOverviewSection(state: result, search: search)
                    } else {
                        ProgressView("Loading permissions…")
                    }
                }
            }
            .formStyle(.grouped)
            .searchable(text: $search, prompt: Text("Search permissions"))
            .navigationTitle("Effective permissions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        result = nil
                        attempt += 1
                    } label: {
                        if result?.errorMessage == nil {
                            Text("Refresh")
                        } else {
                            Text("Retry")
                        }
                    }
                    .disabled(result == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        .onChange(of: member == nil, initial: true) { _, missing in
            if missing { dismiss() }
        }
        .task(id: attempt) { await load() }
    }

    @MainActor private func load() async {
        guard target.liveMember(in: model) != nil else {
            dismiss()
            return
        }
        let response = await target.session.memberPermissionOverview(
            clientId: target.member.clientID, databaseId: target.member.databaseID,
            channel: target.channel, generation: target.member.generation
        )
        guard !Task.isCancelled else { return }
        guard target.liveMember(in: model) != nil else {
            dismiss()
            return
        }
        if response.denied {
            result = .denied(permissionID: response.missingPermission)
        } else if let overview = response.overview {
            result = .loaded(overview)
        } else {
            result = .failed(response.error ?? String(localized: "Permission response was incomplete."))
        }
    }
}
#endif

#if DEBUG
struct OfflinePermissionsView: View {
    @State private var sample = PermissionSample.populated
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Sample response", selection: $sample) {
                    Text("With data").tag(PermissionSample.populated)
                    Text("Empty result").tag(PermissionSample.empty)
                    Text("Access denied").tag(PermissionSample.denied)
                    Text("Read failure").tag(PermissionSample.failed)
                }
                PermissionsView(state: sample.state)
            }
            .formStyle(.grouped)
            .navigationTitle("Offline permission preview")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }
}
#endif

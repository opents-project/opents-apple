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
        Section("Effective permissions") {
            if let error = state.overview.errorMessage {
                Text(error).foregroundStyle(.secondary)
            } else if case let .loaded(overview) = state.overview {
                LabeledContent("Client database ID", value: String(overview.clientDbId))
                LabeledContent("Channel ID", value: String(overview.channelId))
                if overview.permissions.isEmpty { Text("No permissions returned.").foregroundStyle(.secondary) }
                ForEach(overview.permissions, id: \.id) { permission in
                    DisclosureGroup {
                        ForEach(Array(permission.assignments.enumerated()), id: \.offset) { _, assignment in
                            VStack(alignment: .leading) {
                                LabeledContent { Text(verbatim: String(assignment.value)) } label: { source(assignment.source) }
                                if assignment.negated { Text("Negated").font(.caption) }
                                if assignment.skip { Text("Skip").font(.caption) }
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
            }
        }
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

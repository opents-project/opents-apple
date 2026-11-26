import SwiftUI

#if os(macOS)
struct MemberGroupAssignmentTarget: Identifiable {
    let id = UUID()
    let member: MemberSelection
    let session: Session
    let channel: UInt64

    @MainActor func displayedMember(in model: ServerModel) -> (member: RoomMember, room: Room)? {
        guard model.groupPermissionSession === session, model.groupPermissionGeneration == member.generation,
              let match = member.find(in: model.channels), channel == match.room.id else { return nil }
        return match
    }

    @MainActor func liveMember(in model: ServerModel) -> RoomMember? {
        guard member.databaseID != 0, displayedMember(in: model) != nil else { return nil }
        let snapshot = session.snapshot()
        guard !snapshot.reconnecting, !snapshot.server.isEmpty, snapshot.audioGeneration == member.generation,
              let room = snapshot.rooms.first(where: { $0.id == channel }),
              let match = room.memberDetails.first(where: member.matches) else { return nil }
        return match
    }
}

struct MemberGroupAssignmentView: View {
    @ObservedObject var model: ServerModel
    let target: MemberGroupAssignmentTarget
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: GroupPermissionResponse?
    @State private var loading = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var ownGroupChange: Change?
    @State private var awaitingConfirmation: Change?
    @State private var confirmationTimedOut = false

    private struct GroupOption {
        let group: ListedGroup
        let listed: Bool
    }

    private struct Change: Equatable {
        let group: UInt64
        let name: String
        let assigned: Bool

        func isApplied(to member: RoomMember) -> Bool {
            member.serverGroups.contains { $0.id == group } == assigned
        }
    }

    private var displayedMember: (member: RoomMember, room: Room)? { target.displayedMember(in: model) }

    private var confirmationArrived: Bool {
        guard let awaitingConfirmation, let displayedMember else { return false }
        return awaitingConfirmation.isApplied(to: displayedMember.member)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let displayedMember {
                let options = groupOptions(for: displayedMember.member)
                header(member: displayedMember.member)
                Divider()
                groupList(options, member: displayedMember.member)
                Divider()
                footer
            }
        }
        .frame(width: 440)
        .interactiveDismissDisabled(saving)
        .onChange(of: displayedMember == nil, initial: true) { _, missing in
            if missing { dismiss() }
        }
        .onChange(of: confirmationArrived) { _, arrived in
            if arrived { awaitingConfirmation = nil }
        }
        .alert("Couldn’t Change Group", isPresented: Binding(get: { saveError != nil }, set: { visible in
            if !visible { saveError = nil }
        }), presenting: saveError) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(verbatim: error)
        }
        .alert("Change Your Groups?", isPresented: Binding(get: { ownGroupChange != nil }, set: { visible in
            if !visible { ownGroupChange = nil }
        }), presenting: ownGroupChange) { change in
            Button("Cancel", role: .cancel) { }
            Button("Change Group") {
                ownGroupChange = nil
                Task { await submit(change, confirmed: true) }
            }
        } message: { change in
            if change.assigned {
                Text("Add yourself to \(change.name)? This may change your permissions on this server.")
            } else {
                Text("Remove yourself from \(change.name)? This may change your permissions on this server.")
            }
        }
        .task { await loadGroups() }
        .task(id: awaitingConfirmation) {
            guard let awaitingConfirmation else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard self.awaitingConfirmation == awaitingConfirmation else { return }
            confirmationTimedOut = true
        }
    }

    private func header(member: RoomMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set Server Group").font(.headline)
            Text(verbatim: member.name).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func groupList(_ options: [GroupOption], member: RoomMember) -> some View {
        let rowHeight: CGFloat = 26
        let inset: CGFloat = 6
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if options.isEmpty, let catalog, catalog.error == nil {
                    Text("No assignable groups.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                }
                ForEach(options, id: \.group.id) { option in
                    groupRow(option, for: member)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, inset)
        }
        .frame(height: min(180, CGFloat(max(3, options.count)) * rowHeight + 2 * inset))
    }

    private var footer: some View {
        let loadError = catalog?.error
        return HStack(spacing: 12) {
            Group {
                if let error = loadError {
                    failure(error)
                } else if saving || loading {
                    ProgressView().controlSize(.small)
                } else if awaitingConfirmation != nil {
                    if confirmationTimedOut {
                        Text("The server accepted the change. The membership update is still pending.")
                    } else {
                        Text("Waiting for the server to confirm group membership…")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if loadError != nil {
                Button("Retry") { Task { await loadGroups() } }
                    .disabled(loading)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func failure(_ description: String) -> some View {
        if description.hasPrefix("PermissionsClientInsufficient") {
            Label("Permission denied", systemImage: "lock")
                .foregroundStyle(.red)
                .help(description)
        } else {
            Text(verbatim: description).foregroundStyle(.red).help(description)
        }
    }

    private func groupOptions(for member: RoomMember) -> [GroupOption] {
        let available = catalog?.error == nil ? catalog?.groups ?? [] : []
        let availableIDs = Set(available.map(\.id))
        let options = available.map { GroupOption(group: $0, listed: true) }
        let readOnly = member.serverGroups.filter { !availableIDs.contains($0.id) }.map { GroupOption(group: $0, listed: false) }
        return (options + readOnly).sorted { $0.group.id < $1.group.id }
    }

    private func groupRow(_ option: GroupOption, for member: RoomMember) -> some View {
        let group = option.group
        let assigned = member.serverGroups.contains { $0.id == group.id }
        let canChange = option.listed && !saving && !loading && awaitingConfirmation == nil
        return Toggle(isOn: Binding(get: { assigned }, set: { included in
            Task { await submit(Change(group: group.id, name: group.name, assigned: included)) }
        })) {
            Text(verbatim: group.name)
        }
        .toggleStyle(.checkbox)
        .disabled(!canChange)
    }

    @MainActor private func loadGroups() async {
        guard !Task.isCancelled, !loading, !saving, awaitingConfirmation == nil else { return }
        guard target.liveMember(in: model) != nil else { dismiss(); return }
        loading = true
        defer { loading = false }
        catalog = nil
        let response = await target.session.listAssignableGroups(kind: .server, generation: target.member.generation)
        guard !Task.isCancelled else { return }
        guard target.liveMember(in: model) != nil else { dismiss(); return }
        catalog = response
    }

    @MainActor private func submit(_ change: Change, confirmed: Bool = false) async {
        guard !saving, !loading, awaitingConfirmation == nil, ownGroupChange == nil,
              let catalog, catalog.error == nil,
              catalog.groups.contains(where: { $0.id == change.group }) else { return }
        guard let member = target.liveMember(in: model) else { dismiss(); return }
        guard !change.isApplied(to: member) else { return }
        if member.isSelf, !confirmed {
            ownGroupChange = change
            return
        }
        saving = true
        saveError = nil
        confirmationTimedOut = false
        let selection = target.member
        let response = await target.session.setMemberServerGroup(group: change.group, clientId: selection.clientID,
                                                                 databaseId: selection.databaseID, member: change.assigned,
                                                                 generation: selection.generation)
        saving = false
        guard target.liveMember(in: model) != nil else { dismiss(); return }
        saveError = response.error
        if response.error == nil, let displayedMember, !change.isApplied(to: displayedMember.member) {
            awaitingConfirmation = change
        }
    }
}
#endif

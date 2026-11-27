import SwiftUI

#if os(macOS)
struct ServerGroupRosterView: View {
    let members: [ServerGroupMember]
    let candidates: [RoomMember]
    let loading: Bool
    let error: String?
    let isDefault: Bool
    let disabled: Bool
    let reload: () -> Void
    let add: (RoomMember) -> Void
    let remove: (ServerGroupMember) -> Void
    @State private var query = ""

    private var visibleMembers: [ServerGroupMember] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return members.filter { member in
            search.isEmpty || member.name.localizedCaseInsensitiveContains(search)
                || String(member.databaseId).contains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Members").font(.headline).padding(12)
            if isDefault {
                Text("The server assigns this group automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                TextField("Search members", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                List {
                    if loading, members.isEmpty { ProgressView().controlSize(.small) }
                    if let error { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
                    if !loading, error == nil, visibleMembers.isEmpty {
                        if members.isEmpty { Text("No members.").foregroundStyle(.secondary) }
                        else { Text("No matching members.").foregroundStyle(.secondary) }
                    }
                    ForEach(visibleMembers, id: \.databaseId) { member in
                        memberRow(member)
                    }
                }
                .listStyle(.plain)
                Divider()
                HStack {
                    Menu("Add online member", systemImage: "plus") {
                        ForEach(candidates, id: \.databaseId) { member in
                            Button { add(member) } label: { Text(verbatim: member.name) }
                        }
                    }
                    .disabled(disabled || candidates.isEmpty || error != nil)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                        .labelStyle(.iconOnly)
                        .disabled(disabled)
                }
                .padding(10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func memberRow(_ member: ServerGroupMember) -> some View {
        HStack {
            if member.isSelf {
                Image(systemName: "person.crop.circle.fill").accessibilityLabel("You")
            }
            Text(verbatim: member.name).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: "#\(member.databaseId)").font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Remove member", role: .destructive) { remove(member) }.disabled(disabled)
        }
    }
}
#endif

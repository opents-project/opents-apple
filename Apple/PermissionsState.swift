import Foundation

enum PermissionRead<Value> {
    case loaded(Value)
    case denied(permissionID: UInt32?)
    case failed(String)

    var errorMessage: String? {
        switch self {
        case .loaded: return nil
        case .denied(let id):
            if let id { return String(localized: "Permission denied (ID: \(String(id))).") }
            return String(localized: "Permission denied.")
        case .failed(let detail):
            return String(localized: "Could not load data: \(detail)")
        }
    }
}

struct PermissionsState {
    let groups: PermissionRead<[ListedGroup]>
    let overview: PermissionRead<PermissionOverview>

    func groups(of kind: GroupKind) -> [ListedGroup]? {
        guard case let .loaded(rows) = groups else { return nil }
        return rows.filter { $0.kind == kind }.sorted { $0.id < $1.id }
    }
}

#if DEBUG
enum PermissionSample: CaseIterable {
    case populated, empty, denied, failed

    var state: PermissionsState {
        let groups = [
            ListedGroup(kind: .server, id: 6, name: "Example Members"),
            ListedGroup(kind: .channel, id: 6, name: "Example Guests")
        ]
        switch self {
        case .populated:
            let assignments = [
                PermissionAssignment(source: .serverGroup(groupId: 6), value: 25, negated: false, skip: false, setsEffectiveValue: false),
                PermissionAssignment(source: .client(clientDbId: 12), value: 40, negated: false, skip: true, setsEffectiveValue: true)
            ]
            return PermissionsState(groups: .loaded(groups), overview: .loaded(PermissionOverview(
                clientDbId: 12, channelId: 3, permissions: [
                    EffectivePermission(id: 401, name: "example_power", effectiveValue: 40, assignments: assignments),
                    EffectivePermission(id: 402, name: nil, effectiveValue: nil, assignments: [
                        PermissionAssignment(source: .channelGroup(channelId: 3, groupId: 6), value: -1, negated: true, skip: false, setsEffectiveValue: false)
                    ])
                ])))
        case .empty:
            return PermissionsState(groups: .loaded([]), overview: .loaded(PermissionOverview(clientDbId: 12, channelId: 3, permissions: [])))
        case .denied:
            return PermissionsState(groups: .loaded(groups), overview: .denied(permissionID: 401))
        case .failed:
            return PermissionsState(groups: .failed(String(localized: "Request timed out.")), overview: .denied(permissionID: nil))
        }
    }
}
#endif

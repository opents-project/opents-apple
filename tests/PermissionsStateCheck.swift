import Foundation

@main struct PermissionsStateCheck {
    static func main() {
        let normal = PermissionSample.populated.state
        precondition(normal.groups(of: .server)?.map(\.name) == ["Example Members"])
        precondition(normal.groups(of: .channel)?.map(\.name) == ["Example Guests"])
        guard case let .loaded(overview) = normal.overview else { preconditionFailure() }
        precondition(overview.clientDbId == 12 && overview.channelId == 3)
        let first = overview.permissions[0], unknown = overview.permissions[1]
        precondition(first.effectiveValue == 40 && first.assignments.count == 2)
        precondition(first.assignments[1].skip && first.assignments[1].source == .client(clientDbId: 12))
        precondition(unknown.effectiveValue == nil && unknown.assignments[0].value == -1 && unknown.assignments[0].negated)
        let empty = PermissionSample.empty.state
        guard case let .loaded(result) = empty.overview else { preconditionFailure() }
        precondition(result.permissions.isEmpty && empty.groups(of: .channel)?.isEmpty == true)
        precondition(empty.groups.errorMessage == nil && empty.overview.errorMessage == nil)
        let denied = PermissionSample.denied.state
        precondition(denied.groups(of: .server)?.count == 1 && denied.overview.errorMessage?.contains("401") == true)
        let failed = PermissionSample.failed.state
        precondition(failed.groups(of: .server) == nil && failed.groups.errorMessage?.isEmpty == false)
        precondition(failed.overview.errorMessage?.isEmpty == false)
        print("Group scope, effective and unknown values, sources, empty, denied and failure passed.")
    }
}

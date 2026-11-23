import SwiftUI

struct ChannelNode: Identifiable {
    let room: Room
    let children: [ChannelNode]?
    var id: UInt64 { room.id }

    static func tree(_ rooms: [Room]) -> [ChannelNode] {
        let groups = Dictionary(grouping: rooms, by: \.parent)
        var visited = Set<UInt64>()
        func children(of parent: UInt64) -> [ChannelNode] {
            let siblings = (groups[parent] ?? []).sorted { $0.id < $1.id }
            let following = Dictionary(grouping: siblings, by: \.predecessor)
            var ordered: [ChannelNode] = []
            func appendChain(_ first: Room?) {
                var current = first
                while let room = current, visited.insert(room.id).inserted {
                    let nested = children(of: room.id)
                    ordered.append(ChannelNode(room: room, children: nested.isEmpty ? nil : nested))
                    current = following[room.id]?.first
                }
            }
            appendChain(following[0]?.first)
            for room in siblings where !visited.contains(room.id) { appendChain(room) }
            return ordered
        }
        return children(of: 0)
    }
}

@MainActor
final class ServerModel: ObservableObject {
    @Published var address = ""
    @Published var nickname = "OpenTS"
    @Published private(set) var server = ""
    @Published private(set) var channels: [ChannelNode] = []
    @Published private(set) var error: String?
    @Published private(set) var active = false
    @Published private(set) var currentChannel: UInt64?
    @Published private(set) var joining = false
    @Published var joinError: String?
    private var session: Session?
    private var observer: Task<Void, Never>?

    func connect() {
        guard !active else { return }
        error = nil
        let connection = Session(address: address.trimmingCharacters(in: .whitespacesAndNewlines), nickname: nickname)
        session = connection
        active = true
        observer = Task { [weak self] in
            var previous: Snapshot?
            while !Task.isCancelled {
                let update = connection.snapshot()
                if let failure = update.error {
                    self?.disconnect()
                    self?.error = failure
                    return
                }
                if update != previous {
                    self?.currentChannel = update.currentChannel
                    self?.server = update.server
                    self?.channels = ChannelNode.tree(update.rooms)
                    previous = update
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    func join(_ room: Room, password: String = "") {
        guard let session, !joining, currentChannel != room.id else { return }
        joining = true
        joinError = nil
        Task {
            let failure = await session.joinChannel(channel: room.id, password: password)
            guard self.session === session else { return }
            joining = false
            joinError = failure
        }
    }

    func disconnect() {
        joining = false
        joinError = nil
        currentChannel = nil
        observer?.cancel()
        observer = nil
        session?.disconnect()
        session = nil
        active = false
        server = ""
        channels = []
    }
}

import SwiftUI

struct ChannelNode: Identifiable {
    let room: Room
    let children: [ChannelNode]?
    var id: UInt64 { room.id }

    static func path(to id: UInt64, in nodes: [ChannelNode]) -> [UInt64]? {
        for node in nodes {
            if node.id == id { return [id] }
            if let path = path(to: id, in: node.children ?? []) { return [node.id] + path }
        }
        return nil
    }

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
    @Published var address = UserDefaults.standard.string(forKey: "lastServer") ?? ""
    @Published var nickname = UserDefaults.standard.string(forKey: "lastNickname") ?? "OpenTS"
    @Published private(set) var identityUID = ""
    @Published private(set) var server = ""
    @Published private(set) var channels: [ChannelNode] = []
    @Published private(set) var error: String?
    @Published private(set) var active = false
    @Published private(set) var reconnecting = false
    @Published private(set) var currentChannel: UInt64?
    @Published private(set) var joining = false
    @Published var joinError: String?
    @Published var chat = ChatState()
    private var generation: UInt64 = 0
    let audio = VoiceAudio()
    private let cues = ChannelSounds()
    private var session: Session?
    private var observer: Task<Void, Never>?

    func connect() {
        guard !active else { return }
        error = nil
        let identity: String
        do { identity = try IdentityStore().loadOrCreate() }
        catch { self.error = error.localizedDescription; return }
        let destination = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = Session(address: destination, nickname: nickname, identity: identity)
        session = connection
        active = true
        observer = Task { [weak self] in
            var previous: Snapshot?
            while !Task.isCancelled {
                let update = connection.snapshot()
                if let failure = update.error {
                    self?.disconnect()
                    self?.error = NSLocalizedString(failure, comment: "Connection error")
                    return
                }
                let batch = connection.takeChat()
                if !batch.isEmpty { self?.chat.receive(batch) }
                if update != previous {
                    self?.generation = update.audioGeneration
                    self?.reconnecting = update.reconnecting
                    if update.reconnecting {
                        if previous?.server.isEmpty == false { self?.play(.disconnected) }
                        self?.audio.disconnect()
                    }
                    if !update.server.isEmpty && (previous?.server.isEmpty != false || previous?.audioGeneration != update.audioGeneration) {
                        self?.audio.connect(connection.audio())
                    }
                    for cue in ChannelSound.changes(from: previous, to: update) { self?.play(cue) }
                    self?.currentChannel = update.currentChannel
                    if !update.server.isEmpty && previous?.server != update.server {
                        UserDefaults.standard.set(destination, forKey: "lastServer")
                        UserDefaults.standard.set(self?.nickname, forKey: "lastNickname")
                    }
                    self?.identityUID = update.identityUid
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
            joinError = failure?.userMessage
        }
    }

    private func play(_ cue: ChannelSound) {
        if audio.output { cues.play(cue) }
    }

    func sendChat(_ scope: ChatScope) {
        guard let session, !server.isEmpty, chat.sending == nil, let text = chat.drafts[scope],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let expected = generation
        chat.sending = scope
        chat.errors[scope] = nil
        Task {
            let failure = await session.sendChat(scope: scope, text: text, generation: expected)
            guard self.session === session else { return }
            chat.finish(scope, text: text, failure: failure)
        }
    }

    func disconnect() {
        chat = ChatState()
        if !server.isEmpty { play(.disconnected) }
        audio.disconnect()
        joining = false
        joinError = nil
        currentChannel = nil
        observer?.cancel()
        observer = nil
        session?.disconnect()
        session = nil
        active = false
        reconnecting = false
        server = ""
        channels = []
    }
}

extension JoinFailure {
    var userMessage: String {
        switch self {
        case .permissionDenied(let permission):
            if let permission {
                return String(localized: "Your identity lacks permission to join this channel (permission ID: \(String(permission))).")
            }
            return String(localized: "Your identity lacks permission to join this channel.")
        case .serverRejected(let code, let reason):
            return String(localized: "The server declined the channel change: \(reason) (error code: \(String(code))).")
        case .other(let message):
            return NSLocalizedString(message, comment: "Channel error")
        }
    }
}

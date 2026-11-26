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
    @Published var selectedIdentityUID = UserDefaults.standard.string(forKey: "connectionIdentityUID") {
        didSet { UserDefaults.standard.set(selectedIdentityUID, forKey: "connectionIdentityUID") }
    }
    @Published private(set) var identityUID = ""
    @Published private(set) var server = ""
    @Published private(set) var channelTreeServerKey: String?
    @Published private(set) var channels: [ChannelNode] = []
    @Published private(set) var error: String?
    @Published private(set) var active = false
    @Published private(set) var reconnecting = false
    @Published private(set) var currentChannel: UInt64?
    @Published private(set) var joining = false
    @Published var joinError: String?
    @Published var chat = ChatState()
    #if os(macOS)
    @Published private(set) var unreadChat = false
    @Published private(set) var windowTitle = "OpenTS"
    private var tabSelected = true
    #endif
    private(set) var generation: UInt64 = 0
    let audio = VoiceAudio()
    private let cues = ChannelSounds()
    private let channelTreeDefaults: UserDefaults
    private static let channelExpansionKeyPrefix = "channelTreeExpansion.v1."
    var fileSession: Session? { session }
    private var session: Session?
    private var observer: Task<Void, Never>?

    var groupPermissionSession: Session? { reconnecting || server.isEmpty ? nil : session }
    var groupPermissionGeneration: UInt64 { generation }

    init(channelTreeDefaults: UserDefaults = .standard) {
        self.channelTreeDefaults = channelTreeDefaults
    }

    #if os(macOS)
    func updateWindowTitle(_ title: String) {
        if windowTitle != title { windowTitle = title }
    }

    func setTabSelected(_ selected: Bool) {
        guard tabSelected != selected else { return }
        tabSelected = selected
        if selected { unreadChat = false }
        audio.setTabSelected(selected)
    }
    #endif

    func savedChannelExpansion(for serverKey: String) -> Set<UInt64>? {
        guard let data = channelTreeDefaults.data(forKey: Self.channelExpansionKeyPrefix + serverKey),
              let ids = try? JSONDecoder().decode([UInt64].self, from: data) else { return nil }
        return Set(ids)
    }

    func saveChannelExpansion(_ ids: Set<UInt64>, for serverKey: String) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        channelTreeDefaults.set(data, forKey: Self.channelExpansionKeyPrefix + serverKey)
    }

    func connect() {
        guard !active else { return }
        error = nil
        let identity: String
        do { identity = try IdentityStore().forConnection(selectedUID: selectedIdentityUID) }
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
                if !batch.isEmpty, let self {
                    self.chat.receive(batch)
                    #if os(macOS)
                    if !self.tabSelected { self.unreadChat = true }
                    #endif
                }
                if update != previous {
                    self?.applySnapshot(update, previous: previous)
                    if update.reconnecting {
                        if previous?.reconnecting != true {
                            self?.play(.disconnected)
                            self?.audio.disconnect()
                        }
                    } else if !update.server.isEmpty {
                        if previous?.server.isEmpty != false || previous?.audioGeneration != update.audioGeneration {
                            self?.audio.connect(connection.audio())
                            UserDefaults.standard.set(destination, forKey: "lastServer")
                            UserDefaults.standard.set(self?.nickname, forKey: "lastNickname")
                        }
                        self?.refreshTransmission()
                        for cue in ChannelSound.changes(from: previous, to: update) { self?.play(cue) }
                    }
                    previous = update
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    var currentRoom: Room? { currentChannel.flatMap { room($0) } }

    func room(_ id: UInt64) -> Room? {
        func lookup(_ nodes: [ChannelNode]) -> Room? {
            for node in nodes {
                if node.id == id { return node.room }
                if let children = node.children, let match = lookup(children) { return match }
            }
            return nil
        }
        return lookup(channels)
    }

    func applySnapshot(_ update: Snapshot, previous: Snapshot?) {
        generation = update.audioGeneration
        reconnecting = update.reconnecting
        // Keep the last confirmed channel tree on screen during the retry window.
        if !update.reconnecting && !update.server.isEmpty {
            server = update.server
            if channelTreeServerKey != update.serverKey { channelTreeServerKey = update.serverKey }
            identityUID = update.identityUid
            currentChannel = update.currentChannel
            if update.rooms != previous?.rooms { channels = ChannelNode.tree(update.rooms) }
        }
        refreshTransmission()
    }

    private func refreshTransmission() {
        audio.setChannelAllowsTransmission(!reconnecting && !joining && currentRoom?.audioSupported == true)
    }

    func readChannelDescription(_ id: UInt64) async -> String? {
        let failure = await changeChannel(.readDescription(channel: id), generation: generation)
        return failure.map { NSLocalizedString($0, comment: "Channel description request error") }
    }

    func changeChannel(_ change: ChannelChange, generation expected: UInt64) async -> String? {
        guard let session, !reconnecting, generation == expected else { return String(localized: "Connection interrupted") }
        return await session.changeChannel(change: change, generation: expected)
    }

    func join(_ room: Room, password: String = "") {
        guard let session, !reconnecting, !joining, currentChannel != room.id else { return }
        joining = true
        refreshTransmission()
        joinError = nil
        Task {
            let failure = await session.joinChannel(channel: room.id, password: password)
            guard self.session === session else { return }
            joining = false
            refreshTransmission()
            joinError = failure?.userMessage
        }
    }

    private func play(_ cue: ChannelSound) {
        guard audio.output else { return }
        #if os(macOS)
        cues.play(cue, outputDeviceUID: audio.devices.actual[.output]?.uid)
        #else
        cues.play(cue)
        #endif
    }

    func sendChat(_ scope: ChatScope) {
        guard let session, !server.isEmpty, !reconnecting, chat.sending == nil, let text = chat.drafts[scope],
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
        #if os(macOS)
        unreadChat = false
        updateWindowTitle("OpenTS")
        #endif
        if !server.isEmpty && !reconnecting { play(.disconnected) }
        audio.disconnect()
        audio.voiceActivated = false
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
        channelTreeServerKey = nil
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

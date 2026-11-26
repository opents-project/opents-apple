import Foundation

/// Exercises the same published state the three server workspaces observe.
@main struct WorkspaceRecoveryCheck {
    @MainActor static func main() {
        let suite = "OpenTS.WorkspaceRecoveryCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ServerModel(channelTreeDefaults: defaults)
        let firstServer = "ts3:first:1"
        let secondServer = "ts3:second:1"
        let room = Room(id: 7, parent: 0, predecessor: 0, name: "Studio", codec: "OpusVoice",
                        audioSupported: true, kind: "Permanent", members: [], memberDetails: [],
                        subscribed: true, passwordRequired: false, description: nil)
        let live = Snapshot(server: "Local test", serverKey: firstServer, reconnecting: false, audioGeneration: 1, rooms: [room],
                            currentChannel: room.id, peerIds: [], identityUid: "test", error: nil)
        let lost = Snapshot(server: "", serverKey: nil, reconnecting: true, audioGeneration: 2, rooms: [],
                            currentChannel: nil, peerIds: [], identityUid: "", error: nil)
        let scope = ChatScope.channel(id: room.id)
        model.applySnapshot(live, previous: nil)
        precondition(model.channelTreeServerKey == firstServer)
        precondition(model.savedChannelExpansion(for: firstServer) == nil)
        let firstExpansion: Set<UInt64> = [UInt64.max, room.id]
        model.saveChannelExpansion(firstExpansion, for: firstServer)
        model.chat.drafts[scope] = "Unsent draft"
        model.applySnapshot(lost, previous: live)
        precondition(model.reconnecting && model.currentRoom == room && model.server == live.server)
        precondition(model.identityUID == live.identityUid && model.chat.drafts[scope] == "Unsent draft")
        precondition(model.channelTreeServerKey == firstServer)
        var restored = live
        restored.audioGeneration = lost.audioGeneration
        model.applySnapshot(restored, previous: lost)
        precondition(!model.reconnecting && model.currentRoom == room && model.chat.drafts[scope] == "Unsent draft")
        precondition(model.channelTreeServerKey == firstServer)
        precondition(model.savedChannelExpansion(for: firstServer) == firstExpansion)

        var sameName = restored
        sameName.serverKey = secondServer
        model.applySnapshot(sameName, previous: restored)
        precondition(model.server == live.server && model.channelTreeServerKey == secondServer)
        precondition(model.savedChannelExpansion(for: secondServer) == nil)
        model.saveChannelExpansion([], for: secondServer)
        let reloaded = ServerModel(channelTreeDefaults: UserDefaults(suiteName: suite)!)
        precondition(reloaded.savedChannelExpansion(for: firstServer) == firstExpansion)
        precondition(reloaded.savedChannelExpansion(for: secondServer) == [])
        model.disconnect()
        precondition(model.currentRoom == nil && model.channels.isEmpty && model.chat.drafts.isEmpty)
        precondition(model.channelTreeServerKey == nil)
        print("Retry retains the workspace, draft and server key. Channel expansion survives reload and stays separate for same-name servers.")
    }
}

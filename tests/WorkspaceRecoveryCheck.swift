import Foundation

/// Exercises the same published state the three server workspaces observe.
@main struct WorkspaceRecoveryCheck {
    @MainActor static func main() {
        let model = ServerModel()
        let room = Room(id: 7, parent: 0, predecessor: 0, name: "Studio", codec: "OpusVoice",
                        audioSupported: true, kind: "Permanent", members: [], memberDetails: [],
                        subscribed: true, passwordRequired: false, description: nil)
        let live = Snapshot(server: "Local test", reconnecting: false, audioGeneration: 1, rooms: [room],
                            currentChannel: room.id, peerIds: [], identityUid: "test", error: nil)
        let lost = Snapshot(server: "", reconnecting: true, audioGeneration: 2, rooms: [],
                            currentChannel: nil, peerIds: [], identityUid: "", error: nil)
        let scope = ChatScope.channel(id: room.id)
        model.applySnapshot(live, previous: nil)
        model.chat.drafts[scope] = "Unsent draft"
        model.applySnapshot(lost, previous: live)
        precondition(model.reconnecting && model.currentRoom == room && model.server == live.server)
        precondition(model.identityUID == live.identityUid && model.chat.drafts[scope] == "Unsent draft")
        var restored = live
        restored.audioGeneration = lost.audioGeneration
        model.applySnapshot(restored, previous: lost)
        precondition(!model.reconnecting && model.currentRoom == room && model.chat.drafts[scope] == "Unsent draft")
        model.disconnect()
        precondition(model.currentRoom == nil && model.channels.isEmpty && model.chat.drafts.isEmpty)
        print("Retry retains the channel, workspace and draft; recovery restores state; disconnect clears it.")
    }
}

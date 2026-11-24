import AVFoundation

enum ChannelSound: String, CaseIterable {
    case connected, disconnected, channelChanged, memberJoined, memberLeft

    static func changes(from previous: Snapshot?, to current: Snapshot) -> [Self] {
        guard !current.server.isEmpty else { return [] }
        guard let previous, !previous.server.isEmpty else { return [.connected] }
        guard current.currentChannel != nil else { return [] }
        if previous.currentChannel != current.currentChannel { return [.channelChanged] }
        let before = Set(previous.peerIds)
        let after = Set(current.peerIds)
        var sounds: [Self] = []
        if !before.isSubset(of: after) { sounds.append(.memberLeft) }
        if !after.isSubset(of: before) { sounds.append(.memberJoined) }
        return sounds
    }
}

@MainActor
final class ChannelSounds {
    private var players: [ChannelSound: AVAudioPlayer] = [:]

    func play(_ cue: ChannelSound, outputDeviceUID: String? = nil) {
        if players[cue] == nil, let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav") {
            players[cue] = try? AVAudioPlayer(contentsOf: url)
        }
        guard let player = players[cue] else { return }
        #if os(macOS)
        if player.currentDevice != outputDeviceUID { player.currentDevice = outputDeviceUID }
        #endif
        player.currentTime = 0
        player.play()
    }
}

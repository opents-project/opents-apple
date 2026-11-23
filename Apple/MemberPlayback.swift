import SwiftUI

struct MemberPlaybackList: View {
    let members: [RoomMember]
    @ObservedObject var audio: VoiceAudio

    var body: some View {
        ForEach(members, id: \.clientId) { member in
            if !member.isSelf, member.databaseId != 0, let voice = audio.voice {
                MemberPlayback(member: member, voice: voice)
                    .id(MemberKey(voice: ObjectIdentifier(voice), databaseID: member.databaseId))
            } else {
                Label(member.name, systemImage: "person")
            }
        }
    }

    private struct MemberKey: Hashable {
        let voice: ObjectIdentifier
        let databaseID: UInt64
    }
}

private struct MemberPlayback: View {
    let member: RoomMember
    let voice: Voice
    @State private var mix = SpeakerMix(gain: 1, pan: 0, muted: false)
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Toggle("Mute locally", isOn: control(\.muted))
            LabeledContent("Playback volume", value: Double(mix.gain).formatted(.percent))
            Slider(value: control(\.gain), in: 0...2, step: 0.05)
                .accessibilityLabel("Playback volume")
            LabeledContent("Stereo balance") {
                if abs(mix.pan) < 0.001 { Text("Center") }
                else if mix.pan < 0 { Text("Left \(Int((-mix.pan * 100).rounded()))%") }
                else { Text("Right \(Int((mix.pan * 100).rounded()))%") }
            }
            Slider(value: control(\.pan), in: -1...1, step: 0.05)
                .accessibilityLabel("Stereo balance")
            Button("Reset playback") { apply(SpeakerMix(gain: 1, pan: 0, muted: false)) }
        } label: {
            Label(member.name, systemImage: mix.muted ? "speaker.slash" : "person")
        }
        .onAppear { mix = voice.speakerMix(databaseId: member.databaseId) }
        .onChange(of: expanded) { _, open in
            if open { mix = voice.speakerMix(databaseId: member.databaseId) }
        }
    }

    private func control<T>(_ path: WritableKeyPath<SpeakerMix, T>) -> Binding<T> {
        Binding(get: { mix[keyPath: path] }, set: { value in
            var updated = voice.speakerMix(databaseId: member.databaseId)
            updated[keyPath: path] = value
            apply(updated)
        })
    }

    private func apply(_ updated: SpeakerMix) {
        voice.setSpeakerMix(databaseId: member.databaseId, mix: updated)
        mix = updated
    }
}

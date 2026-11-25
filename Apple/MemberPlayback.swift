import SwiftUI

struct MemberPlaybackList: View {
    let members: [RoomMember]
    @ObservedObject var audio: VoiceAudio

    var body: some View {
        ForEach(members, id: \.clientId) { member in
            MemberPlayback(member: member, voice: audio.voice)
                .id(MemberKey(voice: audio.voice.map(ObjectIdentifier.init), clientID: member.clientId, databaseID: member.databaseId))
        }
    }

    private struct MemberKey: Hashable {
        let voice: ObjectIdentifier?
        let clientID: UInt16
        let databaseID: UInt64
    }
}

private struct MemberPlayback: View {
    let member: RoomMember
    let voice: Voice?
    @State private var mix = SpeakerMix(gain: 1, pan: 0, muted: false)
    @State private var expanded = false

    private var canControlPlayback: Bool { !member.isSelf && member.databaseId != 0 && voice != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if canControlPlayback {
                    DisclosureGroup(isExpanded: $expanded) {
                        playbackControls
                            .padding(.vertical, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } label: {
                        Label(member.name, systemImage: mix.muted ? "speaker.slash" : "person")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear { refreshMix() }
                    .onChange(of: expanded) { _, open in if open { refreshMix() } }
                } else {
                    Label(member.name, systemImage: member.isSelf ? "person.crop.circle.fill" : "person")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }

                MemberConnectionQuality(member: member, voice: voice)
                    .layoutPriority(1)
            }
            .frame(minHeight: 32)

        }
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
    }

    private func refreshMix() {
        guard canControlPlayback, let voice else { return }
        mix = voice.speakerMix(databaseId: member.databaseId)
    }

    private func control<T>(_ path: WritableKeyPath<SpeakerMix, T>) -> Binding<T> {
        Binding(get: { mix[keyPath: path] }, set: { value in
            guard let voice else { return }
            var updated = voice.speakerMix(databaseId: member.databaseId)
            updated[keyPath: path] = value
            apply(updated)
        })
    }

    private func apply(_ updated: SpeakerMix) {
        voice?.setSpeakerMix(databaseId: member.databaseId, mix: updated)
        mix = updated
    }
}

private struct MemberConnectionQuality: View {
    let member: RoomMember
    let voice: Voice?
    @State private var showingDetails = false

    private func readQuality() -> ConnectionQuality? {
        guard let voice else { return nil }
        if member.isSelf { return voice.connectionQuality() }
        return voice.memberConnectionQuality(clientId: member.clientId, databaseId: member.databaseId)
    }

    private func ping(_ quality: ConnectionQuality?) -> String {
        guard let ping = quality?.pingMs else { return "—" }
        let pingText = ping.formatted(.number.precision(.fractionLength(0)))
        guard let deviation = quality?.deviationMs else {
            return String(format: NSLocalizedString("Ping %@ ± %@ ms", comment: "Compact member ping and deviation"), pingText, "—")
        }
        let deviationText = deviation.formatted(.number.precision(.fractionLength(0...1)))
        return String(format: NSLocalizedString("Ping %@ ± %@ ms", comment: "Compact member ping and deviation"), pingText, deviationText)
    }

    private func percent(_ value: Float?) -> String? {
        value?.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private func lossSummary(_ quality: ConnectionQuality?) -> String {
        if let incoming = percent(quality?.incomingLoss) {
            return String(format: NSLocalizedString("Down loss %@", comment: "Incoming loss summary"), incoming)
        }
        if let outgoing = percent(quality?.outgoingLoss) {
            return String(format: NSLocalizedString("Up loss %@", comment: "Outgoing loss summary"), outgoing)
        }
        return "—"
    }

    private func rate(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal) + "/s"
    }

    private func directedRate(_ value: UInt64?, direction: String) -> String {
        let amount = value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .decimal) } ?? "—"
        return String(format: NSLocalizedString(direction, comment: "Compact directional connection rate"), amount)
    }

    private var owner: String { member.isSelf ? String(localized: "This client") : member.name }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let quality = readQuality()
            Button { showingDetails = true } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text(verbatim: ping(quality))
                            Text(verbatim: lossSummary(quality))
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: ping(quality))
                            Text(verbatim: lossSummary(quality))
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text(verbatim: directedRate(quality?.incomingBytesPerSecond, direction: "↓ %@/s"))
                            Text(verbatim: directedRate(quality?.outgoingBytesPerSecond, direction: "↑ %@/s"))
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: directedRate(quality?.incomingBytesPerSecond, direction: "↓ %@/s"))
                            Text(verbatim: directedRate(quality?.outgoingBytesPerSecond, direction: "↑ %@/s"))
                        }
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Connection quality for \(member.name)"))
            .accessibilityValue(Text("\(ping(quality)), packet loss \(lossSummary(quality)), \(directedRate(quality?.incomingBytesPerSecond, direction: "↓ %@/s")), \(directedRate(quality?.outgoingBytesPerSecond, direction: "↑ %@/s"))"))
        }
        .popover(isPresented: $showingDetails) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let quality = readQuality()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection quality for \(member.name)").font(.headline)
                    LabeledContent("Connection owner", value: owner)
                    LabeledContent("Ping ± variation", value: ping(quality))
                    LabeledContent("Incoming packet loss", value: percent(quality?.incomingLoss) ?? "—")
                    LabeledContent("Outgoing packet loss", value: percent(quality?.outgoingLoss) ?? "—")
                    LabeledContent("Receive rate", value: rate(quality?.incomingBytesPerSecond))
                    LabeledContent("Send rate", value: rate(quality?.outgoingBytesPerSecond))
                }
                .monospacedDigit()
                .padding()
                .frame(minWidth: 260, idealWidth: 300)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

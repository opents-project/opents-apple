import SwiftUI

struct MemberPlaybackList: View {
    let members: [RoomMember]
    @ObservedObject var audio: VoiceAudio

    var body: some View {
        ForEach(members.filter(\.isSelf) + members.filter { !$0.isSelf }, id: \.clientId) { member in
            MemberPlayback(member: member, audio: audio)
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
    @ObservedObject var audio: VoiceAudio
    @State private var mix = SpeakerMix(gain: 1, pan: 0, muted: false)
    @State private var expanded = false

    private var voice: Voice? { audio.voice }
    private var canControlPlayback: Bool { !member.isSelf && member.databaseId != 0 && voice != nil }
    private var isSpeaking: Bool {
        guard let voice else { return false }
        if member.isSelf { return voice.isLocallySpeaking() }
        return voice.memberIsSpeaking(clientId: member.clientId, databaseId: member.databaseId)
    }

    private var nameAndStatus: some View {
        HStack(spacing: 5) {
            Label(member.name, systemImage: member.isSelf ? "person.crop.circle.fill" : (mix.muted ? "speaker.slash" : "person"))
                .lineLimit(1)
                .truncationMode(.middle)
            if member.isSelf {
                Text("You").font(.caption).foregroundStyle(.secondary).fixedSize()
            } else if mix.muted {
                Text("Muted locally").font(.caption).foregroundStyle(.secondary)
            }
            if isSpeaking {
                Text("Speaking")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.12), in: Capsule())
                    .fixedSize()
                    .accessibilityLabel(Text("Speaking"))
            }
            if member.isSelf && !audio.microphone {
                Image(systemName: "mic.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(Text("Microphone off"))
                    .accessibilityLabel(Text("Microphone off"))
            }
        }
        .lineLimit(1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 0) {
                #if os(iOS)
                memberRow(compactQuality: true)
                #else
                ViewThatFits(in: .horizontal) {
                    memberRow(compactQuality: false)
                    memberRow(compactQuality: true)
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private func memberRow(compactQuality: Bool) -> some View {
        HStack(spacing: 8) {
            if canControlPlayback {
                DisclosureGroup(isExpanded: $expanded) {
                    playbackControls
                        .padding(.vertical, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } label: {
                    nameAndStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .onAppear { refreshMix() }
                .onChange(of: expanded) { _, open in if open { refreshMix() } }
            } else {
                nameAndStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }

            #if os(macOS)
            if !member.isSelf { qualityButton(compact: compactQuality) }
            #else
            qualityButton(compact: compactQuality)
            #endif
        }
        .frame(minHeight: 32)
    }

    private func qualityButton(compact: Bool) -> some View {
        MemberConnectionQuality(member: member, voice: voice, compact: compact)
            .fixedSize(horizontal: true, vertical: false)
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

struct MemberConnectionQuality: View {
    let member: RoomMember
    let voice: Voice?
    var compact = false
    @State private var showingDetails = false

    private func readQuality() -> ConnectionQuality? {
        guard let voice else { return nil }
        if member.isSelf { return voice.connectionQuality() }
        return voice.memberConnectionQuality(clientId: member.clientId, databaseId: member.databaseId)
    }

    private func ping(_ quality: ConnectionQuality?) -> String {
        guard let ping = quality?.pingMs else { return "—" }
        let pingText = ping.formatted(.number.precision(.fractionLength(0)))
        if let deviation = quality?.deviationMs {
            let variation = deviation.formatted(.number.precision(.fractionLength(0...1)))
            return "\(pingText) ± \(variation) ms"
        }
        return "\(pingText) ms"
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

    @ViewBuilder
    private func rates(_ quality: ConnectionQuality?) -> some View {
        let incoming = quality?.incomingBytesPerSecond.map { "↓ " + ConnectionUnits.rate($0) }
        let outgoing = quality?.outgoingBytesPerSecond.map { "↑ " + ConnectionUnits.rate($0) }
        if let incoming, let outgoing {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Text(verbatim: incoming)
                    Text(verbatim: outgoing)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: incoming)
                    Text(verbatim: outgoing)
                }
            }
        } else if let incoming {
            Text(verbatim: incoming)
        } else if let outgoing {
            Text(verbatim: outgoing)
        }
    }

    private func accessibilityRates(_ quality: ConnectionQuality?) -> String {
        [
            quality?.incomingBytesPerSecond.map { "↓ " + ConnectionUnits.rate($0) },
            quality?.outgoingBytesPerSecond.map { "↑ " + ConnectionUnits.rate($0) },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var owner: String { member.isSelf ? String(localized: "This client") : member.name }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let quality = readQuality()
            Button { showingDetails = true } label: {
                if quality == nil {
                    Label("—", systemImage: "network")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if compact {
                    Label(quality?.pingMs == nil ? "—" : ping(quality), systemImage: "network")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
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
                        rates(quality)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Connection quality for \(member.name)"))
            .accessibilityValue(Text(verbatim: [ping(quality), lossSummary(quality), accessibilityRates(quality)].filter { !$0.isEmpty }.joined(separator: ", ")))
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
                    LabeledContent("Receive rate", value: quality?.incomingBytesPerSecond.map(ConnectionUnits.rate) ?? "—")
                    LabeledContent("Send rate", value: quality?.outgoingBytesPerSecond.map(ConnectionUnits.rate) ?? "—")
                }
                .monospacedDigit()
                .padding()
                .frame(minWidth: 260, idealWidth: 300)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

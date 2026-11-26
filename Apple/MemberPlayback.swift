import SwiftUI

enum SidebarSelection: Hashable {
    case channel(UInt64)
    case member(MemberSelection)
}

struct MemberSelection: Hashable, Identifiable {
    let clientID: UInt16
    let databaseID: UInt64
    let generation: UInt64
    var id: Self { self }

    init(_ member: RoomMember, generation: UInt64) {
        clientID = member.clientId
        databaseID = member.databaseId
        self.generation = generation
    }

    func matches(_ member: RoomMember) -> Bool {
        member.clientId == clientID && member.databaseId == databaseID
    }

    func find(in nodes: [ChannelNode]) -> (member: RoomMember, room: Room)? {
        for node in nodes {
            if let member = node.room.memberDetails.first(where: matches) { return (member, node.room) }
            if let children = node.children, let match = find(in: children) { return match }
        }
        return nil
    }
}

struct MemberPlaybackList: View {
    let members: [RoomMember]
    @ObservedObject var audio: VoiceAudio
    let generation: UInt64
    @Binding var selection: SidebarSelection?

    var body: some View {
        ForEach(members.filter(\.isSelf) + members.filter { !$0.isSelf }, id: \.clientId) { member in
            let target = SidebarSelection.member(MemberSelection(member, generation: generation))
            MemberRow(member: member, audio: audio) { selection = target }
                .tag(target)
        }
    }
}

private struct MemberRow: View {
    let member: RoomMember
    @ObservedObject var audio: VoiceAudio
    let select: () -> Void

    private let iconWidth: CGFloat = 16
    private let summarySpacing: CGFloat = 5

    private var voice: Voice? { audio.voice }
    private var isSpeaking: Bool {
        guard let voice else { return false }
        if member.isSelf { return voice.isLocallySpeaking() }
        return voice.memberIsSpeaking(clientId: member.clientId, databaseId: member.databaseId)
    }

    private var nameAndStatus: some View {
        let muted = !member.isSelf && voice?.speakerMix(databaseId: member.databaseId).muted == true
        return HStack(spacing: summarySpacing) {
            Image(systemName: member.isSelf ? "person.crop.circle.fill" : (muted ? "speaker.slash" : "person"))
                .frame(width: iconWidth)
                .accessibilityLabel(member.isSelf ? Text("You") : Text("Muted locally"))
                .accessibilityHidden(!member.isSelf && !muted)
            Text(verbatim: member.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if !member.isSelf, let awayMessage = member.awayMessage {
                Label("Away", systemImage: "moon.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(awayMessage.isEmpty ? Text("Away") : Text(verbatim: awayMessage))
                    .accessibilityValue(Text(verbatim: awayMessage))
            } else if isSpeaking {
                Label("Speaking", systemImage: "waveform")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .fixedSize()
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
            HStack(spacing: 6) {
                Button(action: select) {
                    nameAndStatus.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                MemberConnectionQuality(member: member, voice: voice)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
    }
}

struct MemberPlaybackSettings: View {
    let member: RoomMember
    let voice: Voice
    @Environment(\.dismiss) private var dismiss
    @State private var mix = SpeakerMix(gain: 1, pan: 0, muted: false)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    playbackControls
                } header: { Text(verbatim: member.name) }
            }
            .formStyle(.grouped)
            .navigationTitle("Playback settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 275)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .onAppear { mix = voice.speakerMix(databaseId: member.databaseId) }
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

struct ServerMemberDetails: View {
    let member: RoomMember
    let channel: String

    var body: some View {
        Form {
            Section {
                Label {
                    Text(verbatim: member.name).font(.title2.weight(.semibold))
                } icon: {
                    Image(systemName: member.isSelf ? "person.crop.circle.fill" : "person.crop.circle")
                }
                LabeledContent("Channel", value: channel)
                if let away = member.awayMessage {
                    LabeledContent("Away") { Text(verbatim: away.isEmpty ? "—" : away) }
                }
                if let version = member.opentsVersion {
                    LabeledContent("Client version", value: "OpenTS \(version)")
                }
            }
            Section("Groups") {
                LabeledContent("Server groups") {
                    let names = member.serverGroups.map(\.name)
                    Text(verbatim: names.isEmpty ? "—" : names.joined(separator: ", "))
                }
                LabeledContent("Channel group") { Text(verbatim: member.channelGroup?.name ?? "—") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MemberConnectionQuality: View {
    let member: RoomMember
    let voice: Voice?
    @State private var showingDetails = false

    private func lossSummary(_ quality: ConnectionQuality?) -> String {
        if let incoming = percent(quality?.incomingLoss) {
            return String(format: NSLocalizedString("Loss %@", comment: "Compact packet loss summary"), incoming)
        }
        if let outgoing = percent(quality?.outgoingLoss) {
            return String(format: NSLocalizedString("Up loss %@", comment: "Outgoing loss summary"), outgoing)
        }
        return "—"
    }

    private func accessibilityRates(_ quality: ConnectionQuality?) -> String {
        [
            quality?.incomingBytesPerSecond.map { "↓ " + ConnectionUnits.rate($0) },
            quality?.outgoingBytesPerSecond.map { "↑ " + ConnectionUnits.rate($0) },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let quality = member.connectionQuality(using: voice)
            Button { showingDetails = true } label: {
                HStack(spacing: 4) {
                    Text(verbatim: ping(quality, includeVariation: false))
                    if let loss = treePacketLoss(quality) { Text(verbatim: loss) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Connection quality for \(member.name)"))
            .accessibilityValue(Text(verbatim: [ping(quality), lossSummary(quality), accessibilityRates(quality)].filter { !$0.isEmpty }.joined(separator: ", ")))
        }
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection quality for \(member.name)").font(.headline)
                MemberQualityFields(member: member, voice: voice)
            }
            .padding()
            .frame(minWidth: 260, idealWidth: 300)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct MemberQualityFields: View {
    let member: RoomMember
    let voice: Voice?

    private var owner: String { member.isSelf ? String(localized: "This client") : member.name }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let quality = member.connectionQuality(using: voice)
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Connection owner", value: owner)
                LabeledContent("Ping ± variation", value: ping(quality))
                LabeledContent("Incoming packet loss", value: percent(quality?.incomingLoss) ?? "—")
                LabeledContent("Outgoing packet loss", value: percent(quality?.outgoingLoss) ?? "—")
                LabeledContent("Receive rate", value: quality?.incomingBytesPerSecond.map(ConnectionUnits.rate) ?? "—")
                LabeledContent("Send rate", value: quality?.outgoingBytesPerSecond.map(ConnectionUnits.rate) ?? "—")
            }
            .monospacedDigit()
        }
    }
}

private extension RoomMember {
    func connectionQuality(using voice: Voice?) -> ConnectionQuality? {
        guard let voice else { return nil }
        if isSelf { return voice.connectionQuality() }
        return voice.memberConnectionQuality(clientId: clientId, databaseId: databaseId)
    }
}

private func ping(_ quality: ConnectionQuality?, includeVariation: Bool = true) -> String {
    guard let ping = quality?.pingMs else { return "—" }
    let pingText = ping.formatted(.number.precision(.fractionLength(0)))
    if includeVariation, let deviation = quality?.deviationMs {
        let variation = deviation.formatted(.number.precision(.fractionLength(0...1)))
        return "\(pingText) ± \(variation) ms"
    }
    return "\(pingText) ms"
}

private func percent(_ value: Float?) -> String? {
    value?.formatted(.percent.precision(.fractionLength(0...1)))
}

private func treePacketLoss(_ quality: ConnectionQuality?) -> String? {
    let losses = [quality?.incomingLoss, quality?.outgoingLoss].compactMap { $0 }
    guard let highest = losses.filter(\.isFinite).max(), highest > 0.01 else { return nil }
    return highest.formatted(.percent.precision(.fractionLength(0...2)))
}

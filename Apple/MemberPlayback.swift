import SwiftUI

struct MemberPlaybackList: View {
    let members: [RoomMember]
    @ObservedObject var audio: VoiceAudio

    let startChat: (RoomMember) -> Void

    var body: some View {
        ForEach(members.filter(\.isSelf) + members.filter { !$0.isSelf }, id: \.clientId) { member in
            MemberPlayback(member: member, audio: audio, startChat: startChat)
                .selectionDisabled(true)
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
    let startChat: (RoomMember) -> Void
    @State private var mix = SpeakerMix(gain: 1, pan: 0, muted: false)
    @State private var showingMemberDetails = false

    private let iconWidth: CGFloat = 16
    private let summarySpacing: CGFloat = 5

    private var voice: Voice? { audio.voice }
    private var canControlPlayback: Bool { !member.isSelf && member.databaseId != 0 && voice != nil }
    private var isSpeaking: Bool {
        guard let voice else { return false }
        if member.isSelf { return voice.isLocallySpeaking() }
        return voice.memberIsSpeaking(clientId: member.clientId, databaseId: member.databaseId)
    }

    private var nameAndStatus: some View {
        HStack(spacing: summarySpacing) {
            Image(systemName: member.isSelf ? "person.crop.circle.fill" : (mix.muted ? "speaker.slash" : "person"))
                .frame(width: iconWidth)
                .accessibilityLabel(member.isSelf ? Text("You") : Text("Muted locally"))
                .accessibilityHidden(!member.isSelf && !mix.muted)
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
            treeRow
        }
        .onAppear { refreshMix() }
        .popover(isPresented: $showingMemberDetails, attachmentAnchor: .point(.leading)) {
            #if os(iOS)
            ScrollView { memberDetails }
                .frame(idealHeight: canControlPlayback ? 420 : 320)
                .presentationDetents(canControlPlayback ? [.large] : [.medium, .large])
                .presentationCompactAdaptation(.sheet)
            #else
            memberDetails
            #endif
        }
        .contextMenu {
            if canControlPlayback {
                Button("Playback settings", systemImage: "slider.horizontal.3", action: showMemberDetails)
            } else {
                Button("Connection quality for \(member.name)", systemImage: "network", action: showMemberDetails)
            }
            if !member.isSelf, member.uid != nil {
                Button("Private message", systemImage: "bubble.left") { startChat(member) }
            }
        }
    }

    private var treeRow: some View {
        Button(action: showMemberDetails) {
            HStack(spacing: 6) {
                nameAndStatus.frame(maxWidth: .infinity, alignment: .leading)
                TreeMemberQuality(member: member, voice: voice)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(canControlPlayback ? Text("Playback settings") : Text("Connection quality for \(member.name)"))
    }

    private var memberDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if canControlPlayback {
                    Text("Playback settings").font(.headline)
                } else {
                    Text("Connection quality for \(member.name)").font(.headline)
                }
                #if os(iOS)
                Spacer()
                Button("Done") { showingMemberDetails = false }
                #endif
            }
            if canControlPlayback {
                playbackControls
                Divider()
                Text("Connection quality for \(member.name)")
                    .font(.subheadline.weight(.semibold))
            }
            MemberQualityFields(member: member, voice: voice)
        }
        .frame(minWidth: 230, idealWidth: 260)
        .padding(16)
    }

    private func showMemberDetails() {
        refreshMix()
        showingMemberDetails = true
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
                Label(ping(quality), systemImage: "network")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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

private struct TreeMemberQuality: View {
    let member: RoomMember
    let voice: Voice?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let quality = member.connectionQuality(using: voice)
            let latency = ping(quality, includeVariation: false)
            let packetLoss = treePacketLoss(quality)
            HStack(spacing: 4) {
                Text(verbatim: latency)
                if let packetLoss {
                    Text(verbatim: packetLoss)
                        .accessibilityLabel(Text("Loss \(packetLoss)"))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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

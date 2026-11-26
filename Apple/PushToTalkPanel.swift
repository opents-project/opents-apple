#if os(macOS)
import SwiftUI

struct PushToTalkPanel: View {
    @ObservedObject var tabs: ServerTabs
    @Environment(\.scenePhase) private var phase
    @Environment(\.controlActiveState) private var windowActivity
    @State private var held: HeldConnection?

    private struct HeldConnection {
        let id: ServerTabs.Tab.ID
        let token: UUID
    }

    private var connections: [ServerTabs.Tab] { tabs.entries.filter { $0.model.active } }

    var body: some View {
        Group {
            if connections.isEmpty {
                ContentUnavailableView("No connected servers", systemImage: "mic.slash")
            } else {
                GeometryReader { geometry in targetGrid(in: geometry.size) }
            }
        }
        .onChange(of: tabs.selected.id) { _, _ in cancel() }
        .onChange(of: windowActivity) { _, activity in
            if activity != .key { cancel() }
        }
        .onChange(of: phase) { _, phase in
            if phase != .active { cancel() }
        }
        .onDisappear { cancel() }
    }

    private func targetGrid(in size: CGSize) -> some View {
        let targets = connections
        let spacing: CGFloat = 12
        let columns = max(1, min(targets.count, Int((size.width - spacing) / (230 + spacing))))
        let rows = max(1, (targets.count + columns - 1) / columns)
        let rowHeight = (size.height - CGFloat(rows + 1) * spacing) / CGFloat(rows)
        let padHeight = max(144, rowHeight - 40)

        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                      spacing: spacing) {
                ForEach(targets) { connection in
                    let label = tabs.label(for: connection)
                    PushToTalkTarget(
                        model: connection.model,
                        audio: connection.model.audio,
                        title: label.title,
                        detail: label.subtitle ?? connection.model.currentRoom?.name ?? connection.model.nickname,
                        selected: tabs.selected.id == connection.id,
                        holding: held?.id == connection.id,
                        padHeight: padHeight,
                        begin: { begin(connection) },
                        end: { stop(connection.id) },
                        toggleMicrophone: { toggleMicrophone(connection) }
                    )
                }
            }
            .padding(spacing)
        }
    }

    private func begin(_ connection: ServerTabs.Tab) {
        let audio = connection.model.audio
        guard held == nil, phase == .active, windowActivity == .key,
              unavailableReason(for: connection.model, audio: audio) == nil,
              let token = tabs.leaseAudio(for: connection) else { return }
        guard unavailableReason(for: connection.model, audio: audio) == nil else {
            tabs.releaseAudio(token)
            return
        }
        audio.press(true)
        if audio.talking {
            held = HeldConnection(id: connection.id, token: token)
        } else {
            tabs.releaseAudio(token)
        }
    }

    private func stop(_ id: ServerTabs.Tab.ID? = nil) {
        guard let held, id == nil || held.id == id else { return }
        self.held = nil
        tabs.releaseAudio(held.token)
    }

    private func cancel() {
        stop()
    }

    private func toggleMicrophone(_ connection: ServerTabs.Tab) {
        let audio = connection.model.audio
        let turnOn = !audio.microphoneEnabledForTab
        guard held == nil else { return }
        Task {
            guard !audio.voiceActivated,
                  !connection.model.reconnecting, !connection.model.joining else { return }
            await audio.setMicrophone(turnOn)
        }
    }
}

private struct PushToTalkTarget: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var audio: VoiceAudio
    let title: String
    let detail: String
    let selected: Bool
    let holding: Bool
    let padHeight: CGFloat
    let begin: () -> Void
    let end: () -> Void
    let toggleMicrophone: () -> Void
    @GestureState private var pressed = false

    private var reason: LocalizedStringKey? { unavailableReason(for: model, audio: audio) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.headline)
                    Text(verbatim: detail).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
                microphoneButton
            }
            pad
        }
        .onChange(of: pressed) { _, pressed in
            if pressed { begin() } else { end() }
        }
        .onChange(of: audio.talking) { _, talking in if holding && !talking { end() } }
        .onChange(of: reason != nil) { _, unavailable in if unavailable { end() } }
        .onChange(of: model.currentChannel) { _, _ in end() }
        .onDisappear(perform: end)
    }

    private var microphoneButton: some View {
        let enabled = audio.microphoneEnabledForTab
        let label: LocalizedStringKey = enabled ? "Mute Microphone" : "Enable Microphone"
        return Button(action: toggleMicrophone) {
            Label(label, systemImage: enabled ? "mic.fill" : "mic.slash")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderless)
        .help(Text(label))
        .disabled(audio.voice == nil || audio.voiceActivated || model.reconnecting || model.joining || holding)
    }

    private var pad: some View {
        TimelineView(.animation(minimumInterval: 0.15, paused: !holding)) { _ in
            let transmitting = holding && audio.talking && audio.voice?.isLocallySpeaking() == true
            let status = reason ?? (transmitting ? "Talking…" : holding ? "Ready to speak" : "Hold to Talk")
            Label(status, systemImage: transmitting ? "waveform" : "mic")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(reason == nil ? Color.white : Color.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: padHeight)
                .background(
                    transmitting ? AnyShapeStyle(.green) : reason == nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .accessibilityLabel(Text(verbatim: "\(title) · \(detail)"))
                .accessibilityValue(Text(status))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, pressed, _ in pressed = true })
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(reason ?? "Hold to transmit")
        .disabled(reason != nil)
    }
}

@MainActor
private func unavailableReason(for model: ServerModel, audio: VoiceAudio) -> LocalizedStringKey? {
    if model.reconnecting { return "Reconnecting…" }
    if model.server.isEmpty { return "Connecting…" }
    if model.joining { return "Switching channel…" }
    guard let room = model.currentRoom else { return "No current channel" }
    if !room.audioSupported { return "Audio unavailable for this codec" }
    if audio.voice == nil { return "Audio unavailable" }
    if audio.voiceActivated { return "Voice activation" }
    if !audio.microphoneEnabledForTab { return "Microphone off" }
    if !audio.outputEnabledForTab { return "Output off" }
    return nil
}
#endif

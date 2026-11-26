import SwiftUI

struct VoiceMenu: View {
    @ObservedObject var audio: VoiceAudio
    var includesMuteControls = true
    #if os(macOS)
    @ViewBuilder
    private func deviceMenu(_ side: DeviceSide) -> some View {
        let selection = audio.devices
        let options = selection.inventory?.devices[side] ?? []
        let uid = selection.preferred[side]
        let active = side == .input ? audio.hasInputRoute : audio.hasOutputRoute
        Menu(side == .input ? "Input device" : "Output device") {
            Picker("Preferred device", selection: Binding(get: { uid }, set: { audio.selectDevice(side, uid: $0) })) {
                Text("Follow system default").tag(nil as String?)
                ForEach(options, id: \.uid) { device in
                    Text(verbatim: device.name).tag(Optional(device.uid))
                }
                if let uid, !options.contains(where: { $0.uid == uid }) {
                    Text("\(selection.savedNames[side] ?? uid) (unavailable)").tag(Optional(uid))
                }
            }
            .pickerStyle(.inline)
            Divider()
            if let device = selection.actual[side] {
                Text("Current device: \(device.name)")
            } else if active {
                Text("Current device: Unknown")
            } else {
                Text("Current device: Inactive")
            }
            if selection.inventory == nil {
                Button("Retry device discovery", action: audio.refreshDevices)
            }
        }
    }
    #endif

    var body: some View {
        Picker("Transmission mode", selection: $audio.voiceActivated) {
            Text("Push to talk").tag(false)
            Text("Voice activation").tag(true)
        }
        #if os(macOS)
        deviceMenu(.input)
        deviceMenu(.output)
        Toggle("Global push to talk (⌥⇧Space)", isOn: $audio.globalShortcut)
            .disabled(audio.voiceActivated)
        if includesMuteControls {
            Button(audio.microphone ? "Mute Microphone" : "Enable Microphone", systemImage: audio.microphone ? "mic" : "mic.slash") {
                Task { await audio.setMicrophone(!audio.microphone) }
            }
            Button(audio.output ? "Mute Output" : "Enable Output", systemImage: audio.output ? "speaker.wave.2" : "speaker.slash", action: audio.toggleOutput)
        }
        #endif
    }
}

struct DeviceButtons: View {
    @ObservedObject var audio: VoiceAudio
    var minimumSize: CGFloat = 44

    var body: some View {
        Group {
            Button {
                Task { await audio.setMicrophone(!audio.microphone) }
            } label: {
                Label(audio.microphone ? "Mute Microphone" : "Enable Microphone",
                      systemImage: audio.microphone ? "mic.fill" : "mic.slash")
                    .frame(minWidth: minimumSize, minHeight: minimumSize)
            }
            Button(action: audio.toggleOutput) {
                Label(audio.output ? "Mute Output" : "Enable Output",
                      systemImage: audio.output ? "speaker.wave.2.fill" : "speaker.slash")
                    .frame(minWidth: minimumSize, minHeight: minimumSize)
            }
        }
        .disabled(audio.voice == nil)
    }
}

struct VoiceControls: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var audio: VoiceAudio
    let compact: Bool
    let revealChannel: () -> Void
    var showsDeviceButtons = true
    @Environment(\.scenePhase) private var phase
    @State private var showingDiagnostics = false
    @State private var showingThreshold = false
    @GestureState private var holding = false
    private var reason: LocalizedStringKey? {
        #if os(iOS)
        if audio.audioInterrupted { return "Audio interrupted." }
        #endif
        if model.reconnecting { return "Reconnecting · talk unavailable" }
        if model.joining { return "Switching channel…" }
        guard let room = model.currentRoom else { return "No current channel" }
        if !room.audioSupported { return "Audio unavailable for this codec" }
        if audio.voice == nil { return "Audio unavailable" }
        if !audio.microphone { return "Microphone off" }
        if !audio.output { return "Output off" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let message = audio.message {
                Text(message).font(.caption).foregroundStyle(audio.standardInput ? Color.secondary : Color.red)
            }
            #if os(iOS)
            if compact {
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    channelRevealButton
                    Spacer(minLength: 2)
                    if showsDeviceButtons { devices }
                    settings
                    talk
                }
            } else {
                HStack {
                    status
                    Spacer(minLength: 4)
                    settings
                    if showsDeviceButtons { devices }
                    talk
                }
            }
            #else
            HStack {
                status
                Spacer(minLength: 4)
                settings
                talk
            }
            #endif
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.bar)
        .onDisappear { audio.press(false) }
        .onChange(of: phase) { _, phase in if phase != .active { audio.press(false) } }
        .sheet(isPresented: $showingDiagnostics) { VoiceDiagnosticsView(audio: audio) }
        .popover(isPresented: $showingThreshold) {
            VStack(alignment: .leading) {
                LabeledContent("Activation threshold", value: "\(Int(audio.threshold)) dBFS")
                Slider(value: $audio.threshold, in: -70 ... -10, step: 1)
                    .accessibilityLabel("Activation threshold")
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    ProgressView(value: max(0, min(70, audio.reading.level + 70)), total: 70)
                        .accessibilityLabel("Microphone level")
                }
            }.padding().frame(width: 260).presentationCompactAdaptation(.popover)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: revealChannel) {
                Label(model.currentRoom?.name ?? model.server, systemImage: "person.wave.2")
                    .font(.headline).lineLimit(1)
            }.buttonStyle(.plain).accessibilityHint("Show current channel")
            HStack(spacing: 6) {
                if let reason { Text(reason) }
                #if os(macOS)
                if !audio.globalShortcut { Text("⌥⇧Space off") }
                else if !audio.microphone { Text("⌥⇧Space paused · microphone off") }
                else if audio.shortcutUnavailable || reason != nil || audio.voiceActivated { Text("⌥⇧Space unavailable") }
                else { Text("⌥⇧Space ready") }
                #endif
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var channelRevealButton: some View {
        Button(action: revealChannel) {
            Label(model.currentRoom?.name ?? model.server, systemImage: "person.wave.2")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: model.currentRoom?.name ?? model.server))
        .accessibilityHint("Show current channel")
    }

    private var devices: some View {
        HStack(spacing: 2) { DeviceButtons(audio: audio) }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.reconnecting)
    }

    private var settings: some View {
        Menu {
            VoiceMenu(audio: audio, includesMuteControls: false)
            if audio.voiceActivated { Button("Activation threshold") { showingThreshold = true } }
            Divider()
            Button("Voice diagnostics") { showingDiagnostics = true }
        } label: { Label("Audio", systemImage: "slider.horizontal.3") }
        .labelStyle(.iconOnly)
        .fixedSize()
        .disabled(audio.voice == nil || model.reconnecting)
    }

    @ViewBuilder private var talk: some View {
        if audio.voiceActivated {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Label(reason == nil && audio.reading.active && audio.voice?.isLocallySpeaking() == true ? "Talking…" : "Voice activation",
                      systemImage: "waveform").font(.callout.bold()).frame(minHeight: 44)
            }
        } else {
            TimelineView(.animation(minimumInterval: 0.15, paused: !audio.talking)) { _ in
                let transmitting = audio.talking && audio.voice?.isLocallySpeaking() == true
                Text(transmitting ? "Talking…" : audio.talking ? "Ready to speak" : "Hold to Talk")
                    .font(.callout.bold())
                    .foregroundStyle(reason == nil ? Color.white : Color.secondary)
                    .padding(.horizontal, 16).frame(minWidth: 100, minHeight: 44)
                    .background(transmitting ? AnyShapeStyle(.green) : reason == nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
            }
                .contentShape(Capsule())
                .overlay {
                    if audio.talking { Capsule().strokeBorder(.primary.opacity(0.4), lineWidth: 2) }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($holding) { _, pressed, _ in pressed = true })
                .onChange(of: holding) { _, pressed in audio.press(pressed && reason == nil) }
                .accessibilityAddTraits(.isButton)
                #if os(iOS)
                .accessibilityDirectTouch(true, options: .silentOnTouch)
                #endif
                .accessibilityHint(reason ?? "Hold to transmit")
                .disabled(reason != nil)
        }
    }
}

import SwiftUI

struct VoiceMenu: View {
    @ObservedObject var audio: VoiceAudio
    var body: some View {
        Picker("Transmission mode", selection: $audio.voiceActivated) {
            Text("Push to talk").tag(false)
            Text("Voice activation").tag(true)
        }
        #if os(macOS)
        Toggle("Global push to talk (⌥⇧Space)", isOn: $audio.globalShortcut)
            .disabled(audio.voiceActivated)
        #endif
        Button(audio.microphone ? "Mute Microphone" : "Enable Microphone", systemImage: audio.microphone ? "mic" : "mic.slash") {
            Task { await audio.setMicrophone(!audio.microphone) }
        }
        Button(audio.output ? "Mute Output" : "Enable Output", systemImage: audio.output ? "speaker.wave.2" : "speaker.slash", action: audio.toggleOutput)
    }
}

struct VoiceControls: View {
    @ObservedObject var audio: VoiceAudio
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack {
            if let message = audio.message { Text(message).font(.caption).foregroundStyle(audio.standardInput ? Color.secondary : Color.red) }
            #if os(macOS)
            if audio.shortcutUnavailable {
                Text("The talk shortcut is unavailable. Use Hold to Talk or free ⌥⇧Space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            HStack {
                Menu("Audio", systemImage: "waveform") { VoiceMenu(audio: audio) }
                Spacer()
                if audio.microphone && audio.voiceActivated {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let reading = audio.reading
                        Label(reading.active ? "Talking…" : "Listening", systemImage: "waveform")
                    }
                } else if audio.microphone {
                    Text(audio.talking ? "Talking…" : "Hold to Talk")
                        .padding(.vertical, 6).padding(.horizontal, 12)
                        .background(.quaternary, in: Capsule())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in audio.press(true) }.onEnded { _ in audio.press(false) })
                        .disabled(!audio.output)
                } else {
                    Button("Enable Microphone") { Task { await audio.setMicrophone(true) } }
                }
            }
            if audio.voiceActivated {
                VStack(alignment: .leading) {
                    LabeledContent("Activation threshold", value: "\(Int(audio.threshold)) dBFS")
                    Slider(value: $audio.threshold, in: -70 ... -10, step: 1)
                        .accessibilityLabel("Activation threshold")
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        ProgressView(value: max(0, min(70, audio.reading.level + 70)), total: 70)
                            .accessibilityLabel("Microphone level")
                    }
                }
            }
        }
        .padding(10).background(.bar)
        .onDisappear { audio.press(false) }
        .onChange(of: phase) { _, value in if value != .active { audio.press(false) } }
    }
}

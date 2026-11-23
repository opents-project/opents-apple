import SwiftUI

struct VoiceMenu: View {
    @ObservedObject var audio: VoiceAudio
    var body: some View {
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
            if let message = audio.message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Menu("Audio", systemImage: "waveform") { VoiceMenu(audio: audio) }
                Spacer()
                if audio.microphone {
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
        }
        .padding(10).background(.bar)
        .onDisappear { audio.press(false) }
        .onChange(of: phase) { _, value in if value != .active { audio.press(false) } }
    }
}

import SwiftUI
#if os(iOS)
import AVFAudio
#endif

struct VoiceDiagnosticsView: View {
    @ObservedObject var audio: VoiceAudio
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let queue = audio.playbackMeter.snapshot()
                Form {
                    Section("Local playback · current audio engine") {
                        #if os(iOS)
                        let session = AVAudioSession.sharedInstance()
                        LabeledContent("Output route", value: session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))
                        LabeledContent("Device sample rate", value: "\(Int(session.sampleRate.rounded())) Hz")
                        LabeledContent("I/O buffer / output latency", value: "\(Int((session.ioBufferDuration * 1000).rounded())) / \(Int((session.outputLatency * 1000).rounded())) ms")
                        #endif
                        LabeledContent("Buffers awaiting player consumption", value: String(queue.pending))
                        LabeledContent("Playback queue drained", value: String(queue.drained))
                        LabeledContent("Longest empty interval", value: "\(queue.maxEmptyMs) ms")
                        LabeledContent("Longest callback to refill", value: "\(queue.maxRefillMs) ms")
                    }
                    if let stats = audio.voice?.diagnostics() {
                        Section("Incoming voice · current connection") {
                            LabeledContent("Received audio packets", value: String(stats.rxPackets))
                            LabeledContent("Sequence gaps / later filled", value: "\(stats.rxGapSlots) / \(stats.rxGapFills)")
                            LabeledContent("Late / other rejected packets", value: "\(stats.rxLate) / \(stats.rxOtherRejected)")
                            LabeledContent("Opus concealment / FEC", value: "\(stats.rxConcealedFrames / 48) ms")
                            LabeledContent("Backlog removed during recovery", value: "\(stats.rxRecoveredFrames / 48) ms")
                            LabeledContent("Longest interval during speech", value: "\(stats.rxLongestIntervalMs) ms")
                        }
                        Section("Outgoing voice · current connection") {
                            LabeledContent("Capture frames queued / queue full", value: "\(stats.txEnqueued) / \(stats.txFull)")
                            LabeledContent("Audio frames handed to transport", value: String(stats.txSent))
                        }
                    }
                }
                .formStyle(.grouped)
                .monospacedDigit()
            }
            .navigationTitle("Voice diagnostics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}

import SwiftUI

struct MicrophoneTestView: View {
    @StateObject private var test = MicrophoneTest()
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch test.state {
                    case .running:
                        if let name = test.inputName { LabeledContent("Input device", value: name) }
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            let db = test.level
                            LabeledContent("Microphone level") {
                                if let db { Text(verbatim: "\(Int(db.rounded())) dBFS").monospacedDigit() }
                                else { Text("Waiting for input…") }
                            }
                            ProgressView(value: (db ?? -90) + 90, total: 90)
                                .accessibilityLabel("Microphone level")
                                .accessibilityValue(Text(verbatim: "\(Int((db ?? -90).rounded())) dBFS"))
                        }
                        Button("Stop test", action: test.stop)
                    case .requesting:
                        ProgressView("Requesting microphone access…")
                        Button("Cancel", action: test.stop)
                    case .idle, .failed:
                        if case let .failed(error) = test.state { Text(verbatim: error).foregroundStyle(.red) }
                        Button("Start test", action: test.start)
                    }
                } footer: {
                    Text("Audio is measured on this device. It is never sent or saved.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Microphone test")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { test.stop(); dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 240)
        #endif
        .onDisappear { test.stop() }
        .onChange(of: phase) { _, value in if value == .background { test.stop() } }
    }
}

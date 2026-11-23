#if DEBUG
import SwiftUI

struct OfflineServerLogView: View {
    @State private var sample = LogSample.populated
    @State private var server: String? = "Sample A"
    @State private var log = ServerLogState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Sample server", selection: $server) {
                    Text("Disconnected").tag(nil as String?)
                    ForEach(["Sample A", "Sample B"], id: \.self) { name in
                        Text(verbatim: name).tag(Optional(name))
                    }
                }
                Picker("Sample response", selection: $sample) {
                    Text("With data").tag(LogSample.populated)
                    Text("Empty result").tag(LogSample.empty)
                    Text("Access denied").tag(LogSample.denied)
                    Text("Read failure").tag(LogSample.failed)
                }
                Section("Server log") {
                    if server == nil { Text("Disconnected") }
                    else if log.denied { Text("Permission denied.") }
                    else {
                        ForEach(log.entries) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.time, format: .dateTime.year().month().day().hour().minute().second())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: entry.message).textSelection(.enabled)
                            }
                        }
                        if log.failed { Text("Could not read the server log.").foregroundStyle(.red) }
                        if log.pending != nil { ProgressView() }
                        else if log.finished && log.entries.isEmpty { Text("No log entries.") }
                        else if !log.finished {
                            Button(log.failed ? "Retry" : "Load older entries") { load() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Offline server log")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: server, initial: true) { _, _ in reload() }
            .onChange(of: sample) { _, _ in reload() }
            .onDisappear { log.reset(server: nil) }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 440)
        #endif
    }

    private func reload() {
        log.reset(server: server)
        load()
    }

    private func load() {
        guard let request = log.begin() else { return }
        let source = sample
        Task { @MainActor in
            await Task.yield()
            log.complete(request, with: source.read(request))
        }
    }
}
#endif

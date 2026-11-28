import SwiftUI

#if os(macOS)
struct ServerLogWindow: View {
    static let windowID = "server-log"
    @ObservedObject var tabs: ServerTabs

    private struct ConnectionID: Hashable {
        let tab: UUID
        let session: ObjectIdentifier
        let generation: UInt64
    }

    var body: some View {
        let tab = tabs.selected
        let model = tab.model
        if let session = model.connectedSession {
            let generation = model.generation
            LiveServerLogView(session: session, generation: generation, server: model.server)
                .id(ConnectionID(tab: tab.id, session: ObjectIdentifier(session), generation: generation))
        } else {
            ContentUnavailableView(LocalizedStringKey(model.reconnecting ? "Reconnecting…" : "Disconnected"),
                                   systemImage: "externaldrive.badge.wifi")
        }
    }
}

private struct LiveServerLogView: View {
    let session: Session
    let generation: UInt64
    let server: String
    @State private var log = ServerLogState()

    var body: some View {
        Group {
            if log.denied {
                ContentUnavailableView("Permission denied.", systemImage: "lock", description: denialDetails)
            } else if log.finished && log.entries.isEmpty {
                ContentUnavailableView("No log entries.", systemImage: "doc.text")
            } else {
                List {
                    ForEach(log.entries) { entry in
                        ServerLogRow(line: entry.message)
                    }
                    if let failure = log.failureMessage {
                        Text(verbatim: failure).foregroundStyle(.red)
                    } else if log.failed {
                        Text("Could not read the server log.").foregroundStyle(.red)
                    }
                    if log.pending != nil {
                        ProgressView().controlSize(.small)
                    } else if !log.finished {
                        Button(log.failed ? "Retry" : "Load older entries", action: load)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, minHeight: 300)
        .navigationTitle("Server log · \(server)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                    .disabled(log.pending != nil)
            }
        }
        .onAppear(perform: reload)
        .onDisappear { log.reset(server: nil) }
    }

    private var denialDetails: Text? {
        log.deniedPermission.map { Text("Permission #\(Int($0))") }
    }

    private func reload() {
        log.reset(server: server)
        load()
    }

    private func load() {
        guard let request = log.begin() else { return }
        Task {
            let response = await session.readServerLog(cursor: request.cursor, generation: generation)
            guard log.pending == request else { return }
            switch response {
            case .page(let lines, let olderCursor):
                log.complete(request, with: .page(.live(lines, olderCursor: olderCursor, following: log.entries)))
            case .permissionDenied(let permission):
                log.complete(request, with: .denied(permission: permission))
            case .failed(let message):
                log.complete(request, with: .failed(message: message))
            }
        }
    }
}

private struct ServerLogRow: View {
    let line: String

    var body: some View {
        let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        VStack(alignment: .leading, spacing: 4) {
            if fields.count == 5 {
                Text(verbatim: fields[0...2].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(verbatim: fields[4])
            } else {
                Text(verbatim: line)
            }
        }
        .padding(.vertical, 3)
        .textSelection(.enabled)
    }
}
#endif

#if DEBUG
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
                                if let time = entry.time {
                                    Text(time, format: .dateTime.year().month().day().hour().minute().second())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
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

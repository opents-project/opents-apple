#if DEBUG
import SwiftUI

struct OfflineFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server: String? = "Sample A"
    @State private var browser = OfflineFileBrowser()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sample server", selection: $server) {
                        Text("Disconnected").tag(nil as String?)
                        ForEach(["Sample A", "Sample B"], id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                    }
                    if server != nil { Button("Reconnect", action: reconnect) }
                }
                if server != nil {
                    Section {
                        if let parent = browser.path.parent { Button("Parent folder") { open(parent) } }
                        directory
                    } header: { Text(verbatim: browser.path.display) }
                    if !browser.transfers.isEmpty {
                        Section("Simulated transfers") {
                            ForEach(browser.transfers) { transfer in
                                VStack(alignment: .leading) {
                                    Label(transfer.path.display, systemImage: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                                    ProgressView(value: Double(transfer.percent), total: 100)
                                    switch transfer.status {
                                    case .running:
                                        HStack {
                                            Button("Cancel") { browser.stop(transfer.id, reason: .cancelled) }
                                            Menu("Simulate failure") {
                                                Button("Access denied") { browser.stop(transfer.id, reason: .denied) }
                                                Button("Transfer failed") { browser.stop(transfer.id, reason: .failed) }
                                            }
                                        }
                                    case .completed: Text("Completed")
                                    case .cancelled: Text("Cancelled")
                                    case .denied: Text("Permission denied.")
                                    case .failed: Text("Transfer failed")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Offline files")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: server, initial: true) { _, _ in reconnect() }
            .onDisappear { browser.reset(server: nil) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    @ViewBuilder private var directory: some View {
        switch browser.result {
        case .none: ProgressView()
        case .denied: Text("Permission denied.")
        case .failed:
            Text("Could not read folder.")
            Button("Retry") { open(browser.path) }
        case .listing(let entries):
            if entries.isEmpty { Text("Empty folder") }
            ForEach(entries) { entry in
                if entry.directory {
                    Button(entry.name, systemImage: "folder") {
                        if let path = browser.path.child(entry.name) { open(path) }
                    }
                } else {
                    HStack {
                        Text(verbatim: entry.name)
                        Spacer()
                        Button("Simulate download") { transfer(.download, name: entry.name) }
                    }
                }
            }
            Button("Simulate upload") { transfer(.upload, name: "example.txt") }
        }
    }

    private func reconnect() {
        browser.reset(server: server)
        open(.root)
    }

    private func open(_ path: ChannelFilePath) {
        guard let request = browser.open(path) else { return }
        Task { @MainActor in
            await Task.yield()
            browser.receive(OfflineFileBrowser.sample(request), for: request)
        }
    }

    private func transfer(_ direction: SimulatedDirection, name: String) {
        guard let id = browser.start(direction, name: name) else { return }
        Task { @MainActor in
            for progress in stride(from: 10, through: 100, by: 10) {
                try? await Task.sleep(for: .milliseconds(400))
                guard browser.transfers.contains(where: { $0.id == id && $0.status == .running }) else { return }
                browser.advance(id, percent: progress)
            }
        }
    }
}
#endif

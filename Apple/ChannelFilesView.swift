import SwiftUI
import UniformTypeIdentifiers

struct ChannelFilesButton: View {
    @ObservedObject var model: ServerModel
    let room: Room
    @State private var showing = false

    var body: some View {
        Button("Channel files", systemImage: "folder") { showing = true }
            .disabled(model.reconnecting || model.fileSession == nil)
            .sheet(isPresented: $showing) {
                if let session = model.fileSession {
                    ChannelFilesView(session: session, room: room)
                }
            }
            .onChange(of: model.reconnecting) { _, reconnecting in
                if reconnecting { showing = false }
            }
    }
}

private extension RemoteChannelFile {
    var wireName: Data { Data(name.utf8) }
}

private struct ChannelFilesView: View {
    let session: Session
    let room: Room
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var parts: [String] = []
    @State private var entries: [RemoteChannelFile] = []
    @State private var job: ChannelFileJob?
    @State private var error: String?
    @State private var listed = false
    @State private var picking = false
    @State private var exporting = false
    @State private var staged: URL?

    var body: some View {
        NavigationStack {
            List {
                if room.passwordRequired {
                    SecureField("Channel Password", text: $password)
                        .onSubmit { refresh() }
                        .disabled(job != nil)
                }
                Section {
                    if !parts.isEmpty {
                        Button("Parent folder", systemImage: "arrow.up") {
                            parts.removeLast()
                            refresh()
                        }.disabled(job != nil)
                    }
                    ForEach(entries, id: \.wireName) { item in
                        Button {
                            if item.directory {
                                parts.append(item.name)
                                refresh()
                            } else {
                                download(item.name)
                            }
                        } label: {
                            HStack {
                                Label(item.name, systemImage: item.directory ? "folder" : "arrow.down.doc")
                                Spacer()
                                if !item.directory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(job != nil)
                    }
                    if listed && entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
                } header: { Text(verbatim: room.name + "  /" + parts.joined(separator: "/")) }
                if let error { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
                if let job {
                    HStack {
                        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                            if let fraction = job.transferredFraction() {
                                ProgressView(value: fraction)
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Spacer()
                        Button("Cancel", role: .cancel) { job.cancel() }
                    }
                }
            }
            .navigationTitle("Channel files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                        .disabled(job != nil)
                    Button("Upload file", systemImage: "square.and.arrow.up") { picking = true }
                        .disabled(job != nil || !listed)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 320)
        #endif
        .onAppear { if !room.passwordRequired { refresh() } }
        .onDisappear { job?.cancel(); job = nil; clearStage() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            do { upload(try result.get()) } catch { self.error = error.localizedDescription }
        }
        .fileMover(isPresented: $exporting, file: staged) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
            clearStage()
        } onCancellation: { clearStage() }
    }

    private func clearStage() {
        if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        staged = nil
    }

    private func path(_ leaf: String? = nil) -> String {
        "/" + (parts + (leaf.map { [$0] } ?? [])).joined(separator: "/")
    }

    private func begin() -> ChannelFileJob {
        let next = session.channelFileJob(channel: room.id, password: password)
        job = next
        error = nil
        return next
    }

    private func refresh() {
        let next = begin()
        let remote = path()
        entries = []
        listed = false
        Task {
            let result = await next.listFiles(path: remote)
            guard job === next else { return }
            job = nil
            error = result.error
            listed = error == nil
            entries = result.entries.sorted {
                if $0.directory != $1.directory { return $0.directory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func upload(_ url: URL) {
        let next = begin()
        let remote = path(url.lastPathComponent)
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = await next.upload(path: remote, source: url.path)
            guard job === next else { return }
            job = nil
            if let failure = result.error { error = failure } else { refresh() }
        }
    }

    private func download(_ name: String) {
        let next = begin()
        let remote = path(name)
        Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let result = await next.download(path: remote, destination: file.path)
                if job === next && result.error == nil {
                    staged = file
                    exporting = true
                } else {
                    try? FileManager.default.removeItem(at: directory)
                }
                guard job === next else { return }
                error = result.error
            } catch {
                guard job === next else { return }
                self.error = error.localizedDescription
            }
            job = nil
        }
    }
}

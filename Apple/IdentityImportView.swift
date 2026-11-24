import SwiftUI
import UniformTypeIdentifiers

struct IdentityImportView: View {
    @Binding var selectedUID: String?
    @State private var knownUIDs: [String] = []
    @State private var choosingFile = false
    @State private var message: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let store = IdentityStore()

    var body: some View {
        NavigationStack {
            Form {
                Picker("Connection identity", selection: $selectedUID) {
                    Text("OpenTS default identity").tag(nil as String?)
                    ForEach(knownUIDs, id: \.self) { uid in Text(verbatim: uid).tag(Optional(uid)) }
                }
                Button("Import TS3 identity…", systemImage: "square.and.arrow.down") { choosingFile = true }
                if let message { Text(verbatim: message).textSelection(.enabled) }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Identities")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { refresh() }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "ini") ?? .data]) { result in
                do {
                    let url = try result.get()
                    message = nil
                    error = nil
                    let imported = try store.importFile(url)
                    message = imported.added ? String(localized: "Imported UID: \(imported.uid)") :
                                               String(localized: "This UID is already saved: \(imported.uid)")
                    refresh()
                } catch let failure as CocoaError where failure.code == .userCancelled {
                    return
                } catch { self.error = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 250)
        #endif
    }

    private func refresh() {
        do { knownUIDs = try store.importedUIDs() }
        catch { self.error = error.localizedDescription }
    }
}

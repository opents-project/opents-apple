import SwiftUI

struct ServerBookmark: Identifiable, Codable, Equatable {
    static let storageKey = "serverBookmarks.v1"

    var id = UUID()
    var name: String
    var address: String
    var nickname: String

    static func saved(from data: Data) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    var normalized: Self {
        var copy = self
        copy.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = copy.address }
        return copy
    }
}

struct BookmarkSection: View {
    @Binding var address: String
    @Binding var nickname: String
    @AppStorage(ServerBookmark.storageKey) private var data = Data()
    @State private var editing: ServerBookmark?

    private var bookmarks: [ServerBookmark] {
        ServerBookmark.saved(from: data)
    }

    var body: some View {
        Section("Bookmarks") {
            ForEach(bookmarks) { bookmark in
                HStack {
                    Button {
                        address = bookmark.address
                        nickname = bookmark.nickname
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: bookmark.name)
                            Text(verbatim: "\(bookmark.nickname) · \(bookmark.address)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Menu {
                        Button("Edit Bookmark") { editing = bookmark }
                        Button("Delete Bookmark", role: .destructive) {
                            save(bookmarks.filter { $0.id != bookmark.id })
                        }
                    } label: { Label("Bookmark options", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                }
            }
            Button("Add Bookmark", systemImage: "bookmark.badge.plus") {
                editing = ServerBookmark(name: "", address: address, nickname: nickname)
            }
        }
        .sheet(item: $editing) { bookmark in
            BookmarkEditor(draft: bookmark) { result in
                var entries = bookmarks
                if let index = entries.firstIndex(where: { $0.id == result.id }) {
                    entries[index] = result
                } else { entries.append(result) }
                save(entries)
                editing = nil
            }
        }
    }

    private func save(_ entries: [ServerBookmark]) {
        if let encoded = try? JSONEncoder().encode(entries) { data = encoded }
    }
}

private struct BookmarkEditor: View {
    @State var draft: ServerBookmark
    let save: (ServerBookmark) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Bookmark name", text: $draft.name)
                TextField("Address or server nickname", text: $draft.address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Your nickname", text: $draft.nickname)
            }
            .formStyle(.grouped)
            .navigationTitle("Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(draft.normalized) }
                        .disabled(draft.normalized.address.isEmpty || draft.normalized.nickname.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 220)
        #endif
    }
}

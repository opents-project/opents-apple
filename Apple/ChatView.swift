import SwiftUI

struct ChatView: View {
    @ObservedObject var model: ServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var serverChat = false

    private var scope: ChatScope? {
        serverChat ? .server : model.currentChannel.map { .channel(id: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Chat destination", selection: $serverChat) {
                    Text("Current channel").tag(false)
                    Text("Server").tag(true)
                }.pickerStyle(.segmented)
                if let scope {
                    let lines = model.chat.transcript(for: scope)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(lines, id: \.id) { line in
                                    VStack(alignment: .leading) {
                                        Text(verbatim: line.sender).font(.caption).foregroundStyle(.secondary)
                                        Text(verbatim: line.text).textSelection(.enabled)
                                    }.id(line.id)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: lines.last?.id, initial: true) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    if let error = model.chat.errors[scope] { Text(error).foregroundStyle(.red) }
                    HStack {
                        TextField("Message", text: Binding(get: { model.chat.drafts[scope] ?? "" },
                            set: { model.chat.drafts[scope] = $0 }))
                            .onSubmit { model.sendChat(scope) }
                        Button("Send", systemImage: "paperplane") { model.sendChat(scope) }
                            .disabled(model.chat.sending != nil || (model.chat.drafts[scope] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding()
            .navigationTitle("Text chat")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

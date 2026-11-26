import SwiftUI

struct ChatView: View {
    @ObservedObject var model: ServerModel
    @State private var serverChat = false
    @FocusState private var composing: Bool

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var heightClass
    #endif

    private var shortLayout: Bool {
        #if os(iOS)
        return heightClass == .compact
        #else
        return false
        #endif
    }

    private var scope: ChatScope? {
        serverChat ? .server : model.currentChannel.map { .channel(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !shortLayout {
                Picker("Chat destination", selection: $serverChat) {
                    Text("Current channel").tag(false)
                    Text("Server").tag(true)
                }.pickerStyle(.segmented)
            }
            if let scope {
                ChatTranscript(lines: model.chat.transcript(for: scope))
                    .id(scope)
                if let error = model.chat.errors[scope] { Text(error).font(.caption).foregroundStyle(.red) }
                let destination = serverChat ? model.server : model.currentRoom?.name ?? ""
                HStack {
                    if shortLayout {
                        Menu {
                            Button(model.currentRoom?.name ?? String(localized: "Current channel")) { serverChat = false }
                            Button(model.server) { serverChat = true }
                        } label: {
                            Label(destination, systemImage: serverChat ? "server.rack" : "bubble.left")
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: 140)
                        .accessibilityLabel("Chat destination")
                    }
                    ChatDraftField(model: model, scope: scope, destination: destination, focus: $composing)
                        .id(scope)
                    #if os(iOS)
                    if composing {
                        Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { composing = false }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("chat.hideKeyboard")
                    }
                    #endif
                    Button("Send", systemImage: "paperplane.fill") { model.sendChat(scope) }
                        .labelStyle(.iconOnly)
                        .disabled(model.reconnecting || model.chat.sending != nil || (model.chat.drafts[scope] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Message to \(destination)"))
                // The placeholder disappears while typing; keep the recipient visible.
                if !shortLayout {
                    Text(serverChat ? "To server: \(destination)" : "To channel: \(destination)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, shortLayout ? 2 : 6)
        #if os(iOS)
        .toolbar(shortLayout && composing ? .hidden : .automatic, for: .navigationBar)
        #endif
    }
}

private struct ChatDraftField: View {
    @ObservedObject var model: ServerModel
    let scope: ChatScope
    let destination: String
    let focus: FocusState<Bool>.Binding
    @State private var draft: String

    init(model: ServerModel, scope: ChatScope, destination: String, focus: FocusState<Bool>.Binding) {
        self.model = model
        self.scope = scope
        self.destination = destination
        self.focus = focus
        _draft = State(initialValue: model.chat.drafts[scope] ?? "")
    }

    var body: some View {
        TextField("Message to \(destination)", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused(focus)
            .onChange(of: draft) { _, text in
                if text != (model.chat.drafts[scope] ?? "") { model.chat.drafts[scope] = text }
            }
            .onChange(of: model.chat.drafts[scope]) { old, new in
                // A delivery acknowledgment only clears what was actually sent.
                if new == nil && draft == old { draft = "" }
            }
            .onSubmit {
                model.chat.drafts[scope] = draft
                model.sendChat(scope)
            }
    }
}

private struct TranscriptEnd: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatTranscript: View {
    let lines: [ChatLine]
    @State private var nearEnd = true
    @State private var unread = false
    @Namespace private var viewport

    var body: some View {
        GeometryReader { available in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(lines, id: \.id) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: line.sender).font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: line.text).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                        .background(GeometryReader { marker in
                            Color.clear.preference(key: TranscriptEnd.self, value: marker.frame(in: .named(viewport)).maxY)
                        })
                }
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: viewport)
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(TranscriptEnd.self) { end in
                    nearEnd = end <= available.size.height + 24
                    if nearEnd { unread = false }
                }
                .onChange(of: lines.last?.id, initial: true) { old, latest in
                    guard latest != nil else { return }
                    if old == nil || nearEnd { proxy.scrollTo("end", anchor: .bottom) }
                    else { unread = true }
                }
                .overlay(alignment: .bottomTrailing) {
                    if unread {
                        Button("New messages", systemImage: "arrow.down") {
                            proxy.scrollTo("end", anchor: .bottom)
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

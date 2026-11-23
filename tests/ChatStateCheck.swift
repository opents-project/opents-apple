import Foundation

/// Standalone offline check using the same state that backs the SwiftUI chat window.
@main struct ChatStateCheck {
    static func main() {
        let room = ChatScope.channel(id: 17)
        let other = ChatScope.channel(id: 18)
        var chat = ChatState()
        chat.receive([
            ChatLine(id: 1, scope: room, sender: "Member", text: "room only"),
            ChatLine(id: 2, scope: .server, sender: "Admin", text: "server only"),
            ChatLine(id: 3, scope: other, sender: "Member", text: "other room"),
        ])
        precondition(chat.transcript(for: room).map(\.text) == ["room only"])
        precondition(chat.transcript(for: .server).map(\.text) == ["server only"])
        chat.drafts[room] = "retry me"
        chat.sending = room
        chat.finish(room, text: "retry me", failure: "You lack permission to send this message.")
        precondition(chat.sending == nil && chat.drafts[room] == "retry me")
        precondition(chat.errors[room] != nil && chat.errors[.server] == nil)
        chat.finish(room, text: "retry me", failure: nil)
        precondition(chat.drafts[room] == nil && chat.errors[room] == nil)
        chat.drafts[.server] = "next message"
        chat.finish(.server, text: "previous message", failure: nil)
        precondition(chat.drafts[.server] == "next message")
        print("Scope filtering, rejection feedback, draft retention and acknowledgment passed.")
    }
}

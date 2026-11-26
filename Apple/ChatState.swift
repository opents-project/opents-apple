import Foundation

struct ChatState {
    private(set) var lines: [ChatLine] = []
    var directNames: [ChatScope: String] = [:]
    var drafts: [ChatScope: String] = [:]
    var errors: [ChatScope: String] = [:]
    var sending: ChatScope?

    mutating func receive(_ batch: [ChatLine]) {
        for line in batch {
            if case .direct = line.scope, directNames[line.scope] == nil {
                directNames[line.scope] = line.sender
            }
        }
        lines.append(contentsOf: batch)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    mutating func finish(_ scope: ChatScope, text: String, failure: String?) {
        sending = nil
        errors[scope] = failure.map { NSLocalizedString($0, comment: "Chat delivery error") }
        if failure == nil && drafts[scope] == text { drafts[scope] = nil }
    }

    func transcript(for scope: ChatScope) -> [ChatLine] { lines.filter { $0.scope == scope } }
}

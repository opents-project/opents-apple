import Foundation

struct ServerLogEntry: Identifiable, Equatable {
    let id: Int
    let time: Date
    let message: String
}

struct ServerLogPage {
    let entries: [ServerLogEntry] // newest first
    let olderCursor: Int?
}

enum ServerLogRead {
    case page(ServerLogPage)
    case denied
    case failed
}

struct ServerLogRequest: Equatable {
    let id = UUID()
    let server: String
    let cursor: Int?
}

struct ServerLogState {
    private(set) var server: String?
    private(set) var entries: [ServerLogEntry] = []
    private(set) var pending: ServerLogRequest?
    private(set) var denied = false
    private(set) var failed = false
    private(set) var finished = false
    private var cursor: Int?
    private var seenIDs: Set<Int> = []

    mutating func reset(server: String?) {
        self = ServerLogState()
        self.server = server
    }

    mutating func begin() -> ServerLogRequest? {
        guard let server, pending == nil, !denied, !finished else { return nil }
        let request = ServerLogRequest(server: server, cursor: cursor)
        pending = request
        failed = false
        return request
    }

    mutating func complete(_ request: ServerLogRequest, with result: ServerLogRead) {
        guard pending == request else { return }
        pending = nil
        switch result {
        case .page(let page):
            // File positions must move backwards as older pages are requested.
            if let old = cursor, let next = page.olderCursor, next >= old {
                failed = true
                return
            }
            for entry in page.entries where seenIDs.insert(entry.id).inserted {
                entries.append(entry)
            }
            cursor = page.olderCursor
            finished = cursor == nil
        case .denied:
            reset(server: server)
            denied = true
        case .failed:
            failed = true
        }
    }
}

#if DEBUG
enum LogSample {
    case populated, empty, denied, failed

    func read(_ request: ServerLogRequest) -> ServerLogRead {
        switch self {
        case .empty: return .page(ServerLogPage(entries: [], olderCursor: nil))
        case .denied: return .denied
        case .failed: return .failed
        case .populated:
            let events = ["Server started", "Client connected", "Channel created", "Client moved",
                          "Client disconnected", "Client connected", "Channel updated"]
            let end = request.cursor ?? events.count
            guard end > 0 && end <= events.count else { return .failed }
            let start = max(0, end - 3)
            let entries = (start..<end).reversed().map { index in
                ServerLogEntry(id: index, time: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60)),
                               message: "\(request.server) · \(events[index])")
            }
            return .page(ServerLogPage(entries: entries, olderCursor: start > 0 ? start : nil))
        }
    }
}
#endif

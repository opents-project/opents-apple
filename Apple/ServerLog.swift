import Foundation

struct ServerLogEntry: Identifiable, Equatable {
    let id: Int
    let time: Date?
    let message: String
}

struct ServerLogPage {
    let entries: [ServerLogEntry] // newest first
    let olderCursor: UInt64?

    static func live(_ lines: [String], olderCursor: UInt64?, following entries: [ServerLogEntry]) -> Self {
        let limit = min(lines.count, entries.count)
        let overlap = (0...limit).reversed().first { count in
            entries.suffix(count).map(\.message).elementsEqual(lines.prefix(count))
        } ?? 0
        let nextEntries = lines.dropFirst(overlap).enumerated().map { index, line in
            ServerLogEntry(id: entries.count + index, time: nil, message: line)
        }
        return Self(entries: nextEntries, olderCursor: olderCursor)
    }
}

enum ServerLogRead {
    case page(ServerLogPage)
    case denied(permission: UInt32?)
    case failed(message: String?)
}

struct ServerLogRequest: Equatable {
    let id = UUID()
    let server: String
    let cursor: UInt64?
}

struct ServerLogState {
    private(set) var server: String?
    private(set) var entries: [ServerLogEntry] = []
    private(set) var pending: ServerLogRequest?
    private(set) var denied = false
    private(set) var failed = false
    private(set) var finished = false
    private(set) var deniedPermission: UInt32?
    private(set) var failureMessage: String?
    private var cursor: UInt64?
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
        failureMessage = nil
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
        case .denied(let permission):
            reset(server: server)
            denied = true
            deniedPermission = permission
        case .failed(let message):
            failed = true
            failureMessage = message
        }
    }
}

#if DEBUG
enum LogSample {
    case populated, empty, denied, failed

    func read(_ request: ServerLogRequest) -> ServerLogRead {
        switch self {
        case .empty: return .page(ServerLogPage(entries: [], olderCursor: nil))
        case .denied: return .denied(permission: nil)
        case .failed: return .failed(message: nil)
        case .populated:
            let events = ["Server started", "Client connected", "Channel created", "Client moved",
                          "Client disconnected", "Client connected", "Channel updated"]
            guard let end = Int(exactly: request.cursor ?? UInt64(events.count)),
                  (1...events.count).contains(end) else { return .failed(message: nil) }
            let start = max(0, end - 3)
            let entries = (start..<end).reversed().map { index in
                ServerLogEntry(id: index, time: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60)),
                               message: "\(request.server) · \(events[index])")
            }
            return .page(ServerLogPage(entries: entries, olderCursor: start > 0 ? UInt64(start) : nil))
        }
    }
}
#endif

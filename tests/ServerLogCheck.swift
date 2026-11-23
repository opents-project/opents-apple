import Foundation

@main struct ServerLogCheck {
    static func main() {
        var log = ServerLogState()
        precondition(log.begin() == nil)
        log.reset(server: "A")
        let first = log.begin()!
        precondition(log.begin() == nil)
        log.complete(first, with: LogSample.populated.read(first))
        log.complete(first, with: .denied)
        precondition(log.entries.map(\.id) == [6, 5, 4])
        let second = log.begin()!
        precondition(second.cursor == 4)
        log.complete(second, with: .failed)
        precondition(log.failed && log.entries.count == 3)
        let retry = log.begin()!
        precondition(retry.cursor == 4 && retry != second)
        log.complete(retry, with: LogSample.populated.read(retry))
        let last = log.begin()!
        precondition(last.cursor == 1)
        log.complete(last, with: LogSample.populated.read(last))
        precondition(log.entries.map(\.id) == [6,5,4,3,2,1,0] && log.finished && log.begin() == nil)

        log.reset(server: "A")
        let seed = log.begin()!
        log.complete(seed, with: LogSample.populated.read(seed))
        let stale = log.begin()!
        log.reset(server: "B")
        let fresh = log.begin()!
        log.complete(stale, with: LogSample.populated.read(stale))
        precondition(log.entries.isEmpty && log.pending == fresh)
        log.complete(fresh, with: LogSample.empty.read(fresh))
        precondition(log.finished && log.entries.isEmpty && !log.denied && !log.failed)
        log.reset(server: "B")
        let loading = log.begin()!
        log.complete(loading, with: LogSample.populated.read(loading))
        let older = log.begin()!
        log.complete(older, with: .page(ServerLogPage(entries: Array(log.entries.suffix(1)), olderCursor: 1)))
        precondition(log.entries.count == 3)
        let repeatedCursor = log.begin()!
        log.complete(repeatedCursor, with: .page(ServerLogPage(entries: [], olderCursor: 1)))
        precondition(log.failed)
        let blocked = log.begin()!
        log.complete(blocked, with: LogSample.denied.read(blocked))
        precondition(log.denied && log.entries.isEmpty && log.begin() == nil)
        log.reset(server: "B")
        let seedB = log.begin()!
        log.complete(seedB, with: LogSample.populated.read(seedB))
        let oldConnection = log.begin()!
        log.reset(server: nil)
        log.complete(oldConnection, with: LogSample.populated.read(oldConnection))
        precondition(log.server == nil && log.entries.isEmpty && log.begin() == nil)
        log.reset(server: "B")
        let reconnected = log.begin()!
        log.complete(oldConnection, with: .denied)
        precondition(log.pending == reconnected && !log.denied)
        print("Pagination, overlap, retries, empty, denied, disconnect and stale responses passed.")
    }
}

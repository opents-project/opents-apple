import Foundation

@main struct OfflineFilesCheck {
    static func main() {
        let root = ChannelFilePath.root
        precondition(root.parent == nil && root.display == "/")
        precondition(ChannelFilePath("//Documents/./") == root.child("Documents"))
        precondition(ChannelFilePath("/cafe\u{301}")?.display == "/café")
        for path in ["", "relative", "/..", "/Documents/../notes.txt", "/a\\..\\b", "/a\u{0}b"] {
            precondition(ChannelFilePath(path) == nil, path)
        }
        for name in ["", ".", "..", "a/b", "/outside", "a\\b"] { precondition(root.child(name) == nil) }
        precondition(root.child("Empty")?.parent == root)

        var browser = OfflineFileBrowser()
        func navigate(_ path: ChannelFilePath) {
            let read = browser.open(path)!
            browser.receive(OfflineFileBrowser.sample(read), for: read)
        }
        precondition(browser.open(root) == nil)
        browser.reset(server: "A")
        navigate(root)
        guard case .listing(let rows) = browser.result else { preconditionFailure() }
        precondition(rows.count == 5)
        precondition(browser.start(.download, name: "Documents") == nil)
        precondition(browser.start(.download, name: "missing") == nil)
        precondition(browser.start(.upload, name: "../escape") == nil)
        let download = browser.start(.download, name: "welcome.txt")!
        let upload = browser.start(.upload, name: "example.txt")!
        browser.advance(download, percent: 60)
        browser.advance(download, percent: 20)
        precondition(browser.transfers[0].percent == 60)
        browser.stop(download, reason: .cancelled)
        browser.advance(download, percent: 100)
        browser.stop(download, reason: .failed)
        precondition(browser.transfers[0].status == .cancelled && browser.transfers[0].percent == 60)
        browser.advance(upload, percent: 110)
        precondition(browser.transfers[1].status == .completed && browser.transfers[1].percent == 100)
        for reason in [SimulatedTransferStatus.denied, .failed] {
            let id = browser.start(.upload, name: "sample.txt")!
            browser.stop(id, reason: reason)
            browser.advance(id, percent: 100)
            precondition(browser.transfers.last?.status == reason)
        }
        let oldDirectory = browser.open(root.child("Documents")!)!
        navigate(root.child("Empty")!)
        browser.receive(.failed, for: oldDirectory)
        precondition(browser.result == .listing([]))
        navigate(root.child("Restricted")!)
        precondition(browser.result == .denied && browser.start(.upload, name: "sample") == nil)
        navigate(root.child("Unavailable")!)
        precondition(browser.result == .failed)

        for next: String? in ["A", "B", nil] {
            navigate(root)
            let staleID = browser.start(.upload, name: "stale")!
            let staleRead = browser.open(root.child("Documents")!)!
            browser.reset(server: next)
            let pending = browser.open(root)
            browser.receive(.denied, for: staleRead)
            browser.advance(staleID, percent: 90)
            browser.stop(staleID, reason: .failed)
            precondition(browser.path == root && browser.transfers.isEmpty && browser.result == nil)
            precondition(browser.request == pending && (pending == nil) == (next == nil))
            if let pending { browser.receive(OfflineFileBrowser.sample(pending), for: pending) }
        }
        print("Virtual paths, listing states, transfer progress, cancel, errors and stale callbacks passed.")
    }
}

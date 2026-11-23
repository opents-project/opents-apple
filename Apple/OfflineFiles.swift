#if DEBUG
import Foundation

/// Absolute paths in the simulated channel's file namespace.
struct ChannelFilePath: Hashable {
    let components: [String]
    var display: String { "/" + components.joined(separator: "/") }
    static let root = ChannelFilePath(components: [])

    private init(components: [String]) { self.components = components }

    init?(_ raw: String) {
        guard raw.hasPrefix("/"), !raw.contains("\\"), !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        let parts = raw.split(separator: "/")
        guard !parts.contains("..") else { return nil }
        components = parts.filter { $0 != "." }.map { String($0).precomposedStringWithCanonicalMapping }
    }

    func child(_ name: String) -> Self? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return Self(display + "/" + name)
    }

    var parent: Self? { components.isEmpty ? nil : Self(components: Array(components.dropLast())) }
}

struct SampleFile: Identifiable, Equatable {
    let name: String
    let directory: Bool
    var id: String { name }
}

enum DirectoryResult: Equatable {
    case listing([SampleFile]), denied, failed
}

struct DirectoryRead: Equatable {
    let id = UUID()
    let path: ChannelFilePath
}

enum SimulatedDirection { case upload, download }
enum SimulatedTransferStatus { case running, completed, cancelled, denied, failed }

struct SimulatedTransfer: Identifiable {
    let id = UUID()
    let direction: SimulatedDirection
    let path: ChannelFilePath
    var percent = 0
    var status = SimulatedTransferStatus.running
}

struct OfflineFileBrowser {
    private(set) var server: String?
    private(set) var path = ChannelFilePath.root
    private(set) var request: DirectoryRead?
    private(set) var result: DirectoryResult?
    private(set) var transfers: [SimulatedTransfer] = []

    mutating func reset(server: String?) {
        self = Self()
        self.server = server
    }

    mutating func open(_ path: ChannelFilePath) -> DirectoryRead? {
        guard server != nil else { return nil }
        self.path = path
        result = nil
        let read = DirectoryRead(path: path)
        request = read
        return read
    }

    mutating func receive(_ value: DirectoryResult, for read: DirectoryRead) {
        guard request == read else { return }
        request = nil
        result = value
    }

    mutating func start(_ direction: SimulatedDirection, name: String) -> UUID? {
        guard server != nil, case .listing(let entries) = result,
              let target = path.child(name) else { return nil }
        if direction == .download && !entries.contains(SampleFile(name: name, directory: false)) { return nil }
        let transfer = SimulatedTransfer(direction: direction, path: target)
        transfers.append(transfer)
        return transfer.id
    }

    mutating func advance(_ id: UUID, percent: Int) {
        guard let i = transfers.firstIndex(where: { $0.id == id && $0.status == .running }) else { return }
        transfers[i].percent = min(100, max(transfers[i].percent, percent))
        if transfers[i].percent == 100 { transfers[i].status = .completed }
    }

    mutating func stop(_ id: UUID, reason: SimulatedTransferStatus) {
        guard [.cancelled, .denied, .failed].contains(reason),
              let i = transfers.firstIndex(where: { $0.id == id && $0.status == .running }) else { return }
        transfers[i].status = reason
    }

    static func sample(_ read: DirectoryRead) -> DirectoryResult {
        switch read.path.display {
        case "/": return .listing([
            SampleFile(name: "Documents", directory: true), SampleFile(name: "Empty", directory: true),
            SampleFile(name: "Restricted", directory: true), SampleFile(name: "Unavailable", directory: true),
            SampleFile(name: "welcome.txt", directory: false)])
        case "/Documents": return .listing([SampleFile(name: "notes.txt", directory: false)])
        case "/Empty": return .listing([])
        case "/Restricted": return .denied
        default: return .failed
        }
    }
}
#endif

import Foundation

enum ConnectionUnits {
    static func rate(_ bytesPerSecond: UInt64) -> String {
        let units = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"]
        var value = Double(bytesPerSecond)
        var index = 0
        while value >= 1000 && index + 1 < units.count {
            value /= 1000
            index += 1
        }
        let count = value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...1)))
        return "\(count) \(units[index])"
    }
}

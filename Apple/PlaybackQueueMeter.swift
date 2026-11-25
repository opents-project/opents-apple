import Foundation

/// Counts buffers scheduled but not yet acknowledged by dataPlayedBack.
/// These are callback observations, not HAL underrun notifications.
final class PlaybackQueueMeter: @unchecked Sendable {
    struct Reading {
        var pending = 0
        var drained = 0
        var maxEmptyMs: UInt64 = 0
        var maxRefillMs: UInt64 = 0
    }

    private let lock = NSLock()
    private var reading = Reading()
    private var emptySince: UInt64?

    func scheduled(refilling completion: UInt64?, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            if let completion, now > completion { reading.maxRefillMs = max(reading.maxRefillMs, (now - completion) / 1_000_000) }
            if let emptySince, now > emptySince { reading.maxEmptyMs = max(reading.maxEmptyMs, (now - emptySince) / 1_000_000) }
            emptySince = nil
            reading.pending += 1
        }
    }

    func completed(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        lock.withLock {
            reading.pending -= 1
            if reading.pending == 0 {
                reading.drained += 1
                emptySince = now
            }
        }
        return now
    }

    func snapshot() -> Reading { lock.withLock { reading } }
}

import AVFoundation

@main
enum PlaybackQueueCheck {
    static func main() throws {
        let meter = PlaybackQueueMeter()
        for _ in 0..<3 { meter.scheduled(refilling: nil, now: 0) }
        let first = meter.completed(now: 20_000_000)
        _ = meter.completed(now: 40_000_000)
        _ = meter.completed(now: 60_000_000)
        meter.scheduled(refilling: first, now: 95_000_000)
        let stats = meter.snapshot()
        precondition(stats.pending == 1 && stats.drained == 1 && stats.maxRefillMs == 75 && stats.maxEmptyMs == 35)
        let healthy = PlaybackQueueMeter()
        for _ in 0..<3 { healthy.scheduled(refilling: nil, now: 0) }
        for i in 1...50 {
            let time = UInt64(i * 20_000_000)
            let completed = healthy.completed(now: time)
            healthy.scheduled(refilling: completed, now: time + 500_000)
        }
        precondition(healthy.snapshot().pending == 3 && healthy.snapshot().drained == 0)

        // Use the real player and an offline render clock. Defer refills for
        // exactly two quanta after exhausting the three preloaded buffers.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
        try engine.start()
        defer { player.stop(); engine.stop() }
        func enqueue() {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for side in 0..<2 {
                for i in 0..<960 { buffer.floatChannelData![side][i] = 0.5 * sin(Float(i) * .pi / 24) }
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in }
        }
        for _ in 0..<3 { enqueue() }
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        var audible: [Bool] = []
        for tick in 0..<8 {
            if tick == 5 { for _ in 0..<3 { enqueue() } }
            if tick > 5 { enqueue() }
            let status = try engine.renderOffline(960, to: output)
            precondition(status == .success && output.frameLength == 960)
            let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: 960)
            audible.append(samples.contains { abs($0) > 0.01 })
        }
        precondition(audible == [true, true, true, false, false, true, true, true], "Unexpected offline PCM: \(audible)")
        print("PASS: real offline player rendered 60 ms of tone, 40 ms of silence, then tone after refilling three buffers")
        print("PASS: modeled 75 ms refill delay, queue empty for 35 ms; prompt refills never drained")

        // Render the production pump's interleaved PCM, keeping old callbacks
        // alive across stop to check that they cannot pull a later frame.
        player.stop()
        let source = TestFrames()
        let pump = VoicePlaybackPump(player: player, format: format, meter: PlaybackQueueMeter()) {
            source.next()
        }
        pump.start()
        pump.stop()
        let countAtStop = source.count
        precondition(countAtStop >= 3)
        for _ in 0..<3 {
            let status = try engine.renderOffline(960, to: output)
            precondition(status == .success && output.frameLength == 960)
            let channels = output.floatChannelData!
            precondition(abs(channels[0][480] - 0.25) < 0.001)
            precondition(abs(channels[1][480] + 0.5) < 0.001)
        }
        player.stop()
        // Stop synchronizes with work already enqueued by completion handlers.
        pump.stop()
        precondition(source.count == countAtStop)
        print("PASS: production pump preserves stereo and stops pulling PCM on teardown")
    }
}

private final class TestFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var pulls = 0
    var count: Int { lock.withLock { pulls } }

    func next() -> [Float] {
        lock.withLock { pulls += 1 }
        return (0..<1920).map { $0.isMultiple(of: 2) ? 0.25 : -0.5 }
    }
}

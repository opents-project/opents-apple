import AVFoundation

/// One pump per engine. Only the serial queue pulls PCM or schedules buffers.
final class VoicePlaybackPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.opents.playback", qos: .userInitiated)
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let meter: PlaybackQueueMeter
    private let frame: @Sendable () -> [Float]
    private var active = false

    init(player: AVAudioPlayerNode, format: AVAudioFormat, meter: PlaybackQueueMeter,
         frame: @escaping @Sendable () -> [Float]) {
        self.player = player
        self.format = format
        self.meter = meter
        self.frame = frame
    }

    func start() {
        queue.sync {
            active = true
            for _ in 0..<3 { schedule() }
            player.play()
        }
    }

    // Wait for any in-flight schedule before the owner stops or replaces its engine.
    func stop() { queue.sync { active = false } }

    private func schedule(completion: UInt64? = nil) {
        guard active,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
              let channels = buffer.floatChannelData else { return }
        let samples = frame()
        for i in 0..<960 {
            channels[0][i] = samples[2 * i]
            channels[1][i] = samples[2 * i + 1]
        }
        buffer.frameLength = 960
        meter.scheduled(refilling: completion)
        // Refill when the player consumes PCM, before downstream device latency.
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            let completed = self.meter.completed()
            self.queue.async { self.schedule(completion: completed) }
        }
    }
}

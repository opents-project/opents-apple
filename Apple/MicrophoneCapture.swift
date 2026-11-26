import AVFoundation

enum MicrophoneCapture {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    #if os(iOS)
    static func activateSession(microphone: Bool, processing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if microphone {
            try session.setCategory(.playAndRecord, mode: processing ? .voiceChat : .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
        } else {
            try session.setCategory(.playback)
        }
        try session.setActive(true)
    }
    #endif

    static func install(on engine: AVAudioEngine,
                        receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioConverter) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: min(2, format.channelCount)),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "OpenTS", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Microphone format unavailable")])
        }
        input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in receive(buffer, converter) }
    }

    static func levelDBFS(_ frame: ArraySlice<Float>) -> Double {
        guard !frame.isEmpty else { return -90 }
        let power = frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.count)
        guard power.isFinite else { return -90 }
        return min(0, 10 * log10(max(power, 1e-9)))
    }
}

/// The input tap may run concurrently with button and device changes.
final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var held = false
    private var remainder: [Float] = []

    private var threshold: Double?
    private var tailFrames = 0
    private var level = -90.0

    var reading: (level: Double, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (level, held || tailFrames > 0)
    }

    func configure(held value: Bool, threshold newThreshold: Double?) {
        lock.lock()
        defer { lock.unlock() }
        if (threshold == nil) != (newThreshold == nil) || (!value && newThreshold == nil) {
            remainder.removeAll(keepingCapacity: true)
            tailFrames = 0
            level = -90
        }
        held = value
        threshold = newThreshold
    }

    @discardableResult
    func consume(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, epoch newEpoch: UInt64 = 1, send: ([Float]) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if epoch != newEpoch {
            converter.reset()
            remainder.removeAll(keepingCapacity: true)
            tailFrames = 0
            level = -90
            epoch = newEpoch
        }
        guard epoch != 0, held || threshold != nil else { return true }
        let format = converter.outputFormat
        let capacity = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(capacity)) else { return false }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true
            result.pointee = .haveData
            return input
        }
        guard status != .error, let channels = output.floatChannelData else { return false }
        let count = Int(output.frameLength)
        let width = Int(format.channelCount)
        if width == 1 {
            remainder.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
        } else {
            for i in 0..<count {
                remainder.append(channels[0][i])
                remainder.append(channels[1][i])
            }
        }
        let samplesPerPacket = 960 * width
        while remainder.count >= samplesPerPacket {
            let frame = remainder.prefix(samplesPerPacket)
            if let threshold {
                level = MicrophoneCapture.levelDBFS(frame)
                if level >= threshold { tailFrames = 13 }
                if tailFrames > 0 {
                    send(Array(frame))
                    tailFrames -= 1
                }
            } else {
                send(Array(frame))
            }
            remainder.removeFirst(samplesPerPacket)
        }
        return true
    }
}

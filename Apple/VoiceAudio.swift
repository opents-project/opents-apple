import AVFoundation
import SwiftUI

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

    func consume(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, epoch newEpoch: UInt64 = 1, send: ([Float]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if epoch != newEpoch {
            converter.reset()
            remainder.removeAll(keepingCapacity: true)
            tailFrames = 0
            level = -90
            epoch = newEpoch
        }
        guard epoch != 0, held || threshold != nil else { return }
        let format = converter.outputFormat
        let capacity = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(capacity)) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true
            result.pointee = .haveData
            return input
        }
        guard status != .error, let channels = output.floatChannelData else { return }
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
                let power = frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samplesPerPacket)
                level = 10 * log10(max(power, 1e-9))
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
    }
}

@MainActor
final class VoiceAudio: ObservableObject {
    @Published private(set) var microphone = false
    @Published private(set) var output = false
    @Published private(set) var talking = false
    @Published private(set) var message: String?

    @Published var voiceActivated = false { didSet { resetTalkControls() } }
    @Published var threshold = -40.0 { didSet { press(false) } }
    var reading: (level: Double, active: Bool) { gate.reading }
    @Published private(set) var standardInput = false

    @Published private(set) var voice: Voice?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var installedTap = false
    private let gate = CaptureGate()
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    func connect(_ voice: Voice) {
        disconnect()
        self.voice = voice
        configure(mic: false, play: true)
    }

    func setMicrophone(_ on: Bool) async {
        guard let original = voice else { return }
        if installedTap {
            microphone = on
            if !on { press(false) }
            publishDevices()
            return
        }
        if on {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard voice === original else { return }
            guard allowed else { message = String(localized: "Allow microphone access in System Settings to talk."); return }
        }
        configure(mic: on, play: output)
    }

    func toggleOutput() {
        guard let player else { configure(mic: microphone, play: true); return }
        output.toggle()
        player.volume = output ? 1 : 0
        if !output { press(false) }
        publishDevices()
    }

    private func publishDevices() {
        resetTalkControls()
        voice?.setDevices(microphone: installedTap, output: player != nil,
                          micMuted: installedTap && !microphone, outputMuted: player != nil && !output)
    }

    private var buttonHeld = false
    private var shortcutHeld = false

    #if os(macOS)
    @Published var globalShortcut = UserDefaults.standard.bool(forKey: "globalTalkShortcut") {
        didSet {
            UserDefaults.standard.set(globalShortcut, forKey: "globalTalkShortcut")
            resetTalkControls()
        }
    }
    @Published private(set) var shortcutUnavailable = false
    private lazy var hotKey = TalkHotKey { [weak self] held in
        self?.shortcutHeld = held
        self?.updateTransmission()
    }
    #endif

    private func resetTalkControls() {
        buttonHeld = false
        shortcutHeld = false
        #if os(macOS)
        if globalShortcut && microphone && output && !voiceActivated {
            shortcutUnavailable = !hotKey.start()
        } else {
            hotKey.stop()
            shortcutUnavailable = false
        }
        #endif
        updateTransmission()
    }

    func press(_ held: Bool) {
        buttonHeld = held
        updateTransmission()
    }

    private func updateTransmission() {
        talking = (buttonHeld || shortcutHeld) && microphone && output && !voiceActivated
        gate.configure(held: talking, threshold: voiceActivated && microphone && output ? threshold : nil)
    }

    func disconnect() {
        stopEngine()
        voiceActivated = false
        voice = nil
        message = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func stopEngine() {
        press(false)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if installedTap { engine?.inputNode.removeTap(onBus: 0) }
        installedTap = false
        let previous = player
        player = nil
        engine?.stop()
        previous?.stop()
        engine = nil
        microphone = false
        output = false
        publishDevices()
    }

    private func configure(mic: Bool, play: Bool) {
        stopEngine()
        standardInput = false
        message = nil
        guard let voice else { return }
        if mic {
            do {
                try start(voice, mic: true, play: play, processing: true)
                return
            } catch { stopEngine() }
            do {
                try start(voice, mic: true, play: play, processing: false)
                standardInput = true
                message = String(localized: "Voice processing unavailable. Using standard microphone input.")
                return
            } catch {
                stopEngine()
                message = String(localized: "Microphone unavailable: \(error.localizedDescription)")
            }
        }
        do { try start(voice, mic: false, play: play, processing: false) }
        catch {
            stopEngine()
            let failure = String(localized: "Playback unavailable: \(error.localizedDescription)")
            message = [message, failure].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func start(_ voice: Voice, mic: Bool, play: Bool, processing: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if mic {
            try session.setCategory(.playAndRecord, mode: processing ? .voiceChat : .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        } else {
            try session.setCategory(.playback)
        }
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if mic {
            if processing { try engine.inputNode.setVoiceProcessingEnabled(true) }
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let captureFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: min(2, inputFormat.channelCount)),
                  let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
                throw NSError(domain: "OpenTS", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Microphone format unavailable")])
            }
            engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [gate] buffer, _ in
                let epoch = voice.captureEpoch()
                gate.consume(buffer, converter: converter, epoch: epoch) { voice.submitPcm(epoch: epoch, samples: $0) }
            }
            installedTap = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: stereo)
        try engine.start()
        self.player = player
        microphone = mic
        output = play
        player.volume = play ? 1 : 0
        for _ in 0..<3 { schedule(player, voice: voice) }
        player.play()
        publishDevices()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.configure(mic: self.microphone, play: self.output)
            }
        }
    }

    private func schedule(_ node: AVAudioPlayerNode, voice: Voice) {
        guard node === player,
              let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 960),
              let channels = buffer.floatChannelData else { return }
        let samples = voice.playbackFrame()
        for i in 0..<960 {
            channels[0][i] = samples[2 * i]
            channels[1][i] = samples[2 * i + 1]
        }
        buffer.frameLength = 960
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak node] _ in
            Task { @MainActor in
                guard let self, let node else { return }
                self.schedule(node, voice: voice)
            }
        }
    }
}

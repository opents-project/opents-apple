import AVFoundation
import SwiftUI

/// The input tap may run concurrently with button and device changes.
private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var remainder: [Float] = []

    func setHeld(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        held = value
        if !value { remainder.removeAll(keepingCapacity: true) }
    }

    func consume(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, voice: Voice) {
        lock.lock()
        defer { lock.unlock() }
        guard held else { return }
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
        guard status != .error, let samples = output.floatChannelData?[0] else { return }
        remainder.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        while remainder.count >= 960 {
            voice.submitCapture(samples: Array(remainder.prefix(960)))
            remainder.removeFirst(960)
        }
    }
}

@MainActor
final class VoiceAudio: ObservableObject {
    @Published private(set) var microphone = false
    @Published private(set) var output = false
    @Published private(set) var talking = false
    @Published private(set) var message: String?

    private var voice: Voice?
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
        if on {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard voice === original else { return }
            guard allowed else { message = "Allow microphone access in System Settings to talk."; return }
        }
        configure(mic: on, play: output)
    }

    func toggleOutput() { configure(mic: microphone, play: !output) }

    func press(_ held: Bool) {
        talking = held && microphone && output
        gate.setHeld(talking)
    }

    func disconnect() {
        stopEngine()
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
        voice?.setDevices(microphone: false, output: false)
    }

    private func configure(mic: Bool, play: Bool) {
        stopEngine()
        message = nil
        guard let voice, play || mic else { return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            if mic {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
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
                try engine.inputNode.setVoiceProcessingEnabled(true)
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                      let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                      let converter = AVAudioConverter(from: inputFormat, to: mono) else {
                    throw NSError(domain: "OpenTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone format unavailable"])
                }
                engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [gate] buffer, _ in
                    gate.consume(buffer, converter: converter, voice: voice)
                }
                installedTap = true
            }
            engine.connect(player, to: engine.mainMixerNode, format: stereo)
            try engine.start()
            self.player = player
            microphone = mic
            output = play
            if play {
                for _ in 0..<3 { schedule(player, voice: voice) }
                player.play()
            }
            voice.setDevices(microphone: mic, output: play)
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self, let engine, self.engine === engine else { return }
                    self.configure(mic: self.microphone, play: self.output)
                }
            }
        } catch {
            stopEngine()
            message = error.localizedDescription
        }
    }

    private func schedule(_ node: AVAudioPlayerNode, voice: Voice) {
        guard node === player, output,
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

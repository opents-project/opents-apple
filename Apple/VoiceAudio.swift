import AVFoundation
import SwiftUI

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
    private(set) var playbackMeter = PlaybackQueueMeter()
    private var observer: NSObjectProtocol?
    private var installedTap = false
    private let gate = CaptureGate()
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    func connect(_ voice: Voice) {
        disconnect()
        self.voice = voice
        #if os(macOS)
        deviceMonitor = MacDeviceMonitor { [weak self] in self?.refreshDevices() }
        devices.inventory = MacAudioHardware.inventory()
        #endif
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
        #if os(macOS)
        requestedOutput = output
        #endif
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
    @Published private(set) var devices = MacDeviceSelection()
    private var deviceMonitor: MacDeviceMonitor?
    private var requestedOutput = false

    var hasInputRoute: Bool { installedTap }
    var hasOutputRoute: Bool { player != nil }

    func selectDevice(_ side: DeviceSide, uid: String?) {
        let previous = devices.preferred[side]
        devices.choose(side, uid: uid)
        if previous != devices.preferred[side], voice != nil, side == .output || installedTap {
            configure(mic: microphone, play: requestedOutput)
        }
    }

    func refreshDevices() {
        guard voice != nil else { return }
        if devices.updateInventory(MacAudioHardware.inventory(), microphone: installedTap, outputActive: player != nil) {
            configure(mic: microphone, play: requestedOutput)
        }
    }

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
        #if os(macOS)
        deviceMonitor = nil
        #endif
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
        playbackMeter = PlaybackQueueMeter()
        engine?.stop()
        previous?.stop()
        engine = nil
        #if os(macOS)
        devices.actual = [:]
        #endif
        microphone = false
        output = false
        publishDevices()
    }

    private func configure(mic: Bool, play: Bool) {
        stopEngine()
        standardInput = false
        message = nil
        guard let voice else { return }
        #if os(macOS)
        requestedOutput = play
        #endif
        if mic {
            do { try startAudio(voice, mic: true, play: play); return }
            catch {
                stopEngine()
                message = String(localized: "Microphone unavailable: \(error.localizedDescription)")
            }
        }
        do { try startAudio(voice, mic: false, play: play) }
        catch {
            stopEngine()
            let failure = String(localized: "Playback unavailable: \(error.localizedDescription)")
            message = [message, failure].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func startAudio(_ voice: Voice, mic: Bool, play: Bool) throws {
        func attempt(bind: (AVAudioEngine) throws -> Void, verify: (AVAudioEngine) throws -> Void) throws {
            if mic {
                do { try start(voice, mic: true, play: play, processing: true, bind: bind, verify: verify); return }
                catch { stopEngine() }
            }
            try start(voice, mic: mic, play: play, processing: false, bind: bind, verify: verify)
            if mic {
                standardInput = true
                message = String(localized: "Voice processing unavailable. Using standard microphone input.")
            }
        }
        #if os(macOS)
        try MacDeviceSelection.start(bindings: devices.bindings(microphone: mic)) { ids in
            do {
                try attempt(bind: { try MacAudioHardware.bind(ids, to: $0) }, verify: { engine in
                    devices.actual = try MacAudioHardware.readback(engine, microphone: mic, expected: ids, defaults: devices.inventory?.defaults ?? [:])
                })
            } catch { stopEngine(); throw error }
        }
        #else
        try attempt(bind: { _ in }, verify: { _ in })
        #endif
    }

    private func start(_ voice: Voice, mic: Bool, play: Bool, processing: Bool,
                       bind: (AVAudioEngine) throws -> Void, verify: (AVAudioEngine) throws -> Void) throws {
        #if os(iOS)
        try MicrophoneCapture.activateSession(microphone: mic, processing: processing)
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if processing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        try bind(engine)
        if mic {
            try MicrophoneCapture.install(on: engine) { [gate] buffer, converter in
                let epoch = voice.captureEpoch()
                gate.consume(buffer, converter: converter, epoch: epoch) { voice.submitPcm(epoch: epoch, samples: $0) }
            }
            installedTap = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: stereo)
        try engine.start()
        try verify(engine)
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

    private func schedule(_ node: AVAudioPlayerNode, voice: Voice, completion: UInt64? = nil) {
        guard node === player,
              let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 960),
              let channels = buffer.floatChannelData else { return }
        let samples = voice.playbackFrame()
        for i in 0..<960 {
            channels[0][i] = samples[2 * i]
            channels[1][i] = samples[2 * i + 1]
        }
        buffer.frameLength = 960
        let meter = playbackMeter
        meter.scheduled(refilling: completion)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak node] _ in
            let completed = meter.completed()
            Task { @MainActor in
                guard let self, let node else { return }
                self.schedule(node, voice: voice, completion: completed)
            }
        }
    }
}

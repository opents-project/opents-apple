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
    private var playbackPump: VoicePlaybackPump?
    private(set) var playbackMeter = PlaybackQueueMeter()
    private var observer: NSObjectProtocol?
    #if os(iOS)
    private var sessionObservers: [NSObjectProtocol] = []
    private var interruptedSettings: (mic: Bool, play: Bool)?
    #endif
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
        #if os(iOS)
        observeSession()
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

    private var channelAllowsTransmission = true

    func setChannelAllowsTransmission(_ allowed: Bool) {
        guard channelAllowsTransmission != allowed else { return }
        channelAllowsTransmission = allowed
        resetTalkControls()
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
        if channelAllowsTransmission && globalShortcut && microphone && output && !voiceActivated {
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
        talking = channelAllowsTransmission && (buttonHeld || shortcutHeld) && microphone && output && !voiceActivated
        gate.configure(held: talking, threshold: channelAllowsTransmission && voiceActivated && microphone && output ? threshold : nil)
    }

    func disconnect() {
        #if os(macOS)
        deviceMonitor = nil
        #endif
        #if os(iOS)
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
        interruptedSettings = nil
        #endif
        stopEngine()
        voice = nil
        message = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    private func observeSession() {
        guard let observedVoice = voice else { return }
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, self.voice === observedVoice else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    guard self.interruptedSettings == nil else { return }
                    self.interruptedSettings = (self.microphone, self.output)
                    self.stopEngine()
                    self.message = String(localized: "Audio interrupted.")
                } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                          let settings = self.interruptedSettings {
                    self.interruptedSettings = nil
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.configure(mic: settings.mic, play: settings.play)
                    } else {
                        self.message = String(localized: "Audio interrupted. Reconnect to resume audio.")
                    }
                }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                  reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor in
                guard let self, self.voice === observedVoice, self.interruptedSettings == nil, self.engine != nil else { return }
                self.configure(mic: self.microphone, play: self.output)
            }
        })
    }
    #endif

    private func stopEngine() {
        press(false)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if installedTap { engine?.inputNode.removeTap(onBus: 0) }
        installedTap = false
        let previous = player
        playbackPump?.stop()
        playbackPump = nil
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
        let pump = VoicePlaybackPump(player: player, format: stereo, meter: playbackMeter) {
            voice.playbackFrame()
        }
        playbackPump = pump
        pump.start()
        publishDevices()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.configure(mic: self.microphone, play: self.output)
            }
        }
    }
}

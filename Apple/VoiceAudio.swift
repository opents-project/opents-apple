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
    @Published private(set) var audioInterrupted = false
    private var sessionObservers: [NSObjectProtocol] = []
    private var interruptedSettings: (mic: Bool, play: Bool)?
    private var ownsAudioSession = false
    private var lastEngineRecovery: ContinuousClock.Instant?
    #endif
    private var installedTap = false
    private var gate = CaptureGate()
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    @Published private var requestedOutput = true
    @Published private var resumeMicrophone = false
    private var microphonePreferenceKey: String?
    private var microphoneMuted = false
    private var microphoneRequest: UInt64 = 0
    private var tabSelected = true
    private var tabRevision: UInt64 = 0

    func connect(_ voice: Voice, serverKey: String) {
        disconnect(preservingPreferences: true)
        let key = "connectionMicrophoneMuted.v1." + serverKey
        if key != microphonePreferenceKey {
            microphonePreferenceKey = key
            microphoneMuted = UserDefaults.standard.bool(forKey: key)
            requestedOutput = true
        }
        resumeMicrophone = !microphoneMuted && !voiceActivated && MicrophoneCapture.isAuthorized
        self.voice = voice
        if tabSelected { activateTabAudio() }
    }

    func setMicrophone(_ on: Bool) async {
        guard let original = voice else { return }
        microphoneRequest &+= 1
        let request = microphoneRequest
        if on && !MicrophoneCapture.isAuthorized {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard voice === original, request == microphoneRequest else { return }
            guard allowed else {
                message = String(localized: "Allow microphone access in System Settings to talk.")
                return
            }
        }
        microphoneMuted = !on
        if let microphonePreferenceKey {
            UserDefaults.standard.set(microphoneMuted, forKey: microphonePreferenceKey)
        }
        resumeMicrophone = on
        guard tabSelected else { return }
        if installedTap {
            microphone = on
            publishDevices()
            return
        }
        #if os(iOS)
        if interruptedSettings != nil {
            interruptedSettings?.mic = on
            microphone = on
            return
        }
        #endif
        configure(mic: on, play: requestedOutput)
    }

    func toggleOutput() {
        guard voice != nil else { return }
        guard tabSelected else {
            requestedOutput.toggle()
            return
        }
        #if os(iOS)
        if interruptedSettings != nil {
            interruptedSettings?.play.toggle()
            output = interruptedSettings?.play ?? false
            requestedOutput = output
            return
        }
        #endif
        guard let player else { configure(mic: microphone, play: true); return }
        output.toggle()
        requestedOutput = output
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

    func setTabSelected(_ selected: Bool) {
        guard tabSelected != selected else { return }
        tabSelected = selected
        tabRevision &+= 1
        if selected {
            #if os(macOS)
            let shortcutEnabled = UserDefaults.standard.bool(forKey: "globalTalkShortcut")
            if globalShortcut != shortcutEnabled { globalShortcut = shortcutEnabled }
            #endif
            if voice != nil { activateTabAudio() }
        } else {
            resumeMicrophone = microphone
            deactivateTabAudio()
        }
    }

    private func activateTabAudio() {
        #if os(macOS)
        devices = MacDeviceSelection()
        devices.inventory = MacAudioHardware.inventory()
        deviceMonitor = MacDeviceMonitor { [weak self] in self?.refreshDevices() }
        #elseif os(iOS)
        observeSession()
        #endif
        configure(mic: resumeMicrophone && MicrophoneCapture.isAuthorized, play: requestedOutput)
    }

    private func deactivateTabAudio() {
        #if os(macOS)
        deviceMonitor = nil
        #elseif os(iOS)
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
        interruptedSettings = nil
        audioInterrupted = false
        lastEngineRecovery = nil
        #endif
        stopEngine()
        #if os(iOS)
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    #if os(macOS)
    @Published private(set) var devices = MacDeviceSelection()
    private var deviceMonitor: MacDeviceMonitor?

    var hasInputRoute: Bool { installedTap }
    var hasOutputRoute: Bool { player != nil }
    var microphoneEnabledForTab: Bool { tabSelected ? microphone : resumeMicrophone }
    var outputEnabledForTab: Bool { tabSelected ? output : requestedOutput }

    func selectDevice(_ side: DeviceSide, uid: String?) {
        guard tabSelected else { return }
        let previous = devices.preferred[side]
        devices.choose(side, uid: uid)
        if previous != devices.preferred[side], voice != nil, side == .output || installedTap {
            configure(mic: microphone, play: requestedOutput)
        }
    }

    func refreshDevices() {
        guard tabSelected, voice != nil else { return }
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
        if tabSelected && channelAllowsTransmission && globalShortcut && microphone && output && !voiceActivated {
            shortcutUnavailable = !hotKey.start()
        } else {
            hotKey.stop()
            shortcutUnavailable = false
        }
        #endif
        updateTransmission()
    }

    func press(_ held: Bool) {
        guard tabSelected || !held else { return }
        buttonHeld = held
        updateTransmission()
    }

    private func updateTransmission() {
        #if os(iOS)
        let available = tabSelected && !audioInterrupted
        #else
        let available = tabSelected
        #endif
        talking = available && channelAllowsTransmission && (buttonHeld || shortcutHeld) && microphone && output && !voiceActivated
        gate.configure(held: talking, threshold: available && channelAllowsTransmission && voiceActivated && microphone && output ? threshold : nil)
    }

    func disconnect(preservingPreferences: Bool = false) {
        microphoneRequest &+= 1
        deactivateTabAudio()
        resumeMicrophone = false
        if !preservingPreferences {
            requestedOutput = true
            microphonePreferenceKey = nil
            microphoneMuted = false
        }
        voice = nil
        message = nil
    }

    #if os(iOS)
    private func observeSession() {
        guard let observedVoice = voice else { return }
        let revision = tabRevision
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, self.tabSelected, self.tabRevision == revision,
                      self.voice === observedVoice else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    guard self.interruptedSettings == nil else { return }
                    self.interruptedSettings = (self.microphone, self.output)
                    self.ownsAudioSession = false
                    self.lastEngineRecovery = nil
                    self.stopEngine()
                    self.audioInterrupted = true
                    self.microphone = self.interruptedSettings?.mic ?? false
                    self.output = self.interruptedSettings?.play ?? false
                    self.message = String(localized: "Audio interrupted.")
                } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                          let settings = self.interruptedSettings {
                    self.interruptedSettings = nil
                    self.audioInterrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.configure(mic: settings.mic, play: settings.play)
                    } else {
                        self.microphone = false
                        self.output = false
                        self.requestedOutput = false
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
                guard let self, self.tabSelected, self.tabRevision == revision, self.voice === observedVoice,
                      self.interruptedSettings == nil, self.engine != nil else { return }
                self.lastEngineRecovery = nil
                self.configure(mic: self.microphone, play: self.output, preferVoiceProcessing: !self.standardInput)
            }
        })
    }

    private func recoverEngine(_ engine: AVAudioEngine, inputFormat: AVAudioFormat?, voice: Voice) {
        guard !engine.isRunning, let player else { return }
        let now = ContinuousClock.now
        let repeated = lastEngineRecovery.map { $0.duration(to: now) < .seconds(2) } ?? false
        lastEngineRecovery = now

        if !repeated {
            // The mixer's connection follows the output route. Reuse the input
            // tap and converter only while their original format still matches.
            if inputFormat == nil || inputFormat == engine.inputNode.outputFormat(forBus: 0) {
                playbackPump?.stop()
                player.stop()
                playbackMeter = PlaybackQueueMeter()
                gate.configure(held: false, threshold: nil)
                do {
                    try engine.start()
                    startPlayback(player, voice: voice)
                    resetTalkControls()
                    return
                } catch {
                    // Rebuild the graph below if restarting it fails.
                }
            }
            configure(mic: microphone, play: output, preferVoiceProcessing: !standardInput)
        } else if installedTap && !standardInput {
            configure(mic: microphone, play: output, preferVoiceProcessing: false)
        } else {
            let hadMicrophone = microphone
            let failure = String(localized: "The audio configuration keeps changing.")
            if hadMicrophone {
                configure(mic: false, play: output, preferVoiceProcessing: false)
                let inputFailure = String(localized: "Microphone unavailable: \(failure)")
                message = [inputFailure, message].compactMap { $0 }.joined(separator: "\n")
            } else {
                stopEngine()
                message = String(localized: "Playback unavailable: \(failure)")
            }
        }
    }
    #endif

    private func stopEngine() {
        voice?.setDevices(microphone: false, output: false, micMuted: false, outputMuted: false)
        gate.configure(held: false, threshold: nil)
        gate = CaptureGate()
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
        resetTalkControls()
    }

    private func configure(mic: Bool, play: Bool, preferVoiceProcessing: Bool = true) {
        guard tabSelected, let voice else { return }
        stopEngine()
        standardInput = false
        message = nil
        requestedOutput = play
        if mic {
            do { try startAudio(voice, mic: true, play: play, preferVoiceProcessing: preferVoiceProcessing); return }
            catch {
                stopEngine()
                message = String(localized: "Microphone unavailable: \(error.localizedDescription)")
            }
        }
        do { try startAudio(voice, mic: false, play: play, preferVoiceProcessing: false) }
        catch {
            stopEngine()
            let failure = String(localized: "Playback unavailable: \(error.localizedDescription)")
            message = [message, failure].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func startAudio(_ voice: Voice, mic: Bool, play: Bool, preferVoiceProcessing: Bool) throws {
        func attempt(bind: (AVAudioEngine) throws -> Void, verify: (AVAudioEngine) throws -> Void) throws {
            if mic && preferVoiceProcessing {
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
        try MicrophoneCapture.activateSession(microphone: mic, processing: processing, alreadyActive: ownsAudioSession)
        ownsAudioSession = true
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
        #if os(iOS)
        let inputFormat = mic ? engine.inputNode.outputFormat(forBus: 0) : nil
        #endif
        try engine.start()
        try verify(engine)
        self.player = player
        microphone = mic
        output = play
        player.volume = play ? 1 : 0
        startPlayback(player, voice: voice)
        publishDevices()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                #if os(iOS)
                self.recoverEngine(engine, inputFormat: inputFormat, voice: voice)
                #else
                self.configure(mic: self.microphone, play: self.output)
                #endif
            }
        }
    }

    private func startPlayback(_ player: AVAudioPlayerNode, voice: Voice) {
        let pump = VoicePlaybackPump(player: player, format: stereo, meter: playbackMeter) {
            voice.playbackFrame()
        }
        playbackPump = pump
        pump.start()
    }
}

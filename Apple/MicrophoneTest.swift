import AVFoundation
import SwiftUI

/// The tap publishes only one number. Each run gets a separate meter.
final class LocalInputMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    var level: Double? { lock.withLock { value } }

    func measure(_ frame: [Float]) {
        let db = MicrophoneCapture.levelDBFS(frame[...])
        lock.withLock { value = db }
    }
}

@MainActor
protocol MicrophoneTestSource: AnyObject {
    func start(meter: LocalInputMeter, interrupted: @escaping @MainActor () -> Void) throws -> String?
    func stop()
}

@MainActor
final class MicrophoneTest: ObservableObject {
    enum State: Equatable { case idle, requesting, running, failed(String) }
    @Published private(set) var state = State.idle
    private(set) var inputName: String?
    private var meter: LocalInputMeter?
    private var source: MicrophoneTestSource?
    private var request: Task<Void, Never>?
    var level: Double? { meter?.level }

    private let permission: () async -> Bool
    private let makeSource: () -> MicrophoneTestSource

    init(permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         makeSource: @escaping @MainActor () -> MicrophoneTestSource = { LocalMicrophoneInput() }) {
        self.permission = permission
        self.makeSource = makeSource
    }

    func start() {
        guard meter == nil else { return }
        let run = LocalInputMeter()
        meter = run
        state = .requesting
        request = Task { [weak self, permission] in
            guard !Task.isCancelled else { return }
            let allowed = await permission()
            guard let self, !Task.isCancelled, self.meter === run else { return }
            self.request = nil
            self.open(run, allowed: allowed)
        }
    }

    private func open(_ run: LocalInputMeter, allowed: Bool) {
        guard allowed else {
            fail(String(localized: "Allow microphone access in Settings to test your input."))
            return
        }
        let input = makeSource()
        source = input
        do {
            let name = try input.start(meter: run) { [weak self, weak run] in
                guard let self, let run, self.meter === run else { return }
                self.fail(String(localized: "Audio input was interrupted. Start the test again."))
            }
            guard meter === run else { return }
            inputName = name
            state = .running
        } catch {
            fail(String(localized: "Microphone unavailable: \(error.localizedDescription)"))
        }
    }

    func stop() {
        meter = nil
        request?.cancel()
        request = nil
        source?.stop()
        source = nil
        inputName = nil
        state = .idle
    }

    private func fail(_ message: String) {
        stop()
        state = .failed(message)
    }
}

@MainActor
private final class LocalMicrophoneInput: MicrophoneTestSource {
    private var engine: AVAudioEngine?
    private var gate: CaptureGate?
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
    private var sessionActive = false
    #endif

    func start(meter: LocalInputMeter, interrupted: @escaping @MainActor () -> Void) throws -> String? {
        func attempt(bind: (AVAudioEngine) throws -> Void, name: (AVAudioEngine) throws -> String?) throws -> String? {
            // Match the call's voice-processing preference and plain-input fallback.
            for processing in [true, false] {
                do {
                    #if os(iOS)
                    try MicrophoneCapture.activateSession(microphone: true, processing: processing)
                    sessionActive = true
                    #endif
                    let engine = AVAudioEngine()
                    self.engine = engine
                    if processing { try engine.inputNode.setVoiceProcessingEnabled(true) }
                    try bind(engine)
                    let gate = CaptureGate()
                    let notify: @Sendable () -> Void = { [weak self, weak engine] in
                        Task { @MainActor in
                            guard let self, let engine, self.engine === engine else { return }
                            interrupted()
                        }
                    }
                    try MicrophoneCapture.install(on: engine) { buffer, converter in
                        if !gate.consume(buffer, converter: converter, send: meter.measure) { notify() }
                    }
                    self.gate = gate
                    try engine.start()
                    let actual = try name(engine)
                    observe(engine, notify: notify)
                    gate.configure(held: true, threshold: nil)
                    return actual
                } catch {
                    stop()
                    if !processing { throw error }
                }
            }
            return nil
        }
        #if os(macOS)
        var selection = MacDeviceSelection()
        selection.inventory = MacAudioHardware.inventory()
        let input = selection.bindings(microphone: true).filter { $0.key == .input }
        var actual: String?
        try MacDeviceSelection.start(bindings: input) { ids in
            actual = try attempt(bind: { try MacAudioHardware.bind(ids, to: $0) }, name: { engine in
                let id = engine.inputNode.auAudioUnit.deviceID
                try MacDeviceSelection.verify(.input, actual: id, bindings: ids, defaults: selection.inventory?.defaults ?? [:])
                return MacAudioHardware.device(id)?.name
            })
        }
        return actual
        #else
        return try attempt(bind: { _ in }, name: { _ in AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName })
        #endif
    }

    private func observe(_ engine: AVAudioEngine, notify: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in notify() })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue { notify() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in notify() })
        #endif
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let gate {
            gate.configure(held: false, threshold: nil)
            engine?.inputNode.removeTap(onBus: 0)
        }
        gate = nil
        engine?.stop()
        engine = nil
        #if os(iOS)
        if sessionActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        sessionActive = false
        #endif
    }
}

import AVFoundation

@MainActor
private final class FakeInput: MicrophoneTestSource {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var open = false
    var denyStart = false
    var meter: LocalInputMeter?
    var interruption: (@MainActor () -> Void)?

    func start(meter: LocalInputMeter, interrupted: @escaping @MainActor () -> Void) throws -> String? {
        starts += 1
        open = true
        self.meter = meter
        interruption = interrupted
        if denyStart { throw NSError(domain: "MockInput", code: 42) }
        return "Mock USB input"
    }

    func stop() {
        stops += 1
        open = false
        meter = nil
        interruption = nil
    }
}

@main
enum MicrophoneTestCheck {
    @MainActor
    static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Expected state change")
    }

    @MainActor
    static func main() async {
        let source = FakeInput()
        var permits = 0
        let test = MicrophoneTest(permission: { permits += 1; return true }, makeSource: { source })
        precondition(test.state == .idle && test.level == nil && permits == 0 && !source.open)
        test.start()
        test.start()
        await waitFor { test.state == .running }
        precondition(source.starts == 1 && permits == 1 && test.inputName == "Mock USB input")

        let meter = source.meter!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let converter = AVAudioConverter(from: format, to: format)!
        let gate = CaptureGate()
        gate.configure(held: true, threshold: nil)
        func feed(_ left: Float, _ right: Float, count: UInt32 = 960) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            buffer.floatChannelData![0].update(repeating: left, count: Int(count))
            buffer.floatChannelData![1].update(repeating: right, count: Int(count))
            gate.consume(buffer, converter: converter, send: meter.measure)
        }
        feed(0, 0, count: 480)
        precondition(test.level == nil)
        feed(0, 0, count: 480)
        precondition(test.level == -90)
        feed(0.1, -0.1)
        precondition(abs(test.level! + 20) < 0.01)
        feed(1, 0)
        precondition(abs(test.level! + 3.0103) < 0.01)
        feed(1, 1)
        precondition(test.level == 0)

        let late = source.interruption!
        test.stop()
        test.stop()
        precondition(test.state == .idle && test.level == nil && test.inputName == nil && !source.open && source.stops == 1)
        test.start()
        await waitFor { test.state == .running }
        feed(1, 1)
        late()
        precondition(test.state == .running && test.level == nil)
        source.interruption?()
        guard case .failed = test.state else { preconditionFailure("Expected device interruption") }
        precondition(!source.open && source.stops == 2 && test.inputName == nil)

        source.denyStart = true
        test.start()
        await waitFor { if case .failed = test.state { return true }; return false }
        precondition(!source.open && source.stops == 3 && test.level == nil)
        let denied = MicrophoneTest(permission: { false }, makeSource: { preconditionFailure("Opened input after denial") })
        denied.start()
        await waitFor { if case .failed = denied.state { return true }; return false }
        precondition(denied.level == nil)

        var answer: CheckedContinuation<Bool, Never>?
        let waiting = MicrophoneTest(permission: { await withCheckedContinuation { answer = $0 } },
                                     makeSource: { preconditionFailure("Opened input after dismissal") })
        waiting.start()
        await waitFor { answer != nil }
        waiting.stop()
        answer!.resume(returning: true)
        await Task.yield()
        precondition(waiting.state == .idle && waiting.level == nil)

        let neverOpened = MicrophoneTest(permission: { preconditionFailure("Prompted after cancellation") },
                                         makeSource: { preconditionFailure("Opened input after cancellation") })
        neverOpened.start()
        neverOpened.stop()
        await Task.yield()
        precondition(neverOpened.state == .idle)
        print("PASS: local meter levels, device errors, cancellation, cleanup, stale audio and late callbacks")
    }
}

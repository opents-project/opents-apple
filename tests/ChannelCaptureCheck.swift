import AVFoundation

@main
struct ChannelCaptureCheck {
    static func main() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let converter = AVAudioConverter(from: format, to: format)!
        let gate = CaptureGate()
        func feed(_ count: UInt32, left: Float, right: Float, epoch: UInt64) -> [[Float]] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            buffer.floatChannelData![0].update(repeating: left, count: Int(count))
            buffer.floatChannelData![1].update(repeating: right, count: Int(count))
            var output: [[Float]] = []
            gate.consume(buffer, converter: converter, epoch: epoch) { output.append($0) }
            return output
        }

        gate.configure(held: true, threshold: nil)
        precondition(feed(480, left: 1, right: 1, epoch: 1).isEmpty)
        precondition(feed(960, left: 1, right: 1, epoch: 0).isEmpty)
        precondition(feed(480, left: 0.5, right: -0.25, epoch: 3).isEmpty)
        let frames = feed(480, left: 0.5, right: -0.25, epoch: 3)
        precondition(frames.count == 1 && frames[0].count == 1920)
        for i in 0..<960 {
            precondition(frames[0][2 * i] == 0.5 && frames[0][2 * i + 1] == -0.25)
        }

        // A tap may skip the entire pending interval. Its local remainder and
        // the VAD hangover must still expire when the next generation arrives.
        gate.configure(held: false, threshold: -20)
        precondition(feed(960, left: 0, right: 0.5, epoch: 3).count == 1)
        precondition(feed(480, left: 0, right: 0.5, epoch: 3).isEmpty)
        precondition(feed(960, left: 0, right: 0, epoch: 5).isEmpty)
        precondition(!gate.reading.active && gate.reading.level == -90)
        print("Stereo capture, partial frames and voice activation across channel changes passed")
    }
}

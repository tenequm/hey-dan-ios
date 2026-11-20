import AVFAudio
import LiveKit
import os

struct ListeningCuePlayback {
    static let trackName = "background_audio"
    let track: ListeningCueRenderer
    let output: ListeningCueRenderer

    private struct Matches {
        var track: ContinuousClock.Instant?
        var output: ContinuousClock.Instant?
        var fired = false
    }

    init(onPlayback: @escaping @Sendable (CallController.ConnectionMilestone) -> Void) {
        let matches = OSAllocatedUnfairLock(initialState: Matches())
        @Sendable func matched(output: Bool) {
            let now = ContinuousClock.now
            let played = matches.withLock { state in
                guard !state.fired else { return false }
                let other = output ? state.track : state.output
                if output { state.output = now } else { state.track = now }
                // Decoded cue audio and the speaker mix arrive on independent SDK queues.
                guard let other, other.duration(to: now) < .milliseconds(200) else { return false }
                state.fired = true
                return true
            }
            if played { onPlayback(.listeningCue) }
        }
        track = ListeningCueRenderer { matched(output: false) }
        output = ListeningCueRenderer { matched(output: true) }
    }

    func attach(to cue: RemoteAudioTrack) {
        AudioManager.shared.add(remoteAudioRenderer: output)
        cue.add(audioRenderer: track)
    }

    func detach(from cue: RemoteAudioTrack) {
        cue.remove(audioRenderer: track)
        AudioManager.shared.remove(remoteAudioRenderer: output)
    }
}

final class ListeningCueRenderer: AudioRenderer {
    private let signal = OSAllocatedUnfairLock(initialState: Signal())
    private let matched: @Sendable () -> Void

    init(matched: @escaping @Sendable () -> Void) { self.matched = matched }

    func render(pcmBuffer buffer: AVAudioPCMBuffer) {
        if signal.withLockUnchecked({ $0.consume(buffer) }) { matched() }
    }

    // Protocol 6 shares this track with typing and other cues. Listening and discard both open at
    // 784 Hz; the rise to 1175 Hz is the earliest point at which listening is unambiguous.
    private struct Signal {
        var rate = 0.0
        var count = 0
        var energy = 0.0
        var low = Tone(hz: 784, rate: 48_000)
        var high = Tone(hz: 1175, rate: 48_000)
        var lowWindows = 0
        var gap = 0

        mutating func consume(_ buffer: AVAudioPCMBuffer) -> Bool {
            guard buffer.frameLength > 0 else { return false }
            if rate != buffer.format.sampleRate {
                self = Signal()
                rate = buffer.format.sampleRate
                low = Tone(hz: 784, rate: rate)
                high = Tone(hz: 1175, rate: rate)
            }
            let window = max(1, Int(rate / 100))
            let floats = buffer.floatChannelData?[0]
            let ints = buffer.int16ChannelData?[0]
            guard floats != nil || ints != nil else { return false }
            for index in 0 ..< Int(buffer.frameLength) {
                let offset = index * buffer.stride
                let value = floats.map { Double($0[offset]) } ?? Double(ints![offset]) / 32768
                energy += value * value
                low.add(value)
                high.add(value)
                count += 1
                guard count == window else { continue }
                let tonalPower = Double(count) * energy * 0.32
                let audible = energy > Double(count) * 0.00001
                if audible && low.power > tonalPower {
                    lowWindows += 1
                    gap = 0
                } else if audible && high.power > tonalPower && lowWindows >= 4 {
                    self = Signal()
                    return true
                } else {
                    gap += 1
                    if gap > 2 { lowWindows = 0 }
                }
                low.clear()
                high.clear()
                energy = 0
                count = 0
            }
            return false
        }
    }

    // A Goertzel bin measures the energy at one frequency without allocating an FFT per audio buffer.
    private struct Tone {
        let coefficient: Double
        var first = 0.0, second = 0.0

        init(hz: Double, rate: Double) { coefficient = 2 * cos(2 * .pi * hz / rate) }

        mutating func add(_ sample: Double) {
            let next = sample + coefficient * first - second
            second = first
            first = next
        }

        var power: Double { first * first + second * second - coefficient * first * second }

        mutating func clear() { first = 0; second = 0 }
    }
}

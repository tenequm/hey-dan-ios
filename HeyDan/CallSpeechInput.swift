@preconcurrency import AVFAudio
import CoreMedia
import LiveKit
import Speech
import Synchronization

/// The SDK supplies post-processing buffers without timestamps. Keep the mic clock even while a model is loading.
final class CallSpeechInput: AudioRenderer, @unchecked Sendable {
    private struct State {
        var time = CMTime.zero
        var outputTime = CMTime.zero
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        var stream: AsyncStream<AnalyzerInput>.Continuation?
        var muted = false
    }
    private let state = Mutex(State())

    var milliseconds: Int { state.withLock { Int(($0.time.seconds * 1000).rounded()) } }

    func mute(_ muted: Bool) {
        state.withLock {
            $0.muted = muted
            $0.converter = nil
        }
    }

    func feed(format: AVAudioFormat) -> AsyncStream<AnalyzerInput> {
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(50))
        state.withLock {
            $0.stream?.finish()
            $0.stream = continuation
            $0.outputTime = $0.time
            $0.format = format
            $0.converter = nil
        }
        return inputs
    }

    func finish() {
        state.withLock {
            $0.stream?.finish()
            $0.stream = nil
            $0.converter = nil
        }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        state.withLock { state in
            let start = state.time
            state.time = start + CMTime(value: Int64(pcmBuffer.frameLength), timescale: Int32(pcmBuffer.format.sampleRate))
            guard !state.muted, let stream = state.stream, let format = state.format else { return }
            if state.converter?.inputFormat != pcmBuffer.format {
                state.outputTime = max(start, state.outputTime)
                state.converter = AVAudioConverter(from: pcmBuffer.format, to: format)
                state.converter?.primeMethod = .none
            }
            let frames = ceil(Double(pcmBuffer.frameLength) * format.sampleRate / pcmBuffer.format.sampleRate)
            guard let converter = state.converter,
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames) + 1) else { return }
            nonisolated(unsafe) var supplied = false
            let status = converter.convert(to: output, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return pcmBuffer
            }
            if status != .error, output.frameLength > 0 {
                stream.yield(AnalyzerInput(buffer: output, bufferStartTime: state.outputTime))
                state.outputTime = state.outputTime + CMTime(value: Int64(output.frameLength), timescale: Int32(format.sampleRate))
            }
        }
    }
}

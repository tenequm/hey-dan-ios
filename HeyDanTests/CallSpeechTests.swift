import AVFAudio
import Speech
import XCTest
@testable import HeyDan

@MainActor final class CallSpeechTests: XCTestCase {
    func testBackchannelsAndConfidence() {
        for ack in ["Uh-huh.", "OK!", "угу", "АГА", "так", "ну", "да", "ugu", "aga", "tak", "nu", "da", "uh huh"] {
            XCTAssertFalse(CallerWord(text: ack, startMs: 0, confidence: 1).interrupts, ack)
        }
        for confidence: Double? in [nil, 0.1, 0.59] {
            XCTAssertFalse(CallerWord(text: "wait", startMs: 0, confidence: confidence).interrupts)
        }
        XCTAssertTrue(CallerWord(text: "Так, зачекай!", startMs: 0, confidence: 0.9).interrupts)
    }

    func testConvertedInputKeepsMicTimeAcrossPreheatAndMute() async throws {
        let input = CallSpeechInput()
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 480))
        pcm.frameLength = 480
        pcm.floatChannelData?[0].update(repeating: 0, count: 480)
        input.render(pcmBuffer: pcm)
        let stream = input.feed(format: target)
        input.render(pcmBuffer: pcm)
        input.mute(true)
        input.render(pcmBuffer: pcm)
        input.mute(false)
        input.render(pcmBuffer: pcm)
        input.finish()

        var times: [Double] = []
        for await packet in stream {
            XCTAssertEqual(packet.bufferFormat, target)
            XCTAssertEqual(packet.bufferDuration.seconds, 0.01, accuracy: 0.0001)
            times.append(try XCTUnwrap(packet.bufferStartTime).seconds)
        }
        XCTAssertEqual(times, [0.01, 0.03])
        XCTAssertEqual(input.milliseconds, 40)
    }

    func testRevisionsReplaceAndFinalResultsStayFinal() {
        var caption = CallerCaption()
        caption.update("Hel", at: 12, final: false)
        caption.update("Hello", at: 12, final: false)
        XCTAssertEqual(caption.text, "Hello")
        XCTAssertFalse(caption.isFinal)
        caption.update(" Hello! ", at: 12, final: true)
        caption.update("stale", at: 12, final: false)
        XCTAssertEqual(caption.text, "Hello!")
        XCTAssertTrue(caption.isFinal)
        caption.update("Next", at: 200, final: false)
        caption.update("older final", at: 12, final: true)
        XCTAssertEqual(caption.text, "Next")
        XCTAssertFalse(caption.isFinal)
    }

    func testRequiresSupportSpeakingActiveAudioAndNewWords() {
        let gate = SpeechBargeIn()
        for (enabled, speaking, active, start) in [
            (false, true, true, 110), (true, false, true, 110),
            (true, true, false, 110), (true, true, true, 90)
        ] {
            gate.update(enabled: enabled, speaking: speaking, micMs: 100)
            gate.hear([CallerWord(text: "wait", startMs: start, confidence: 1)], remoteActive: active,
                      mute: { XCTFail("Unexpected mute"); return {} }, interrupt: { _ in XCTFail(); return false })
        }
    }

    func testSuccessfulCutIsImmediateOncePerUtteranceAndRestoresPreviousVolume() async {
        let gate = SpeechBargeIn()
        gate.update(enabled: true, speaking: true, micMs: 100)
        var volume = 0.7
        let sent = expectation(description: "Sent first-word mic timestamp")
        let words = [CallerWord(text: "ok", startMs: 150, confidence: 1),
                     CallerWord(text: "wait", startMs: 230, confidence: 1)]
        gate.hear(Array(words.prefix(1)), remoteActive: true,
                  mute: { XCTFail(); return {} }, interrupt: { _ in XCTFail(); return false })
        gate.hear(words, remoteActive: true, mute: {
            volume = 0
            return { volume = 0.7 }
        }, interrupt: { cut in
            XCTAssertEqual(cut, 150)
            sent.fulfill()
            return true
        })
        XCTAssertEqual(volume, 0)
        await fulfillment(of: [sent], timeout: 2)
        gate.hear(words, remoteActive: true, mute: { XCTFail(); return {} }, interrupt: { _ in XCTFail(); return false })
        gate.update(enabled: true, speaking: false, micMs: 300)
        XCTAssertEqual(volume, 0)
        gate.update(enabled: true, speaking: true, micMs: 500)
        XCTAssertEqual(volume, 0.7)
    }

    func testFailedAndUnansweredRPCRestoreVolumeOnDeadline() async {
        for hangs in [false, true] {
            let gate = SpeechBargeIn(timeout: .milliseconds(20))
            gate.update(enabled: true, speaking: true, micMs: 0)
            let restored = expectation(description: "Restored volume")
            var muted = false
            gate.hear([CallerWord(text: "stop", startMs: 123, confidence: 1)], remoteActive: true, mute: {
                muted = true
                return { muted = false; restored.fulfill() }
            }, interrupt: { _ in
                if hangs { try? await Task.sleep(for: .seconds(10)) }
                return false
            })
            XCTAssertTrue(muted)
            await fulfillment(of: [restored], timeout: 2)
            XCTAssertFalse(muted)
            gate.reset()
        }
    }
}

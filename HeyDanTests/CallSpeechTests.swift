import AVFAudio
import Speech
import XCTest
@testable import HeyDan

@MainActor final class CallSpeechTests: XCTestCase {
    func testOnlyPairedHostsAdvertisingCallsAreEligibleForSpeech() throws {
        let account = "test-call-speech-" + UUID().uuidString
        defer { try? IdentityKeychain.remove(account: account) }
        let pairings = Pairings(account: account, publishes: false)
        pairings.loadIfNeeded()
        XCTAssertTrue(pairings.callEntries.isEmpty)
        let host = FixtureAppService.host
        try pairings.add(FixtureAppService.pairing, host: host, features: ["voice-picker"])
        XCTAssertTrue(pairings.callEntries.isEmpty)
        pairings.refreshFeatures(["calls"], host: host)
        XCTAssertEqual(pairings.callEntries.map(\.host), [host])
        pairings.refreshFeatures([], host: host)
        XCTAssertTrue(pairings.callEntries.isEmpty)
    }

    func testUnsupportedCallLanguageDoesNotTryPhoneLanguage() async {
        var candidates: [Locale] = []
        let resolved = await CallSpeech.supportedLocale(language: "uk") { candidate in
            candidates.append(candidate)
            return nil
        }
        XCTAssertNil(resolved)
        XCTAssertEqual(candidates, [Locale(identifier: "uk")])

        let phone = await CallSpeech.supportedLocale(language: nil) { $0 }
        XCTAssertEqual(phone, Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current)
    }

    func testOnlyNumericRepresentableSpeechTimesBecomeMilliseconds() {
        XCTAssertNil(CallSpeech.milliseconds(at: .invalid))
        XCTAssertNil(CallSpeech.milliseconds(at: .indefinite))
        XCTAssertNil(CallSpeech.milliseconds(at: .positiveInfinity))
        XCTAssertNil(CallSpeech.milliseconds(at: CMTime(value: .max, timescale: 1)))
        XCTAssertEqual(CallSpeech.milliseconds(at: CMTime(value: 3, timescale: 2)), 1500)
    }

    func testBackchannelsAndConfidence() {
        for ack in ["Uh-huh.", "OK!", "угу", "АГА", "так", "ну", "да", "ugu", "aga", "tak", "nu", "da", "uh huh"] {
            XCTAssertFalse(CallerWord(text: ack, startMs: 0, confidence: 1).interrupts, ack)
        }
        for confidence: Double? in [nil, 0.1, 0.59] {
            XCTAssertFalse(CallerWord(text: "wait", startMs: 0, confidence: confidence).interrupts)
        }
        XCTAssertTrue(CallerWord(text: "Так, зачекай!", startMs: 0, confidence: 0.9).interrupts)
    }

    func testCaptureRequiresActiveAudioWithHoldAndMuteReleasedIndependently() {
        let speech = CallSpeech()
        func expectCaption(_ allowed: Bool, line: UInt = #line) {
            speech.showCaption("Listening", at: 0, final: false)
            XCTAssertEqual(speech.caption.text.isEmpty, !allowed, line: line)
        }

        expectCaption(false)
        speech.updateInput(audioActive: true, held: false, muted: false)
        expectCaption(true)
        speech.updateInput(audioActive: true, held: true, muted: false)
        expectCaption(false)
        speech.updateInput(audioActive: true, held: false, muted: true)
        expectCaption(false)
        speech.updateInput(audioActive: false, held: false, muted: false)
        expectCaption(false)
        speech.updateInput(audioActive: true, held: false, muted: false)
        expectCaption(true)
        speech.end()
        expectCaption(false)
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

    func testSuccessfulCutIsImmediateOncePerUtteranceAndRestoresPreviousVolume() async throws {
        let gate = SpeechBargeIn()
        let input = CallSpeechInput()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        pcm.frameLength = 48_000
        input.render(pcmBuffer: pcm)
        gate.update(enabled: true, speaking: true, micMs: input.milliseconds)
        var volume = 0.7
        let sent = expectation(description: "Sent interrupt")
        let words = [CallerWord(text: "previous", startMs: 950, confidence: 1),
                     CallerWord(text: " ok", startMs: 1000, confidence: 1),
                     CallerWord(text: " wait!", startMs: 1030, confidence: 1)]
        pcm.frameLength = 4800
        input.render(pcmBuffer: pcm)
        gate.hear(Array(words.prefix(2)), remoteActive: true,
                  mute: { XCTFail(); return {} }, interrupt: { _ in XCTFail(); return false })
        gate.hear(words, remoteActive: true, mute: {
            volume = 0
            return { volume = 0.7 }
        }, interrupt: { cut in
            let payload = try? cut.payload(micMs: input.milliseconds)
            let fields = payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertEqual(fields?.count, 4)
            XCTAssertEqual(fields?["heard"] as? String, "ok wait!")
            XCTAssertEqual(fields?["cutAtMs"] as? Int, 1000)
            XCTAssertEqual(fields?["micMs"] as? Int, 1200)
            XCTAssertTrue(fields?["playedMs"] is NSNull)
            sent.fulfill()
            return true
        })
        input.render(pcmBuffer: pcm)
        XCTAssertEqual(volume, 0)
        await fulfillment(of: [sent], timeout: 2)
        gate.hear(words, remoteActive: true, mute: { XCTFail(); return {} }, interrupt: { _ in XCTFail(); return false })
        gate.update(enabled: true, speaking: false, micMs: 1300)
        XCTAssertEqual(volume, 0)
        gate.update(enabled: true, speaking: true, micMs: 1500)
        XCTAssertEqual(volume, 0.7)
    }

    func testCutMutesAndRestoresOnlyTheOriginalSpeechTrack() throws {
        final class Track: CallSpeechPlayout {
            let name: String
            var volume: Double
            init(_ name: String, volume: Double) {
                self.name = name
                self.volume = volume
            }
        }
        let cue = Track("background_audio", volume: 0.4)
        let speech = Track("roomio_audio", volume: 0.8)
        XCTAssertNil(CallSpeech.muteSpeechTrack(in: [cue]))
        let restore = try XCTUnwrap(CallSpeech.muteSpeechTrack(in: [cue, speech]))
        XCTAssertEqual(speech.volume, 0)
        XCTAssertEqual(cue.volume, 0.4)
        restore()
        XCTAssertEqual(speech.volume, 0.8)
        XCTAssertEqual(cue.volume, 0.4)
    }

    func testRefusedCutRestoresBeforeReplyDeadline() async {
        let restored = expectation(description: "Refusal restored speech")
        let gate = SpeechBargeIn(replyTimeout: .seconds(30))
        gate.update(enabled: true, speaking: true, micMs: 0)
        gate.hear([CallerWord(text: "stop", startMs: 1, confidence: 1)], remoteActive: true,
                  mute: { { restored.fulfill() } }, interrupt: { _ in false })
        await fulfillment(of: [restored], timeout: 2)
    }

    func testMissingLateAndAcceptedRepliesHaveBoundedMute() async {
        for reply: Bool? in [nil, false, true] {
            var events: [String] = []
            let timeout = Duration.milliseconds(100)
            let gate = SpeechBargeIn(replyTimeout: timeout) { events.append($0) }
            gate.update(enabled: true, speaking: true, micMs: 0)
            let restored = expectation(description: "Restored without a new speaking edge")
            let mutedAt = ContinuousClock.now
            gate.hear([CallerWord(text: "stop", startMs: 1, confidence: 1)], remoteActive: true,
                      mute: { { restored.fulfill() } }, interrupt: { _ in
                if reply == false { try? await Task.sleep(for: .seconds(30)) }
                return reply
            })
            await fulfillment(of: [restored], timeout: 3)
            XCTAssertGreaterThanOrEqual(ContinuousClock.now - mutedAt, reply == true ? timeout * 3 : timeout)
            XCTAssertEqual(events.count, 2)
            XCTAssertTrue(events.first?.hasPrefix(reply == true ? "interrupt reply=accepted" : "interrupt reply=timed_out") == true)
            XCTAssertEqual(events.last, reply == true ? "interrupt restored reason=accepted cap" : "interrupt restored reason=deadline")
        }
    }
}

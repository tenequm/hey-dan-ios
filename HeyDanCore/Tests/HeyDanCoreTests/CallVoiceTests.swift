import Foundation
import HeyDanCore
import Testing

struct CallVoiceTests {
    @Test func decodesVoiceAttribute() throws {
        let json = #"{"v":1,"active":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"alnilam"},"pending":{"provider":"elevenlabs","model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"},"gen":7}"#
        let expected = CallVoiceState(
            active: TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "alnilam"),
            pending: TTSChoice(provider: "elevenlabs", model: "eleven_turbo_v2_5", voice: "bIHbv24MWmeRgasZH58o"),
            gen: 7
        )
        #expect(try JSONDecoder().decode(CallVoiceState.self, from: Data(json.utf8)) == expected)
        #expect(CallVoiceState(attribute: json) == expected)
        #expect(expected.v == 1)
    }

    @Test func protocol4HasNoVoiceAttribute() {
        #expect(VoiceProtocol.Names(version: 4)?.voiceAttribute == nil)
    }

    @Test func protocol6NamesVoiceAttribute() {
        #expect(VoiceProtocol.Names(version: 6)?.voiceAttribute == "nanoclaw.voice-mode.voice")
    }

    private let initial = TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "alnilam")
    private let choice = TTSChoice(provider: "elevenlabs", model: "eleven_turbo_v2_5", voice: "bIHbv24MWmeRgasZH58o")
    private let id = UUID()
    private let pendingAttribute = #"{"v":1,"active":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"alnilam"},"pending":{"provider":"elevenlabs","model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"},"gen":7}"#
    private let activeAttribute = #"{"v":1,"active":{"provider":"elevenlabs","model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"},"gen":7}"#

    private func live() -> LiveVoice { LiveVoice(callID: id, state: CallVoiceState(active: initial)) }
    private func reply(gen: Int = 7, ok: Bool = true, error: String? = nil) -> ReviewReply {
        let errorField = error.map { ",\"error\":\"\($0)\"" } ?? ""
        return ReviewReply(payload: "{\"gen\":\(gen),\"ok\":\(ok),\"seq\":12\(errorField)}")!
    }

    @Test func encodesOnlyVoiceFieldsExactly() throws {
        let request = VoiceRequest(gen: 7, tts: TTSChoice(provider: "elevenlabs", voice: "bIHbv24MWmeRgasZH58o"))
        #expect(request.payload == #"{"gen":7,"tts":{"provider":"elevenlabs","voice":"bIHbv24MWmeRgasZH58o"}}"#)
        let fixture = #"{"gen":7,"wake":true,"pauseSends":false,"cues":true,"typing":true,"tts":{"provider":"elevenlabs","voice":"bIHbv24MWmeRgasZH58o"}}"#
        let fields = try #require(JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any])
        let expected = try #require(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        #expect(fields.count == 2)
        #expect((fields["tts"] as? NSDictionary) == (expected["tts"] as? NSDictionary))
    }

    @Test func draftDoesNotChangeConfiguredVoice() {
        var voice = live()
        voice.edit(choice)
        #expect(voice.phase == .draft)
        #expect(voice.draft == choice)
        #expect(voice.state?.active == initial)
        #expect(voice.state?.pending == nil)
    }

    @Test func requestKeepsCurrentSpokenLineUnchanged() {
        var voice = live()
        let began = voice.begin(choice, gen: 7, for: id)
        #expect(began)
        #expect(voice.phase == .requesting(gen: 7))
        #expect(voice.inFlight)
        let applied = voice.apply(reply: reply(), for: id)
        #expect(applied)
        #expect(voice.phase == .queued)
        #expect(voice.state?.active == initial)
        #expect(voice.state?.pending == nil)
        #expect(voice.outcome == .queued(gen: 7))
    }

    @Test func attributeThenReplyRetainsActiveState() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(attribute: activeAttribute, for: id)
        #expect(voice.phase == .active)
        #expect(voice.inFlight)
        voice.apply(reply: reply(), for: id)
        #expect(voice.phase == .active)
        #expect(!voice.inFlight)
    }

    @Test func replyThenAttributeQueuesAndActivatesWithSameGeneration() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(reply: reply(), for: id)
        voice.apply(attribute: pendingAttribute, for: id)
        #expect(voice.phase == .queued)
        #expect(voice.state?.active == initial)
        #expect(voice.state?.pending == choice)
        voice.apply(attribute: activeAttribute, for: id)
        #expect(voice.phase == .active)
        #expect(voice.state?.pending == nil)
        #expect(voice.state?.gen == 7)
    }

    @Test func oneRequestStaysInFlightUntilItsReply() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(attribute: pendingAttribute, for: id)
        let refused = !voice.begin(initial, gen: 8, for: id)
        #expect(refused)
        voice.edit(initial)
        #expect(voice.draft == choice)
        voice.apply(reply: reply(), for: id)
        let beganNext = voice.begin(initial, gen: 8, for: id)
        #expect(beganNext)
    }

    @Test func idempotentPendingRetryKeepsEarlierAttributeGeneration() {
        var voice = live()
        voice.apply(attribute: pendingAttribute, for: id)
        voice.begin(choice, gen: 8, for: id)
        voice.apply(reply: reply(gen: 8), for: id)
        #expect(voice.phase == .queued)
        #expect(voice.state?.gen == 7)
        voice.apply(attribute: activeAttribute, for: id)
        #expect(voice.phase == .active)
        #expect(voice.outcome == .queued(gen: 8))
    }

    @Test func idempotentActiveRetryConfirmsAfterTimeout() {
        var voice = live()
        voice.apply(attribute: activeAttribute, for: id)
        voice.begin(choice, gen: 8, for: id)
        voice.timeout(gen: 8, for: id)
        #expect(voice.phase == .active)
        #expect(voice.outcome == .queued(gen: 8))
    }

    @Test func omittedDefaultsNeedMatchingGeneration() {
        var voice = live()
        voice.apply(attribute: activeAttribute, for: id)
        let defaultChoice = TTSChoice(provider: "elevenlabs", voice: choice.voice)
        voice.begin(defaultChoice, gen: 8, for: id)
        voice.timeout(gen: 8, for: id)
        #expect(voice.phase == .unconfirmed)
        voice.apply(attribute: activeAttribute.replacingOccurrences(of: "7}", with: "8}"), for: id)
        #expect(voice.phase == .active)
    }

    @Test func timeoutDoesNotChangeConfiguredStateAndLaterReconciles() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.timeout(gen: 7, for: id)
        #expect(voice.phase == .unconfirmed)
        #expect(voice.outcome == .unconfirmed)
        #expect(voice.state?.active == initial)
        voice.apply(attribute: pendingAttribute, for: id)
        #expect(voice.phase == .queued)
        voice.apply(attribute: activeAttribute, for: id)
        #expect(voice.phase == .active)
    }

    @Test func invalidReplyFixtureRetainsDraftAndActiveVoice() throws {
        let fixture = #"{"gen":7,"ok":false,"seq":12,"error":"tts_invalid"}"#
        let refused = try #require(ReviewReply(payload: fixture))
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(reply: refused, for: id)
        #expect(voice.phase == .refused(reason: "tts_invalid"))
        #expect(voice.outcome == .refused(reason: "tts_invalid"))
        #expect(voice.draft == choice)
        #expect(voice.state?.active == initial)
        voice.apply(attribute: pendingAttribute, for: id)
        #expect(voice.phase == .refused(reason: "tts_invalid"))
        let retried = voice.begin(initial, gen: 8, for: id)
        #expect(retried)
    }

    @Test func unavailableReplyRetainsActiveVoice() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(reply: reply(ok: false, error: "tts_unavailable"), for: id)
        #expect(voice.outcome == .refused(reason: "tts_unavailable"))
        #expect(voice.state?.active == initial)
    }

    @Test func wrongGenerationCannotSettleRequest() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        let before = voice
        let ignoredReply = !voice.apply(reply: reply(gen: 6), for: id)
        #expect(ignoredReply)
        let ignoredTimeout = !voice.timeout(gen: 6, for: id)
        #expect(ignoredTimeout)
        #expect(voice == before)
    }

    @Test func staleCallCannotChangeAnyLiveState() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        let other = UUID()
        let before = voice
        let ignoredRequest = !voice.begin(initial, gen: 8, for: other)
        #expect(ignoredRequest)
        let ignoredReply = !voice.apply(reply: reply(), for: other)
        #expect(ignoredReply)
        let ignoredAttribute = !voice.apply(attribute: activeAttribute, for: other)
        #expect(ignoredAttribute)
        let ignoredTimeout = !voice.timeout(gen: 7, for: other)
        #expect(ignoredTimeout)
        #expect(voice == before)
    }

    @Test func olderAttributeDoesNotUndoLatestState() {
        var voice = live()
        voice.apply(attribute: activeAttribute.replacingOccurrences(of: "7}", with: "8}"), for: id)
        let before = voice
        let ignoredAttribute = !voice.apply(attribute: pendingAttribute, for: id)
        #expect(ignoredAttribute)
        #expect(voice == before)
    }

    @Test func pendingReplacementIsAuthoritative() {
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(attribute: pendingAttribute, for: id)
        voice.apply(reply: reply(), for: id)
        voice.begin(initial, gen: 8, for: id)
        voice.apply(reply: reply(gen: 8), for: id)
        voice.apply(attribute: #"{"v":1,"active":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"alnilam"},"gen":8}"#, for: id)
        #expect(voice.phase == .active)
        #expect(voice.state?.active == initial)
        #expect(voice.state?.pending == nil)
    }

    @Test func missingMalformedAndUnknownVersionDisableLiveRequests() {
        for attribute in [nil, "invalid", #"{"v":2,"active":{"provider":"gemini"}}"#, #"{"active":{"provider":"gemini"}}"#] as [String?] {
            var voice = live()
            voice.apply(attribute: attribute, for: id)
            #expect(voice.state == nil)
            let unsupported = !voice.begin(choice, gen: 7, for: id)
            #expect(unsupported)
            #expect(CallVoiceState(attribute: attribute ?? "") == nil)
        }
    }

    @Test func unknownProviderIDsRemainVerbatim() {
        let attribute = #"{"v":1,"active":{"provider":"future","model":"future-model","voice":"VoiceID"}}"#
        #expect(CallVoiceState(attribute: attribute)?.active == TTSChoice(provider: "future", model: "future-model", voice: "VoiceID"))
    }

    @Test func voiceRepublishKeepsModeWakeAndPicks() throws {
        var session = ReviewSession(pick: .auto)
        session.startCall()
        var transcript = Transcript()
        let json = #"{"seq":11,"mode":"auto","draft":null,"wake":{"on":true,"waiting":false,"pauseSends":false}}"#
        let state = try JSONDecoder().decode(ReviewState.self, from: Data(json.utf8))
        let first = session.receive(state, transcript: &transcript, micOn: true)
        #expect(first == false)
        let before = session.review
        let picks = SettingsPicks.defaults
        var commands = CommandSettings(picks: picks)
        if let wake = state.wake { commands.apply(wake) }
        let beforeCommands = commands
        var voice = live()
        voice.begin(choice, gen: 7, for: id)
        voice.apply(reply: reply(), for: id)
        let republished = try JSONDecoder().decode(ReviewState.self, from: Data(json.replacingOccurrences(of: "11", with: "12").utf8))
        let closesMic = session.receive(republished, transcript: &transcript, micOn: true)
        if let wake = republished.wake { commands.apply(wake) }
        #expect(closesMic == false)
        #expect(session.seq == 12)
        #expect(session.review == before)
        #expect(session.pick == .auto)
        #expect(commands == beforeCommands)
    }

    @Test func defaultRetryKeepsEarlierResolvedChoiceAndGeneration() {
        var voice = live()
        let defaultChoice = TTSChoice(provider: "elevenlabs", voice: choice.voice)
        voice.begin(defaultChoice, gen: 7, for: id)
        voice.apply(attribute: pendingAttribute, for: id)
        voice.timeout(gen: 7, for: id)
        voice.begin(defaultChoice, gen: 8, for: id)
        voice.timeout(gen: 8, for: id)
        #expect(voice.phase == .queued)
        #expect(voice.outcome == .queued(gen: 8))
        voice.apply(attribute: activeAttribute, for: id)
        #expect(voice.phase == .active)
    }


    @Test func firstAttributesEstablishConfiguredStateWithoutARequest() {
        var voice = LiveVoice(callID: id)
        #expect(voice.phase == .draft)
        voice.apply(attribute: pendingAttribute, for: id)
        #expect(voice.phase == .queued)
        voice.apply(attribute: activeAttribute, for: id)
        #expect(voice.phase == .active)
        #expect(voice.state?.active == choice)
    }

}

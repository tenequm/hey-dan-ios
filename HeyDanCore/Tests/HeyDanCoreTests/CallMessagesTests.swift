import Foundation
import HeyDanCore
import Testing

/// Payloads as nanoclaw's worker publishes them (`voice-livekit-protocol.ts` types, `voice-livekit-worker.test.ts`).
struct TurnMessageTests {
    private func message(_ json: String) -> TurnMessage? {
        TurnMessage(json: Data(json.utf8))
    }

    @Test func decodesTurnStatuses() {
        #expect(message(#"{"turn":2,"status":"sent","text":"Book a table"}"#) == .status(TurnStatus(turn: 2, status: .sent, text: "Book a table")))
        #expect(message(#"{"turn":2,"status":"lost","reason":"stt"}"#) == .status(TurnStatus(turn: 2, status: .lost, reason: .stt)))
        #expect(message(#"{"turn":4,"status":"lost","reason":"rate_limited"}"#) == .status(TurnStatus(turn: 4, status: .lost, reason: .rateLimited)))
        #expect(message(#"{"turn":1,"status":"sending"}"#) == .status(TurnStatus(turn: 1, status: .sending)))
        #expect(message(#"{"turn":3,"status":"sending","text":"Hi","draft":1}"#) == .status(TurnStatus(turn: 3, status: .sending, text: "Hi", draft: 1)))
        #expect(message(#"{"turn":1,"status":"working"}"#) == .status(TurnStatus(turn: 1, status: .working)))
    }

    @Test func aReasonFromANewerWorkerStillLosesTheTurn() {
        #expect(message(#"{"turn":2,"status":"lost","reason":"melted"}"#) == .status(TurnStatus(turn: 2, status: .lost)))
    }

    @Test(arguments: [TurnMessage.dropped(DroppedSpeech(.discarded, text: "never mind")), .dropped(DroppedSpeech(.unaddressed, text: "what time is it")), .dropped(DroppedSpeech(.command, text: "Zulu.")), .dropped(DroppedSpeech(.asleep, text: "and also"))])
    func decodesDroppedSpeech(_ expected: TurnMessage) throws {
        guard case let .dropped(dropped) = expected else { return }
        #expect(message(#"{"dropped":"\#(dropped.dropped.rawValue)","text":"\#(dropped.text)"}"#) == expected)
    }

    @Test func decodesACommandDropsCommandAndSegment() {
        #expect(message(#"{"dropped":"command","text":"Zulu.","command":"send","segment":"SG_turn_7"}"#)
            == .dropped(DroppedSpeech(.command, text: "Zulu.", command: .send, segment: "SG_turn_7")))
        #expect(message(#"{"dropped":"command","text":"Scratch that.","command":"discard","segment":"SG_turn_2"}"#)
            == .dropped(DroppedSpeech(.command, text: "Scratch that.", command: .discard, segment: "SG_turn_2")))
        // A command this app does not know still drops the words, as an older worker's drop does.
        #expect(message(#"{"dropped":"command","text":"Over.","command":"rewind","segment":""}"#) == .dropped(DroppedSpeech(.command, text: "Over.")))
    }

    @Test func decodesUnheardSpeech() {
        #expect(message(#"{"unheard":"agent_speaking"}"#) == .unheard)
    }

    @Test(arguments: [
        #"{"turn":1,"status":"queued"}"#,
        #"{"dropped":"forgotten","text":"x"}"#,
        #"{"unheard":"caller_speaking"}"#,
        #"{"status":"sent"}"#,
        #"{"reply":1}"#,
        "not json",
    ])
    func ignoresWhatItDoesNotKnow(_ json: String) {
        #expect(message(json) == nil)
    }
}

struct ReplyInfoTests {
    private func info(_ json: String) throws -> ReplyInfo {
        try JSONDecoder().decode(ReplyInfo.self, from: Data(json.utf8))
    }

    @Test func decodesEveryShape() throws {
        #expect(try info(#"{"reply":1,"turn":2,"part":1}"#) == ReplyInfo(reply: 1, turn: 2, part: 1))
        #expect(try info(#"{"reply":1,"turn":1,"part":1,"more":true}"#) == ReplyInfo(reply: 1, turn: 1, part: 1, more: true))
        #expect(try info(#"{"reply":3,"unprompted":true}"#) == ReplyInfo(reply: 3, unprompted: true))
        #expect(try info(#"{"reply":4,"notice":true}"#) == ReplyInfo(reply: 4, notice: true))
        #expect(try info(#"{"reply":1,"turn":2,"part":1,"unspoken":true,"text":"Booked for eight."}"#)
            == ReplyInfo(reply: 1, turn: 2, part: 1, unspoken: true, text: "Booked for eight."))
    }
}

struct ReviewStateTests {
    private func state(_ json: String) throws -> ReviewState {
        try JSONDecoder().decode(ReviewState.self, from: Data(json.utf8))
    }

    @Test func decodesTheWakeState() throws {
        #expect(try state(#"{"seq":3,"mode":"auto","draft":null,"wake":{"on":true,"pauseSends":false,"waiting":true}}"#)
            == ReviewState(seq: 3, mode: .auto, wake: WakeState(on: true, pauseSends: false, waiting: true)))
        let full = try state(
            #"{"seq":9,"mode":"auto","draft":null,"wake":{"on":true,"pauseSends":true,"waiting":false,"phrase":"Hey LiveKit","heard":2,"slept":1,"cut":true}}"#
        )
        #expect(full.wake == WakeState(on: true, pauseSends: true, waiting: false, phrase: "Hey LiveKit", heard: 2, slept: 1, cut: true))
    }

    @Test func decodesTheDraftAndAnOlderWorkersMissingWake() throws {
        let review = try state(#"{"seq":5,"mode":"review","draft":{"id":2,"state":"ready","text":"Hi","tooLong":true},"preparing":true}"#)
        #expect(review == ReviewState(seq: 5, mode: .review, draft: Draft(id: 2, state: .ready, text: "Hi", tooLong: true), preparing: true))
    }
}

struct SettingsTests {
    @Test func requestCarriesTheGenAndEverySwitch() throws {
        let request = SettingsRequest(gen: 4, picks: SettingsPicks(wake: false, pauseSends: true, typing: false))
        #expect(request.payload == #"{"cues":true,"gen":4,"pauseSends":true,"typing":false,"wake":false}"#)
    }

    @Test func decodesReplies() {
        #expect(ReviewReply(payload: #"{"gen":4,"ok":true,"seq":7}"#).map { [$0.gen, $0.seq] } == [4, 7])
        let refused = ReviewReply(payload: #"{"gen":5,"ok":false,"seq":7,"error":"closed"}"#)
        #expect(refused?.ok == false)
        #expect(refused?.error == "closed")
        #expect(ReviewReply(payload: #"{"ok":true}"#) == nil)
        #expect(ReviewReply(payload: "") == nil)
    }

    @Test func onlyTheCallsFirstSettingsSendIsCutShort() {
        #expect(VoiceProtocol.settingsAckTimeout(send: 1) == VoiceProtocol.firstSettingsAckTimeout)
        #expect(VoiceProtocol.firstSettingsAckTimeout < VoiceProtocol.rpcAckTimeout)
        for send in 2 ... VoiceProtocol.settingsAttempts + 2 {
            #expect(VoiceProtocol.settingsAckTimeout(send: send) == VoiceProtocol.rpcAckTimeout)
        }
    }

    @Test func commandSettingsFollowTheWorker() {
        var settings = CommandSettings(picks: .defaults)
        #expect(settings == CommandSettings(picks: SettingsPicks(wake: true, pauseSends: false, typing: true)))
        settings.apply(WakeState(on: true, pauseSends: true, waiting: true, phrase: "Hey LiveKit"))
        #expect(settings.wake && settings.pauseSends && settings.waiting)
        #expect(settings.phrase == "Hey LiveKit")
        // Waiting means nothing with the switch off.
        settings.apply(WakeState(on: false, pauseSends: false, waiting: true))
        #expect(!settings.waiting && settings.phrase == nil)
    }

    @Test func aRefusedRequestFallsBackToWhatTheWorkerRuns() {
        var settings = CommandSettings(picks: SettingsPicks(wake: false, pauseSends: true, typing: false))
        settings.revert(running: nil, taken: SettingsPicks(wake: true, pauseSends: false, typing: true))
        #expect(settings.wake && !settings.pauseSends && settings.typing)
        settings.wake = false
        settings.revert(running: WakeState(on: false, pauseSends: true, waiting: false), taken: .defaults)
        #expect(!settings.wake && settings.pauseSends)
    }
}

struct StreamOrderTests {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private let start = ContinuousClock.now

    private func sent(_ ms: Int) -> Date {
        t0.addingTimeInterval(Double(ms) / 1000)
    }

    @Test func holdsEachEventThenReleasesInSendingOrder() {
        var order = StreamOrder<String>(hold: .milliseconds(100))
        order.add("second", sentAt: sent(2), at: start)
        order.add("first", sentAt: sent(1), at: start + .milliseconds(3))
        #expect(order.nextDue == start + .milliseconds(103))
        #expect(order.release(at: start + .milliseconds(102)).isEmpty)
        #expect(order.release(at: start + .milliseconds(103)) == ["first", "second"])
        #expect(order.nextDue == nil)
    }

    @Test func anEventStillHeldBlocksTheOnesSentAfterIt() {
        var order = StreamOrder<String>(hold: .milliseconds(100))
        order.add("a", sentAt: sent(1), at: start)
        order.add("c", sentAt: sent(3), at: start)
        order.add("b", sentAt: sent(2), at: start + .milliseconds(50))
        #expect(order.release(at: start + .milliseconds(100)) == ["a"])
        #expect(order.release(at: start + .milliseconds(150)) == ["b", "c"])
    }

    @Test func theSameMillisecondKeepsArrivalOrder() {
        var order = StreamOrder<String>(hold: .milliseconds(100))
        order.add("x", sentAt: sent(5), at: start)
        order.add("y", sentAt: sent(5), at: start)
        order.add("w", sentAt: sent(4), at: start)
        #expect(order.release(at: start + .seconds(1)) == ["w", "x", "y"])
    }

    @Test func drainGivesEverythingHeldInSendingOrder() {
        var order = StreamOrder<String>()
        order.add("later", sentAt: sent(9), at: start)
        order.add("sooner", sentAt: sent(8), at: start)
        #expect(order.drain() == ["sooner", "later"])
        #expect(order.nextDue == nil)
    }
}

/// The worker's command announcement and caption marks (the command-announce contract, v1).
struct CommandWordsTests {
    private static let announcement = #"{"v":1,"send":[{"say":"zulu","hint":true},{"say":"copy","ownSentence":true,"hint":true},{"say":"copy that","ownSentence":true},{"say":"прийом"}],"discard":[{"say":"scratch that","hint":true},{"say":"discard turn"},{"say":"discard this turn"}]}"#

    @Test func parsesTheAnnouncement() throws {
        let words = try #require(CommandWords(attribute: Self.announcement))
        #expect(words.send == [
            .init("zulu", hint: true), .init("copy", ownSentence: true, hint: true), .init("copy that", ownSentence: true), .init("прийом"),
        ])
        #expect(words.discard == [.init("scratch that", hint: true), .init("discard turn"), .init("discard this turn")])
        #expect(words == .builtIn)
    }

    @Test func ignoresKeysItDoesNotKnow() throws {
        let words = try #require(CommandWords(attribute: #"{"v":1,"lang":"en","send":[{"say":"over","hint":true,"weight":2}],"wake":[]}"#))
        #expect(words == CommandWords(send: [.init("over", hint: true)], discard: []))
    }

    @Test(arguments: [
        nil,
        "",
        "not json",
        #"{"v":2,"send":[{"say":"zulu"}]}"#,
        #"{"send":[{"say":"zulu"}]}"#,
        #"{"v":1,"send":[]}"#,
        #"{"v":1,"send":[{"say":"  "}]}"#,
        #"{"v":1,"discard":[{"say":"scratch that"}]}"#,
        #"{"v":1,"send":[{"hint":true}]}"#,
        #"{"v":1,"send":"zulu"}"#,
    ])
    func anythingElseIsNoAnnouncement(_ attribute: String?) {
        #expect(CommandWords(attribute: attribute) == nil)
    }

    @Test func hintsQuoteTheFlaggedWordsElseTheFirst() throws {
        #expect(CommandWords.builtIn.sendHint == #""zulu" or "copy""#)
        #expect(CommandWords.builtIn.discardHints == ["scratch that"])
        let unflagged = try #require(CommandWords(attribute: #"{"v":1,"send":[{"say":"over"},{"say":"roger"}],"discard":[{"say":"belay"},{"say":"cancel"}]}"#))
        #expect(unflagged.sendHint == #""over""#)
        #expect(unflagged.discardHints == ["belay"])
        let three = try #require(CommandWords(attribute: #"{"v":1,"send":[{"say":"a","hint":true},{"say":"b","hint":true},{"say":"Прийом","hint":true}]}"#))
        #expect(three.sendHint == #""a", "b" or "Прийом""#)
        #expect(CommandWords.join(three.sendHints, quoted: false) == "a, b or Прийом")
        #expect(CommandWords.join([]) == "")
    }

    @Test func theExplainerQuotesEverySendWord() throws {
        #expect(CommandWords.builtIn.explainer == #"say "zulu", "copy", "copy that" or "прийом" to send now, "scratch that" to drop it."#)
        let sendOnly = try #require(CommandWords(attribute: #"{"v":1,"send":[{"say":"over"}]}"#))
        #expect(sendOnly.explainer == #"say "over" to send now."#)
    }

    @Test func readsACaptionsMark() {
        let marked = [VoiceProtocol.captionCommandAttribute: "send", VoiceProtocol.captionWordsAttribute: "Book a table"]
        #expect(SpokenCommand(captionAttributes: marked) == SpokenCommand(.send, words: "Book a table"))
        let alone = [VoiceProtocol.captionCommandAttribute: "discard", VoiceProtocol.captionWordsAttribute: ""]
        #expect(SpokenCommand(captionAttributes: alone) == SpokenCommand(.discard, words: ""))
        #expect(SpokenCommand(captionAttributes: [VoiceProtocol.captionCommandAttribute: "send"]) == nil)
        #expect(SpokenCommand(captionAttributes: [VoiceProtocol.captionWordsAttribute: "Book"]) == nil)
        #expect(SpokenCommand(captionAttributes: [VoiceProtocol.captionCommandAttribute: "rewind", VoiceProtocol.captionWordsAttribute: ""]) == nil)
        #expect(SpokenCommand(captionAttributes: [:]) == nil)
    }
}

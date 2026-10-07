import Foundation
@testable import HeyDanCore
import Testing

/// Review mode as the worker drives it (`voice-livekit-worker.ts` ReviewControl) and the page folds it (`review.ts`,
/// `livekit-call.ts`).
struct ReviewMessageTests {
    private func state(_ json: String) throws -> ReviewState {
        try JSONDecoder().decode(ReviewState.self, from: Data(json.utf8))
    }

    @Test func decodesEveryDraftShape() throws {
        #expect(try state(#"{"seq":1,"mode":"review","draft":null}"#) == ReviewState(seq: 1, mode: .review))
        #expect(try state(#"{"seq":2,"mode":"review","draft":{"id":1,"state":"recording","text":""},"preparing":true}"#)
            == ReviewState(seq: 2, mode: .review, draft: Draft(id: 1, state: .recording), preparing: true))
        #expect(try state(#"{"seq":3,"mode":"review","draft":{"id":4,"state":"finishing","text":"","reason":"switch"}}"#).draft
            == Draft(id: 4, state: .finishing, reason: .switch))
        #expect(try state(#"{"seq":4,"mode":"review","draft":{"id":4,"state":"empty","text":"","reason":"agent"}}"#).draft
            == Draft(id: 4, state: .empty, reason: .agent))
        // A reason from a newer worker is no reason this app can word.
        #expect(try state(#"{"seq":5,"mode":"review","draft":{"id":4,"state":"failed","text":"half","reason":"later"}}"#).draft
            == Draft(id: 4, state: .failed, text: "half"))
    }

    @Test func requestsCarryOnlyWhatTheOperationNeeds() {
        #expect(ReviewRequest(gen: 1).payload == #"{"gen":1}"#)
        #expect(ReviewRequest(gen: 2, mode: .review, afterTurn: 3).payload == #"{"afterTurn":3,"gen":2,"mode":"review"}"#)
        #expect(ReviewRequest(gen: 3, mode: .auto, afterTurn: 0).payload == #"{"afterTurn":0,"gen":3,"mode":"auto"}"#)
        #expect(ReviewRequest(gen: 4, draft: 7).payload == #"{"draft":7,"gen":4}"#)
    }

    @Test func methodsAreTheWorkers() throws {
        let ops: [Review.Op] = [.mode, .talk, .done, .send, .discard]
        let v4 = try #require(VoiceProtocol.Names(version: 4))
        #expect(ops.map(v4.method)
            == ["nanoclaw.voice.mode", "nanoclaw.voice.talk", "nanoclaw.voice.done", "nanoclaw.voice.send", "nanoclaw.voice.discard"])
        let v6 = try #require(VoiceProtocol.Names(version: 6))
        #expect(ops.map(v6.method) == [
            "nanoclaw.voice-mode.mode", "nanoclaw.voice-mode.talk", "nanoclaw.voice-mode.done", "nanoclaw.voice-mode.send",
            "nanoclaw.voice-mode.discard",
        ])
    }

    @Test func repliesCarryTheirFields() {
        let talk = ReviewReply(payload: #"{"gen":5,"ok":true,"seq":9,"draft":2}"#)
        #expect(talk?.draft == 2 && talk?.turn == nil)
        #expect(ReviewReply(payload: #"{"gen":6,"ok":true,"seq":10,"turn":4}"#)?.turn == 4)
        #expect(ReviewReply(payload: #"{"gen":7,"ok":true,"seq":11,"submitted":3}"#)?.submitted == 3)
        #expect(ReviewReply(payload: #"{"gen":8,"ok":false,"seq":11,"error":"stale"}"#)?.error == "stale")
    }
}

struct ReviewSessionTests {
    private var transcript = Transcript()
    private let now = Date(timeIntervalSince1970: 1000)

    private func reply(_ seq: Int, ok: Bool = true, draft: Int? = nil, turn: Int? = nil, submitted: Int? = nil, error: String? = nil) -> ReviewReply {
        var fields = [#""gen":1"#, #""ok":\#(ok)"#, #""seq":\#(seq)"#]
        if let draft { fields.append(#""draft":\#(draft)"#) }
        if let turn { fields.append(#""turn":\#(turn)"#) }
        if let submitted { fields.append(#""submitted":\#(submitted)"#) }
        if let error { fields.append(#""error":"\#(error)""#) }
        return ReviewReply(payload: "{\(fields.joined(separator: ","))}")!
    }

    private mutating func receive(_ session: inout ReviewSession, _ state: ReviewState, micOn: Bool = false) -> Bool? {
        session.receive(state, transcript: &transcript, micOn: micOn)
    }

    @Test mutating func theNewestStateWinsAndAnOlderOneIsIgnored() {
        var session = ReviewSession(pick: .auto)
        session.startCall()
        let r1 = receive(&session, ReviewState(seq: 3, mode: .review))
        #expect(r1 == false)
        let r2 = receive(&session, ReviewState(seq: 2, mode: .auto))
        #expect(r2 == nil)
        #expect(session.review.mode == .review && session.seq == 3)
    }

    @Test mutating func aRecordingFromTalkToSend() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        let r3 = session.beginInitialSwitch()
        #expect(r3)
        #expect(session.review.pending == Review.Pending(.mode, to: .review))
        let r4 = session.beginInitialSwitch()
        #expect(!r4)
        // The reply names a state not here yet: the switch stays pending until it is.
        let r5 = session.settle(reply(1), agentName: "Dan")
        #expect(!r5)
        #expect(session.review.pending != nil)
        _ = receive(&session, ReviewState(seq: 1, mode: .review))
        #expect(session.review.pending == nil)

        let r6 = session.beginTalk()
        #expect(r6)
        let r7 = session.beginTalk()
        #expect(!r7)
        _ = receive(&session, ReviewState(seq: 2, mode: .review, preparing: true))
        _ = receive(&session, ReviewState(seq: 3, mode: .review, draft: Draft(id: 1, state: .recording)))
        // The reply's state is already here: talk settles at once.
        let r8 = session.settle(reply(3, draft: 1), agentName: "Dan")
        #expect(!r8)
        #expect(session.review.pending == nil)

        // The recording's words never reach the transcript.
        let r9 = session.caption(segment: "S1", text: "book a table", knownToTranscript: false)
        #expect(r9)
        let r10 = session.caption(segment: "S2", text: "for eight.Thanks", knownToTranscript: false)
        #expect(r10)
        #expect(session.words == "book a table for eight. Thanks")
        let r11 = session.caption(segment: "S1", text: "Book a table", knownToTranscript: false)
        #expect(r11)
        #expect(session.words == "Book a table for eight. Thanks")

        let r12 = session.beginDone()
        #expect(r12 == 1)
        let r13 = session.beginDone()
        #expect(r13 == nil)
        _ = receive(&session, ReviewState(seq: 4, mode: .review, draft: Draft(id: 1, state: .finishing)))
        _ = session.settle(reply(4), agentName: "Dan")
        let r14 = session.beginSend()
        #expect(r14 == nil)
        _ = receive(&session, ReviewState(seq: 5, mode: .review, draft: Draft(id: 1, state: .ready, text: "Book a table for eight.")))
        let r15 = session.beginSend()
        #expect(r15 == 1)
        session.sent(turn: 2)
        _ = receive(&session, ReviewState(seq: 6, mode: .review))
        _ = session.settle(reply(6, turn: 2), agentName: "Dan", outcome: .init(delivery: .sending))
        #expect(session.review.delivery == .sending && session.review.pending == nil)
        session.turnStatus(TurnStatus(turn: 2, status: .sent, text: "Book a table for eight."))
        #expect(session.review.delivery == .sent)
        session.turnStatus(TurnStatus(turn: 1, status: .lost, reason: .empty))
        #expect(session.review.delivery == .sent)
        #expect(session.maxTurn == 2)
    }

    @Test func onlyTheNewestRecordingIsHeard() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        _ = session.beginTalk()
        let r16 = session.caption(segment: "A", text: "first", knownToTranscript: false)
        #expect(r16)
        _ = session.settle(reply(1, ok: false, error: "agent_speaking"), agentName: "Dan")
        #expect(session.review.note == "Tap talk when Dan finishes.")
        _ = session.beginTalk()
        #expect(session.words.isEmpty)
        // A late update to the earlier recording's segment is still review's, never heard now.
        let r17 = session.caption(segment: "A", text: "first words", knownToTranscript: false)
        #expect(r17)
        #expect(session.words.isEmpty)
        let r18 = session.caption(segment: "B", text: "second", knownToTranscript: false)
        #expect(r18)
        #expect(session.words == "second")
    }

    @Test func autoCaptionsStayTheTranscripts() {
        var session = ReviewSession(pick: .auto)
        session.startCall()
        let r19 = session.caption(segment: "A", text: "hello", knownToTranscript: false)
        #expect(!r19)
        // Switching to review, the open words are heard as the draft's.
        let r20 = session.beginSwitch(to: .review)
        #expect(r20)
        let r21 = session.caption(segment: "A", text: "hello there", knownToTranscript: true)
        #expect(r21)
    }

    @Test mutating func aSwitchMovesTheOpenAutoTurnIntoTheDraft() {
        transcript.caption(segment: "S1", text: "Book it.", isFinal: true, fromCaller: true, at: now)
        transcript.apply(.status(TurnStatus(turn: 1, status: .sent, text: "Book it.")), at: now)
        transcript.caption(segment: "S2", text: "and also", isFinal: true, fromCaller: true, at: now)
        transcript.caption(segment: "S3", text: "the wine", isFinal: false, fromCaller: true, at: now)
        var session = ReviewSession(pick: .auto)
        session.startCall()
        session.turnStatus(TurnStatus(turn: 1, status: .sent, text: "Book it."))
        let r22 = session.beginSwitch(to: .review)
        #expect(r22)
        // The interim kept growing during the switch: heard in full.
        let r23 = session.caption(segment: "S3", text: "the wine list", knownToTranscript: true)
        #expect(r23)
        _ = receive(&session, ReviewState(seq: 1, mode: .review, draft: Draft(id: 1, state: .finishing, reason: .switch)))
        #expect(transcript.lines.map(\.text) == ["Book it."])
        #expect(session.words == "and also the wine list")
        // Their later captions are review's.
        let r24 = session.caption(segment: "S2", text: "and also,", knownToTranscript: true)
        #expect(r24)
        _ = session.settle(reply(1, submitted: 1), agentName: "Dan", outcome: .init(note: "Previous turn already submitted."))
        #expect(session.review.note == "Previous turn already submitted.")
    }

    @Test mutating func aSentDraftEntersTheTranscriptOnceWithItsText() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        let sending = TurnStatus(turn: 4, status: .sending, text: "Call mum.", draft: 2)
        transcript.apply(.status(sending), at: now)
        session.turnStatus(sending)
        #expect(session.review.delivery == .sending)
        #expect(transcript.lines.map(\.mark) == [.sending])
        #expect(transcript.lines.map(\.turn) == [1])
        transcript.apply(.status(TurnStatus(turn: 4, status: .lost, reason: .timeout, text: "Call mum.")), at: now)
        session.turnStatus(TurnStatus(turn: 4, status: .lost, reason: .timeout))
        #expect(transcript.lines.map(\.mark) == [.lost(.timeout)])
        #expect(session.review.delivery == .lost)
        // An auto turn's sending shows nothing.
        transcript.apply(.status(TurnStatus(turn: 5, status: .sending, text: "hi")), at: now)
        #expect(transcript.lines.count == 1)
    }

    @Test mutating func theMicrophoneFollowsAStoppedRecording() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        let r25 = receive(&session, ReviewState(seq: 1, mode: .review, draft: Draft(id: 1, state: .recording)), micOn: true)
        #expect(r25 == false)
        let r26 = receive(&session, ReviewState(seq: 2, mode: .review, draft: Draft(id: 1, state: .finishing, reason: .agent)), micOn: true)
        #expect(r26 == true)
        // Never while talk is opening it.
        _ = receive(&session, ReviewState(seq: 3, mode: .review, draft: Draft(id: 1, state: .empty)))
        let r27 = session.beginTalk()
        #expect(r27)
        let r28 = receive(&session, ReviewState(seq: 4, mode: .review, draft: Draft(id: 1, state: .empty)), micOn: true)
        #expect(r28 == false)
    }

    @Test mutating func handsFreeWaitsForTheDraft() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        _ = receive(&session, ReviewState(seq: 1, mode: .review, draft: Draft(id: 1, state: .ready, text: "x")))
        let r29 = session.beginSwitch(to: .auto)
        #expect(!r29)
        #expect(session.review.note == "Send or discard before hands-free.")
        _ = receive(&session, ReviewState(seq: 2, mode: .review, draft: Draft(id: 1, state: .ready, text: "x", tooLong: true)))
        let r30 = session.beginSwitch(to: .auto)
        #expect(!r30)
        #expect(session.review.note == "Discard before hands-free.")
        _ = receive(&session, ReviewState(seq: 3, mode: .review))
        let r31 = session.beginSwitch(to: .auto)
        #expect(r31)
        #expect(session.review.note == nil)
        // Unanswered: said, and the worker's state is read again.
        let r32 = session.settle(nil, agentName: "Dan")
        #expect(r32)
        #expect(session.review.note == "The voice service did not answer - try again.")
        #expect(session.review.pending == nil)
    }

    @Test func aLineWithoutReviewRunsHandsFree() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        session.notOffered(micMuted: true)
        #expect(session.review.mode == .auto && !session.review.available)
        #expect(session.review.note == "Manual isn't available on this line.")
        let r33 = session.beginInitialSwitch()
        #expect(!r33)
        let r34 = session.beginSwitch(to: .review)
        #expect(!r34)
        // The pick stays for the next call.
        #expect(session.pick == .review)
    }

    @Test func aCallPickedInManualShowsTheSwitchComing() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        #expect(session.review.pending == Review.Pending(.mode, to: .review))
        #expect(session.review.holdsMicClosed)
        let asks = session.beginInitialSwitch()
        #expect(asks && session.review.pending == Review.Pending(.mode, to: .review))
    }

    @Test mutating func aLateOfferStillStartsManual() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        _ = receive(&session, ReviewState(seq: 1, mode: .auto))
        session.notOffered(micMuted: true)
        #expect(session.review.mode == .auto && session.review.pending == nil && !session.review.available)
        session.offered()
        let asks = session.beginInitialSwitch()
        #expect(asks)
        #expect(session.review.pending == Review.Pending(.mode, to: .review))
        _ = session.settle(reply(2), agentName: "Dan")
        _ = receive(&session, ReviewState(seq: 2, mode: .review))
        #expect(session.review.mode == .review && session.review.pending == nil)
        let again = session.beginInitialSwitch()
        #expect(!again)
    }

    @Test mutating func aSwitchByHandWinsOverALateOffer() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        session.notOffered(micMuted: true)
        session.offered()
        let byHand = session.beginSwitch(to: .review)
        #expect(byHand)
        _ = session.settle(reply(1, ok: false, error: "stale"), agentName: "Dan")
        #expect(session.review.pending == nil && session.review.mode == .auto)
        let initial = session.beginInitialSwitch()
        #expect(!initial)
    }

    @Test func aSwitchToManualThatDidNotHappenGivesTheMicBack() {
        #expect(Review.reopensMic(to: .review, taken: false, muted: true, mutedByHand: false, openBefore: true))
        #expect(!Review.reopensMic(to: .review, taken: false, muted: true, mutedByHand: false, openBefore: false))
        #expect(!Review.reopensMic(to: .review, taken: false, muted: true, mutedByHand: true, openBefore: true))
        #expect(!Review.reopensMic(to: .review, taken: true, muted: true, mutedByHand: false, openBefore: true))
    }

    @Test mutating func manualRefusesAnUnmuteOutsideARecording() {
        var session = ReviewSession(pick: .auto)
        session.startCall()
        #expect(!session.review.holdsMicClosed)
        _ = receive(&session, ReviewState(seq: 1, mode: .review))
        #expect(session.review.holdsMicClosed)
        _ = receive(&session, ReviewState(seq: 2, mode: .review, draft: Draft(id: 1, state: .recording)))
        #expect(!session.review.holdsMicClosed)
        _ = receive(&session, ReviewState(seq: 3, mode: .review, draft: Draft(id: 1, state: .ready, text: "x")))
        #expect(session.review.holdsMicClosed)
    }

    @Test mutating func callKitMuteFollowsTheCallerAndOnlyAcknowledgesTheApp() {
        var session = ReviewSession(pick: .auto)
        session.startCall()
        #expect(session.review.callKitMute(true, reportedByApp: false) == .apply)
        #expect(session.review.callKitMute(false, reportedByApp: false) == .apply)
        #expect(session.review.callKitMute(true, reportedByApp: true) == .acknowledge)

        _ = receive(&session, ReviewState(seq: 1, mode: .review))
        #expect(session.review.callKitMute(false, reportedByApp: false) == .refuse)
        #expect(session.review.callKitMute(true, reportedByApp: false) == .apply)
        // The app's report of a microphone it opened to record is never refused, so nothing bounces back.
        #expect(session.review.callKitMute(false, reportedByApp: true) == .acknowledge)
        _ = receive(&session, ReviewState(seq: 2, mode: .review, draft: Draft(id: 1, state: .recording)))
        #expect(session.review.callKitMute(false, reportedByApp: false) == .apply)
        _ = receive(&session, ReviewState(seq: 3, mode: .review, draft: Draft(id: 1, state: .ready, text: "x")))
        #expect(session.review.callKitMute(false, reportedByApp: false) == .refuse)
    }

    @Test func aManualCallWithoutManualOpensTheMicInHandsFree() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        let opens = session.notOffered(micMuted: true)
        #expect(opens && session.review.mode == .auto)
        #expect(session.review.note == "Manual isn't available on this line.")
        let again = session.notOffered(micMuted: true)
        #expect(!again)

        session.startCall()
        session.mutedByHand = true
        let byHand = session.notOffered(micMuted: true)
        #expect(!byHand && session.review.mode == .auto)

        var auto = ReviewSession(pick: .auto)
        auto.startCall()
        let handsFree = auto.notOffered(micMuted: true)
        #expect(!handsFree)
    }

    @Test func aRefusedInitialSwitchSaysTheCallIsHandsFree() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        _ = session.beginInitialSwitch()
        _ = session.settle(reply(1, ok: false, error: "stale"), agentName: "Dan", outcome: .init(note: "Manual didn't start - the call is hands-free.", mode: .auto))
        #expect(session.review.mode == .auto)
        #expect(session.review.note == "Manual didn't start - the call is hands-free.")
    }

    @Test func aManualCallWhoseSwitchWasRefusedOpensTheMicInHandsFree() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        let early = session.initialSwitchReopensMic(reply(1, ok: false, error: "stale"), micMuted: true)
        #expect(!early)
        _ = session.beginInitialSwitch()
        _ = session.settle(reply(1, ok: false, error: "stale"), agentName: "Dan", outcome: .init(mode: .auto))
        let refused = session.initialSwitchReopensMic(reply(1, ok: false, error: "stale"), micMuted: true)
        let open = session.initialSwitchReopensMic(reply(1, ok: false, error: "stale"), micMuted: false)
        let taken = session.initialSwitchReopensMic(reply(2), micMuted: true)
        #expect(refused && !open && !taken)
        session.mutedByHand = true
        let byHand = session.initialSwitchReopensMic(reply(1, ok: false, error: "stale"), micMuted: true)
        #expect(!byHand)

        var auto = ReviewSession(pick: .auto)
        auto.startCall()
        let handsFree = auto.initialSwitchReopensMic(reply(1, ok: false, error: "stale"), micMuted: true)
        #expect(!handsFree)
    }

    @Test mutating func anUnansweredInitialSwitchLetsTheWorkersNextStateDecideTheMic() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        _ = receive(&session, ReviewState(seq: 1, mode: .auto))
        _ = session.beginInitialSwitch()
        _ = session.settle(nil, agentName: "Dan")
        let unanswered = session.initialSwitchReopensMic(nil, micMuted: true)
        #expect(!unanswered)
        // The worker stayed hands-free: the microphone opens, once.
        _ = receive(&session, ReviewState(seq: 2, mode: .auto))
        let stayed = session.resyncedStateReopensMic(micMuted: true)
        let again = session.resyncedStateReopensMic(micMuted: true)
        #expect(stayed && !again)

        // The worker did switch: the microphone stays closed.
        var switched = ReviewSession(pick: .review)
        switched.startCall()
        _ = receive(&switched, ReviewState(seq: 1, mode: .auto))
        _ = switched.beginInitialSwitch()
        _ = switched.settle(nil, agentName: "Dan")
        _ = switched.initialSwitchReopensMic(nil, micMuted: true)
        _ = receive(&switched, ReviewState(seq: 2, mode: .review))
        let inManual = switched.resyncedStateReopensMic(micMuted: true)
        #expect(!inManual && switched.review.mode == .review)

        // No unanswered switch: a state never opens the microphone.
        var answered = ReviewSession(pick: .review)
        answered.startCall()
        _ = receive(&answered, ReviewState(seq: 1, mode: .auto))
        let none = answered.resyncedStateReopensMic(micMuted: true)
        #expect(!none)
    }

    @Test mutating func aDraftOutlivesACallTheCallerDidNotEnd() {
        var session = ReviewSession(pick: .review)
        session.startCall()
        _ = receive(&session, ReviewState(seq: 1, mode: .review, draft: Draft(id: 1, state: .recording)))
        _ = session.caption(segment: "A", text: "remind me", knownToTranscript: false)
        session.endCall(byCaller: false)
        #expect(session.review.draft == Draft(id: 1, state: .failed, text: "remind me"))
        #expect(session.review.ended && session.review.isOn)
        let r35 = session.pickMode(.auto)
        #expect(!r35)
        let r36 = session.beginDiscard(live: false)
        #expect(r36 == .local)
        #expect(session.review.draft == nil && !session.review.ended)

        session.startCall()
        _ = receive(&session, ReviewState(seq: 1, mode: .review, draft: Draft(id: 2, state: .ready, text: "x")))
        session.endCall(byCaller: true)
        #expect(session.review.draft == nil && !session.review.ended)
        #expect(session.review.mode == .review)
    }

    @Test func thePickIsKeptOutsideACall() {
        var session = ReviewSession(pick: .auto)
        let r37 = session.pickMode(.review)
        #expect(r37)
        let r38 = session.pickMode(.review)
        #expect(!r38)
        #expect(session.review.mode == .review)
        session.startCall()
        #expect(session.review.mode == .review && session.beginInitialSwitch())
    }
}

struct ReviewViewTests {
    private func view(
        _ phase: ReviewView.Phase = .listening, draft: Draft? = nil, pending: Review.Pending? = nil, micOn: Bool = false,
        reconnecting: Bool = false, configure: (inout ReviewSession) -> Void = { _ in }
    ) -> ReviewView {
        var session = ReviewSession(pick: .review)
        session.startCall()
        var transcript = Transcript()
        _ = session.receive(ReviewState(seq: 1, mode: .review, draft: draft), transcript: &transcript, micOn: false)
        configure(&session)
        var review = session.review
        if let pending { review.pending = pending }
        return ReviewView(phase: phase, agentName: "Dan", reconnecting: reconnecting, waited: 75, review: review, words: "so far", micOn: micOn)
    }

    @Test func keysFollowTheDraft() {
        let idle = view()
        #expect([idle.left, idle.right] == [.init("End", .end), .init("Talk", .talk)])
        #expect(idle.chip == "Mic muted" && idle.tone == .off && idle.hint == "Tap talk to start.")

        let recording = view(draft: Draft(id: 1, state: .recording), micOn: true)
        #expect(recording.right == .init("Done", .done))
        #expect(recording.chip == "Listening" && recording.tone == .you && recording.mic == "Recording" && recording.capturing)
        #expect(recording.panel == .init(title: "hearing - not sent", text: "so far", tone: .hearing))

        let finishing = view(draft: Draft(id: 1, state: .finishing, reason: .agent))
        #expect([finishing.left, finishing.right] == [.init("Discard", .discard), .init("Send", .send, disabled: true)])
        #expect(finishing.panel?.note == "Dan started speaking - review what was heard")
        #expect(finishing.modeDisabled && finishing.endable)

        let ready = view(draft: Draft(id: 1, state: .ready, text: "Book it."))
        #expect(ready.right == .init("Send", .send) && ready.chip == "Review draft" && ready.hint == "Check the words, then send.")
        #expect(ready.panel == .init(title: "draft - not sent", text: "Book it.", tone: .draft))

        let empty = view(draft: Draft(id: 1, state: .empty))
        #expect(empty.right == .init("Talk", .talk) && empty.hint == "Nothing heard - tap talk to retry.")

        let failed = view(draft: Draft(id: 1, state: .failed, text: "half"))
        #expect(failed.tone == .error && failed.panel?.note == "unverified - not sendable")

        let long = String(repeating: "é", count: 4100)
        let tooLong = view(draft: Draft(id: 1, state: .ready, text: long, tooLong: true))
        #expect(tooLong.chip == "Draft too long" && tooLong.right.disabled)
        #expect(tooLong.panel?.note == "about 4 characters over the limit")
    }

    @Test func overlaysSpeakForTheAgentAndTheLine() {
        let speaking = view(.talking)
        #expect(speaking.chip == "Dan is speaking" && speaking.right.disabled && speaking.hint == "Tap talk when Dan finishes.")
        let sendable = view(.talking, draft: Draft(id: 1, state: .ready, text: "x"))
        #expect(sendable.hint == "You can send it now; Dan gets it next." && !sendable.right.disabled)
        let working = view(.thinking)
        #expect(working.chip == "Dan is working" && working.tone == .think && working.hint == "Tap talk to add more · waiting 1:15")
        let switching = view(pending: .init(.mode, to: .auto))
        #expect(switching.chip == "Switching to hands-free" && switching.hint == "Mic off - please wait." && switching.right.disabled)
        let preparing = view { session in
            var transcript = Transcript()
            _ = session.receive(ReviewState(seq: 2, mode: .review, preparing: true), transcript: &transcript, micOn: false)
        }
        #expect(preparing.chip == "Getting ready" && preparing.right.disabled)
        let reconnecting = view(draft: Draft(id: 1, state: .ready, text: "x"), reconnecting: true)
        #expect(reconnecting.chip == "Reconnecting…" && reconnecting.left == .init("Discard", .discard, disabled: true))
        let stuck = view(draft: Draft(id: 1, state: .ready, text: "x")) { $0.micFailed(.stop) }
        #expect(stuck.mic == "Mic still on" && stuck.right.disabled)
    }

    @Test func outsideACall() {
        #expect(view(.idle).hint == "Call first, then tap talk.")
        #expect(view(.connecting).left == .init("Cancel", .cancel))
        var session = ReviewSession(pick: .review)
        session.startCall()
        var transcript = Transcript()
        _ = session.receive(ReviewState(seq: 1, mode: .review, draft: Draft(id: 1, state: .ready, text: "x")), transcript: &transcript, micOn: false)
        session.endCall(byCaller: false)
        let kept = ReviewView(phase: .ended, agentName: "Dan", reconnecting: false, waited: 0, review: session.review, words: "", micOn: false)
        #expect([kept.left, kept.right] == [.init("Discard", .discard), .init("Send", .send, disabled: true)])
        #expect(kept.hint == "Draft not sent. Copy it, or discard it to call again." && kept.modeDisabled && kept.panel != nil)
    }

    @Test func wording() throws {
        #expect(Review.modeCaption(.review, commands: true, words: .builtIn, wake: true, pauseSends: false) == "Tap talk, read your words, then send.")
        #expect(Review.modeCaption(.auto, commands: false, words: .builtIn, wake: true, pauseSends: false) == "Stop for a moment to send.")
        #expect(Review.modeCaption(.auto, commands: true, words: .builtIn, wake: true, pauseSends: false) == #"Say "zulu" or "copy" to send."#)
        #expect(Review.modeCaption(.auto, commands: true, words: .builtIn, wake: false, pauseSends: false) == #"Stop for a moment, or say "zulu" or "copy", to send."#)
        let announced = try #require(CommandWords(attribute: #"{"v":1,"send":[{"say":"over","hint":true},{"say":"roger"}]}"#))
        #expect(Review.modeCaption(.auto, commands: true, words: announced, wake: true, pauseSends: false) == #"Say "over" to send."#)
        #expect(Review.refusalNote("stale", agentName: "Dan") == nil)
        #expect(Review.refusalNote("recording", agentName: "Dan") == "Tap done, then send or discard.")
        #expect(Review.reopensMic(to: .auto, taken: true, muted: true, mutedByHand: false, openBefore: false))
        #expect(!Review.reopensMic(to: .auto, taken: true, muted: true, mutedByHand: true, openBefore: false))
        #expect(!Review.reopensMic(to: .auto, taken: false, muted: true, mutedByHand: false, openBefore: true))
        #expect(ReviewView.keyIdentity(.cancel, draft: nil) == ReviewView.keyIdentity(.end, draft: 3))
        #expect(ReviewView.keyIdentity(.discard, draft: 3) == "discard:3")
        #expect(asWritten("Switching to Manual", keep: ["Manual"]) == "switching to Manual")
        #expect(asWritten("Say \"Hey LiveKit\" to start.", keep: ["Manual", "Hey LiveKit", ""]) == "say \"Hey LiveKit\" to start.")
        #expect(asWritten("Dan is speaking", keep: []) == "dan is speaking")
    }
}

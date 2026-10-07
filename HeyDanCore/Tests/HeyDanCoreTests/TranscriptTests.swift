import Foundation
@testable import HeyDanCore
import Testing

struct TranscriptTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func status(_ turn: Int, _ status: TurnStatus.Status, _ text: String? = nil, reason: TurnStatus.Reason? = nil) -> TurnMessage {
        .status(TurnStatus(turn: turn, status: status, reason: reason, text: text))
    }

    private func said(_ transcript: inout Transcript, _ segment: String, _ text: String, final: Bool = true, at time: TimeInterval = 0) {
        transcript.caption(segment: segment, text: text, isFinal: final, fromCaller: true, at: at(time))
    }

    private func spoke(_ transcript: inout Transcript, _ segment: String, _ text: String, at time: TimeInterval = 0) {
        transcript.caption(segment: segment, text: text, isFinal: true, fromCaller: false, at: at(time))
    }

    // MARK: - Captions

    @Test func aCallerSegmentFirmsUpInPlace() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a", final: false)
        said(&transcript, "SG_turn_1", "Book a table.Please", final: false, at: 0.5)
        #expect(transcript.lines.count == 1)
        #expect(transcript.lines[0].text == "Book a table. Please")
        #expect(!transcript.lines[0].isFinal)
        #expect(transcript.streamingLineID == transcript.lines[0].id)
        // The final repeats the last interim word for word: it still firms the line up, with no new caret.
        said(&transcript, "SG_turn_1", "Book a table.Please", at: 2)
        #expect(transcript.lines[0].isFinal)
        #expect(transcript.lastDeltaAt == at(0.5))
        #expect(transcript.lines[0].speaker == .caller)
    }

    @Test func aLateInterimNeverUndoesAFinal() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a table")
        said(&transcript, "SG_turn_1", "Book a", final: false)
        #expect(transcript.lines[0].text == "Book a table")
        #expect(transcript.lines[0].isFinal)
    }

    @Test func agentLinesAreFinalAndKeepTheirSpacing() {
        var transcript = Transcript()
        transcript.caption(segment: "SG_a", text: " Done.Next ", isFinal: false, fromCaller: false, at: t0)
        #expect(transcript.lines[0].text == "Done.Next")
        #expect(transcript.lines[0].isFinal)
        #expect(transcript.lines[0].speaker == .agent)
    }

    @Test func aSegmentKeepsItsSide() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Hello", final: false)
        transcript.caption(segment: "SG_turn_1", text: "Hello there", isFinal: true, fromCaller: false, at: at(1))
        #expect(transcript.lines.map(\.speaker) == [.caller])
        #expect(transcript.lines[0].text == "Hello there")
    }

    @Test func emptyCaptionsShowNothing() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "   ", final: false)
        #expect(transcript.lines.isEmpty)
    }

    @Test func staleInterimsSettleAndTheEndFinalizesEverything() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a", final: false)
        said(&transcript, "SG_turn_2", "And a", final: false, at: 4)
        let early = transcript.settleStaleInterims(at: at(4.9))
        #expect(!early)
        let settled = transcript.settleStaleInterims(at: at(5))
        #expect(settled)
        #expect(transcript.lines.map(\.isFinal) == [true, false])
        // A real interim after the settle reads as unsettled again.
        said(&transcript, "SG_turn_1", "Book a cab", final: false, at: 6)
        #expect(transcript.lines.map(\.isFinal) == [false, false])
        transcript.end()
        #expect(transcript.lines.allSatisfy { $0.isFinal })
        #expect(transcript.streamingLineID == nil)
    }

    // MARK: - Turn statuses

    @Test func aSentTurnMarksTheOpenLinesItIsMadeOf() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a table")
        said(&transcript, "SG_turn_2", "for two")
        transcript.apply(status(1, .sending), at: at(1))
        #expect(transcript.lines.allSatisfy { $0.mark == nil })
        transcript.apply(status(1, .sent, "Book a table for two"), at: at(2))
        #expect(transcript.lines.map(\.mark) == [.sent, .sent])
        #expect(transcript.lines.map(\.turn) == [1, 1])
    }

    @Test func aTurnClaimsTheLatestLineItsTextContainsAndLeavesTheRestOpen() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a table")
        said(&transcript, "SG_turn_2", "And a taxi")
        transcript.apply(status(1, .sent, "Book a table"), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.sent, nil])
        transcript.apply(status(2, .sent, "And a taxi"), at: at(2))
        #expect(transcript.lines.map(\.mark) == [.sent, .sent])
        #expect(transcript.lines.map(\.turn) == [1, 2])
    }

    @Test func aSendWordLineBelongsToTheTurnItEnded() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a table")
        said(&transcript, "SG_turn_2", "Copy that.")
        transcript.apply(status(1, .sent, "Book a table"), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.sent, .sent])
    }

    @Test func turnsAreNumberedAsShownNotAsTheWorkerCounts() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_3", "One")
        transcript.apply(status(3, .sent, "One"), at: at(1))
        transcript.apply(status(3, .working), at: at(1))
        said(&transcript, "SG_turn_7", "Two", at: 2)
        transcript.apply(status(7, .sent, "Two"), at: at(3))
        #expect(transcript.lines.map(\.turn) == [1, 2])
    }

    @Test func aWordlessLostTurnGetsItsOwnLineAndLeavesCaptionsOpen() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "late words")
        transcript.apply(status(1, .lost, reason: .stt), at: at(1))
        #expect(transcript.lines.count == 2)
        #expect(transcript.lines[0].mark == nil)
        #expect(transcript.lines[1].speaker == .caller)
        #expect(transcript.lines[1].text == "")
        #expect(transcript.lines[1].mark == .lost(.stt))
        #expect(transcript.lines[1].turn == 1)
    }

    @Test func aTurnWithNoCaptionShowsItsText() {
        var transcript = Transcript()
        transcript.apply(status(1, .sent, " Book a table "), at: at(1))
        #expect(transcript.lines.map(\.text) == ["Book a table"])
        #expect(transcript.lines[0].mark == .sent)
    }

    @Test func aSecondStatusReplacesTheMark() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a table")
        transcript.apply(status(1, .lost, "Book a table", reason: .timeout), at: at(1))
        #expect(transcript.lines[0].mark == .lost(.timeout))
        transcript.apply(status(1, .sent, "Book a table"), at: at(2))
        #expect(transcript.lines.map(\.mark) == [.sent])
    }

    // MARK: - Dropped words

    @Test func aDiscardDropsEveryOpenLine() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a")
        said(&transcript, "SG_turn_2", "table scratch that")
        transcript.apply(.dropped(DroppedSpeech(.discarded, text: "Book a table scratch that")), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.dropped(.discarded), .dropped(.discarded)])
    }

    @Test func aLoneCommandMarksOnlyItsOwnLine() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Zulu.")
        said(&transcript, "SG_turn_2", "What about")
        transcript.apply(.dropped(DroppedSpeech(.command, text: "Zulu")), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.dropped(.command), nil])
    }

    @Test func speechBeforeTheWakePhraseIsDroppedUpToTheLineThatHoldsIt() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Um")
        said(&transcript, "SG_turn_2", "what time is it")
        said(&transcript, "SG_turn_3", "Hey Dan")
        transcript.apply(.dropped(DroppedSpeech(.unaddressed, text: "what time is it")), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.dropped(.unaddressed), .dropped(.unaddressed), nil])
    }

    @Test func wordsBeforeTheWakePhraseOnItsOwnLineTagIt() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Um")
        said(&transcript, "SG_turn_2", "So anyway hey Dan book a table")
        transcript.apply(.dropped(DroppedSpeech(.unaddressed, text: "So anyway")), at: at(1))
        #expect(transcript.lines[0].mark == .dropped(.unaddressed))
        #expect(transcript.lines[1].mark == nil)
        #expect(transcript.lines[1].preWake)
        // The tagged line stays open for the turn the wake phrase started.
        transcript.apply(status(1, .sent, "book a table"), at: at(2))
        #expect(transcript.lines[1].mark == .sent)
    }

    @Test func unaddressedWordsWithNoMatchingLineDropTheOldest() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Mumble")
        said(&transcript, "SG_turn_2", "Next words")
        transcript.apply(.dropped(DroppedSpeech(.unaddressed, text: "something else entirely")), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.dropped(.unaddressed), nil])
    }

    @Test func anAsleepTurnDropsEveryOpenLine() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "and also")
        transcript.apply(.dropped(DroppedSpeech(.asleep, text: "and also")), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.dropped(.asleep)])
    }

    // MARK: - Replies

    @Test func agentLinesJoinTheirReplyAndOnlyTheFirstSaysWhatItAnswers() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_4", "Book a table")
        transcript.apply(status(4, .sent, "Book a table"), at: at(1))
        transcript.apply(ReplyInfo(reply: 1, turn: 4, part: 1, more: true), at: at(2))
        spoke(&transcript, "SG_a", "Sure.", at: 2)
        spoke(&transcript, "SG_b", "For how many?", at: 3)
        transcript.apply(ReplyInfo(reply: 2, turn: 4, part: 2), at: at(4))
        spoke(&transcript, "SG_c", "Booked.", at: 4)
        transcript.apply(ReplyInfo(reply: 3, unprompted: true), at: at(5))
        spoke(&transcript, "SG_d", "Reminder.", at: 5)
        transcript.apply(ReplyInfo(reply: 4, notice: true), at: at(6))
        spoke(&transcript, "SG_e", "That turn was lost.", at: 6)
        let agent = transcript.lines.filter { $0.speaker == .agent }
        #expect(agent.map(\.reply) == [1, 1, 2, 3, 4])
        #expect(agent.map(\.answers) == [.turn(1, part: nil), nil, .turn(1, part: 2), .unprompted, nil])
    }

    @Test func aLineThatCouldNotBeSpokenShowsItsText() {
        var transcript = Transcript()
        transcript.apply(ReplyInfo(reply: 1, unprompted: true), at: t0)
        transcript.apply(ReplyInfo(reply: 1, unspoken: true, text: "It is sunny."), at: at(1))
        #expect(transcript.lines.count == 1)
        #expect(transcript.lines[0].unspoken)
        #expect(transcript.lines[0].text == "It is sunny.")
        #expect(transcript.lines[0].answers == .unprompted)
        // A caption of the same text is marked instead of shown twice.
        transcript.apply(ReplyInfo(reply: 2, unprompted: true), at: at(2))
        spoke(&transcript, "SG_a", "Booked for eight.", at: 2)
        transcript.apply(ReplyInfo(reply: 2, unspoken: true, text: "Booked for eight"), at: at(3))
        #expect(transcript.lines.count == 2)
        #expect(transcript.lines[1].unspoken)
    }

    @Test func speakingOverTheAgentNotesItOncePerReply() {
        var transcript = Transcript()
        transcript.apply(ReplyInfo(reply: 1, unprompted: true), at: t0)
        transcript.apply(.unheard, at: at(1))
        transcript.apply(.unheard, at: at(2))
        transcript.apply(ReplyInfo(reply: 2, unprompted: true), at: at(3))
        transcript.apply(.unheard, at: at(4))
        #expect(transcript.lines.map(\.kind) == [.unheard, .unheard])
        #expect(transcript.lines.allSatisfy { $0.speaker == .agent && $0.text.isEmpty })
    }

    // MARK: - Wake phrase

    @Test func aWakeHeardWhileALineIsSpokenMarksThatLine() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Hey Dan", final: false, at: 1)
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1), at: at(2))
        #expect(transcript.lines[0].wake)
        // The same count again marks nothing new.
        said(&transcript, "SG_turn_2", "book a table", at: 3)
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1), at: at(3.5))
        #expect(!transcript.lines[1].wake)
    }

    @Test func aWakeHeardBeforeItsCaptionMarksTheNextLine() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Earlier", at: 0)
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1), at: at(5))
        #expect(!transcript.lines[0].wake)
        said(&transcript, "SG_turn_2", "Hey Dan book a table", final: false, at: 6)
        #expect(transcript.lines[1].wake)
        said(&transcript, "SG_turn_3", "More", at: 7)
        #expect(!transcript.lines[2].wake)
    }

    @Test func waitingAgainCancelsAPendingWakeMark() {
        var transcript = Transcript()
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1), at: t0)
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: true, heard: 1, slept: 1), at: at(1))
        said(&transcript, "SG_turn_1", "Hello", at: 2)
        #expect(!transcript.lines[0].wake)
    }

    @Test func aCutTranscriptMarksThePhrasesOwnCaption() {
        var transcript = Transcript()
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1, cut: true), at: t0)
        said(&transcript, "SG_turn_1", "Hey LiveKit", at: 1)
        said(&transcript, "SG_turn_2", "Book a table", at: 2)
        transcript.apply(status(1, .sent, "Book a table"), at: at(3))
        #expect(transcript.lines[0].wake && transcript.lines[0].wakeOnly)
        #expect(transcript.lines[0].mark == nil)
        #expect(transcript.lines[1].mark == .sent)
    }

    // MARK: - Cap

    @Test func keepsOnlyTheNewestLines() {
        var transcript = Transcript(maxLines: 3)
        for index in 1 ... 5 {
            said(&transcript, "SG_turn_\(index)", "Line \(index)", at: Double(index))
        }
        #expect(transcript.lines.map(\.text) == ["Line 3", "Line 4", "Line 5"])
        // A late update to a forgotten segment opens no new line.
        said(&transcript, "SG_turn_1", "Line 1 revised", at: 6)
        #expect(transcript.lines.map(\.text) == ["Line 3", "Line 4", "Line 5"])
        said(&transcript, "SG_turn_4", "Line 4 revised", at: 7)
        #expect(transcript.lines.map(\.text) == ["Line 3", "Line 4 revised", "Line 5"])
    }

    // MARK: - Stream order

    private enum StreamEvent: Sendable {
        case caption(segment: String, text: String, isFinal: Bool, fromCaller: Bool)
        case turn(TurnMessage)
        case reply(ReplyInfo)
    }

    /// Folds `arrivals` (each with the millisecond the worker sent it) in the order they reach the fold: through
    /// `StreamOrder` as the app does, or straight as they arrive.
    private func fold(_ arrivals: [(sentMs: Int, event: StreamEvent)], reordered: Bool) -> Transcript {
        let start = ContinuousClock.now
        var order = StreamOrder<StreamEvent>()
        var events: [StreamEvent] = []
        for (index, arrival) in arrivals.enumerated() {
            let sentAt = t0.addingTimeInterval(Double(arrival.sentMs) / 1000)
            if reordered {
                order.add(arrival.event, sentAt: sentAt, at: start + .milliseconds(index))
            } else {
                events.append(arrival.event)
            }
        }
        if reordered { events = order.release(at: start + .seconds(1)) }
        var transcript = Transcript()
        for event in events {
            switch event {
            case let .caption(segment, text, isFinal, fromCaller):
                transcript.caption(segment: segment, text: text, isFinal: isFinal, fromCaller: fromCaller, at: t0)
            case let .turn(message): transcript.apply(message, at: t0)
            case let .reply(info): transcript.apply(info, at: t0)
            }
        }
        return transcript
    }

    @Test func anOlderInterimFinishingLastDoesNotRevertTheLine() {
        let arrivals: [(sentMs: Int, event: StreamEvent)] = [
            (2, .caption(segment: "SG_turn_1", text: "Book a table", isFinal: false, fromCaller: true)),
            (1, .caption(segment: "SG_turn_1", text: "Book", isFinal: false, fromCaller: true)),
        ]
        #expect(fold(arrivals, reordered: false).lines.map(\.text) == ["Book"])
        #expect(fold(arrivals, reordered: true).lines.map(\.text) == ["Book a table"])
    }

    @Test func aCaptionFinishingBeforeItsReplyLabelStillTakesIt() {
        let arrivals: [(sentMs: Int, event: StreamEvent)] = [
            (1, .caption(segment: "SG_turn_1", text: "Book a table", isFinal: true, fromCaller: true)),
            (2, .turn(status(1, .sent, "Book a table"))),
            (4, .caption(segment: "SG_a", text: "Booked.", isFinal: true, fromCaller: false)),
            (3, .reply(ReplyInfo(reply: 1, turn: 1))),
        ]
        #expect(fold(arrivals, reordered: false).lines.last?.answers == nil)
        let transcript = fold(arrivals, reordered: true)
        #expect(transcript.lines.last?.text == "Booked.")
        #expect(transcript.lines.last?.answers == .turn(1, part: nil))
    }

    @Test func aStatusFinishingBeforeItsCaptionMarksThatCaption() {
        let arrivals: [(sentMs: Int, event: StreamEvent)] = [
            (2, .turn(status(1, .sent, "Hello there"))),
            (1, .caption(segment: "SG_turn_1", text: "Hello there", isFinal: true, fromCaller: true)),
        ]
        #expect(fold(arrivals, reordered: false).lines.count == 2)
        let transcript = fold(arrivals, reordered: true)
        #expect(transcript.lines.map(\.text) == ["Hello there"])
        #expect(transcript.lines[0].mark == .sent)
        #expect(transcript.lines[0].turn == 1)
    }

    // MARK: - Matching

    @Test func commandMatchingFollowsThePage() {
        #expect(Transcript.norm("Copy that, please!") == "copythatplease")
        #expect(Transcript.norm("Прийом.") == "прийом")
        #expect(Transcript.lineKey("Book a table. Zulu.") == "bookatable")
        #expect(Transcript.lineKey("Book a table zulu") == "bookatable")
        #expect(Transcript.lineKey("Discard this turn") == "")
        #expect(Transcript.isCommandOnly("Zulu."))
        #expect(Transcript.isCommandOnly("Прийом!"))
        #expect(!Transcript.isCommandOnly("Book a table"))
        #expect(!Transcript.isCommandOnly("..."))
        #expect(Transcript.spaceSentences("test.Please") == "test. Please")
        #expect(Transcript.spaceSentences("2!?Yes") == "2!? Yes")
        #expect(Transcript.spaceSentences("Mr.Smith") == "Mr. Smith")
        #expect(Transcript.spaceSentences("U.S. a.b") == "U.S. a.b")
    }

    @Test func copySendsOnlyAsItsOwnSentence() {
        #expect(Transcript.isCommandOnly("Copy."))
        #expect(Transcript.isCommandOnly("Copy that!"))
        #expect(Transcript.isCommandOnly(" copy that "))
        #expect(Transcript.lineKey("Book a table. Copy.") == "bookatable")
        #expect(Transcript.lineKey("Book a table! Copy that.") == "bookatable")
        #expect(Transcript.lineKey("Make a copy.") == "makeacopy")
        #expect(Transcript.lineKey("Book a table, copy that") == "bookatablecopythat")
        #expect(!Transcript.isCommandOnly("Copy the file."))
    }

    @Test func aSendWordAskedAsAQuestionStillSends() {
        for text in ["Zulu?", "Зулу?", "Прийом?", "Copy?", "Copy that?"] {
            #expect(Transcript.isCommandOnly(text))
        }
        #expect(Transcript.lineKey("Book a table. Copy?") == "bookatable")
        #expect(Transcript.lineKey("Make a copy?") == "makeacopy")
    }

    @Test func theOldSendWordsAreWords() {
        #expect(!Transcript.isCommandOnly("Send it."))
        #expect(!Transcript.isCommandOnly("Send."))
        #expect(!Transcript.isCommandOnly("Сендіт."))
        #expect(Transcript.lineKey("Book a table. Send it.") == "bookatablesendit")
    }

    // MARK: - Reading

    @Test func aTurnsPiecesReadAsOneBlock() {
        var transcript = Transcript()
        said(&transcript, "SG_1", "Book a table", at: 0)
        said(&transcript, "SG_2", "for two", at: 1)
        #expect(!transcript.continuesAbove(0))
        #expect(transcript.continuesAbove(1))
        transcript.apply(status(1, .sent, "Book a table for two"), at: at(2))
        #expect(transcript.continuesAbove(1))
        said(&transcript, "SG_3", "Thanks", at: 3)
        // An open line never carries on a sent turn.
        #expect(!transcript.continuesAbove(2))
        #expect(transcript.liveLineIDs == [transcript.lines[2].id])
        spoke(&transcript, "SG_a", "Done.", at: 4)
        #expect(!transcript.continuesAbove(3))
    }

    @Test func theNewestBlockAndReplyReadAsLive() {
        var transcript = Transcript()
        said(&transcript, "SG_1", "Book a table", at: 0)
        said(&transcript, "SG_2", "for two", at: 1)
        #expect(transcript.liveLineIDs == Set(transcript.lines.map(\.id)))
        transcript.apply(ReplyInfo(reply: 1, turn: 1), at: at(2))
        spoke(&transcript, "SG_a", "Booked.", at: 2)
        spoke(&transcript, "SG_b", "Seven tonight.", at: 3)
        transcript.apply(.unheard, at: at(4))
        // The note is not the newest line: the reply it follows still is, both of its lines.
        #expect(transcript.liveLineIDs == Set(transcript.lines[2...].map(\.id)))
    }

    @Test func aWakeLineStartsItsOwnBlock() {
        var transcript = Transcript()
        said(&transcript, "SG_1", "so anyway", at: 0)
        transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1), at: at(5))
        said(&transcript, "SG_2", "Hey Dan, book it", at: 5.1)
        #expect(transcript.lines[1].wake)
        #expect(!transcript.continuesAbove(1))
    }

    // MARK: - Command marks (a worker that announces its command words)

    private func marked(
        _ transcript: inout Transcript, _ segment: String, _ text: String, _ command: SpokenCommand?, final: Bool = false, at time: TimeInterval = 0
    ) {
        transcript.caption(segment: segment, text: text, isFinal: final, fromCaller: true, command: command, at: at(time))
    }

    @Test func aMarkedLineMatchesItsTurnByTheWordsBeforeTheCommand() {
        var transcript = Transcript()
        transcript.commandsAnnounced()
        // "over" is no built-in word: only the mark says where the words end.
        marked(&transcript, "SG_turn_1", "Book a table over", SpokenCommand(.send, words: "Book a table"))
        said(&transcript, "SG_turn_2", "And then", final: false)
        transcript.apply(status(1, .sent, "Book a table"), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.sent, nil])
    }

    @Test func anUnmarkedCaptionIsOnlyWordsOnceAnnounced() {
        var transcript = Transcript()
        transcript.commandsAnnounced()
        said(&transcript, "SG_turn_1", "Book a table zulu")
        said(&transcript, "SG_turn_2", "And then", final: false)
        transcript.apply(status(1, .sent, "Book a table"), at: at(1))
        // No word is matched: neither line holds the sent text, so the turn takes every open line.
        #expect(transcript.lines.map(\.mark) == [.sent, .sent])
    }

    @Test func anOldWorkersCaptionsAreMatchedOnTheBuiltInWords() {
        var transcript = Transcript()
        said(&transcript, "SG_turn_1", "Book a table zulu")
        said(&transcript, "SG_turn_2", "And then", final: false)
        transcript.apply(status(1, .sent, "Book a table"), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.sent, nil])
    }

    @Test func eachCaptionReplacesTheLinesMark() {
        var transcript = Transcript()
        transcript.commandsAnnounced()
        marked(&transcript, "SG_turn_1", "Send me a copy", SpokenCommand(.send, words: "Send me a"))
        #expect(transcript.lines[0].command == SpokenCommand(.send, words: "Send me a"))
        marked(&transcript, "SG_turn_1", "Send me a copy of it", nil)
        #expect(transcript.lines[0].command == nil)
        // The same words, newly marked, are an update too.
        marked(&transcript, "SG_turn_1", "Send me a copy of it", SpokenCommand(.discard, words: "Send me a copy of"))
        #expect(transcript.lines[0].command?.kind == .discard)
        #expect(transcript.lines.count == 1)
    }

    @Test func anAgentCaptionTakesNoMark() {
        var transcript = Transcript()
        transcript.caption(segment: "SA_1", text: "Copy.", isFinal: true, fromCaller: false, command: SpokenCommand(.send, words: ""), at: at(0))
        #expect(transcript.lines[0].command == nil)
    }

    @Test func aCommandDropMarksTheLineOfItsSegment() {
        var transcript = Transcript()
        transcript.commandsAnnounced()
        marked(&transcript, "SG_turn_1", "Belay.", SpokenCommand(.discard, words: ""), final: true)
        marked(&transcript, "SG_turn_2", "Over.", SpokenCommand(.send, words: ""), final: true)
        transcript.apply(.dropped(DroppedSpeech(.command, text: "Belay.", command: .discard, segment: "SG_turn_1")), at: at(1))
        #expect(transcript.lines.map(\.mark) == [.dropped(.command), nil])
        #expect(transcript.lines[0].command?.kind == .discard)
        // Without a segment: the newest open line the worker marked as a command alone.
        transcript.apply(.dropped(DroppedSpeech(.command, text: "Over.")), at: at(2))
        #expect(transcript.lines.map(\.mark) == [.dropped(.command), .dropped(.command)])
        #expect(transcript.lines[1].command?.kind == .send)
    }

    @Test func aStrayCommandDropIsLabelledFromWhatTheWorkerSaid() {
        var announced = Transcript()
        announced.commandsAnnounced()
        said(&announced, "SG_turn_1", "Scratch that.")
        announced.apply(.dropped(DroppedSpeech(.command, text: "Scratch that.")), at: at(1))
        #expect(announced.lines[0].mark == .dropped(.command))
        #expect(announced.lines[0].command?.kind == .send)

        var old = Transcript()
        said(&old, "SG_turn_1", "Scratch that.")
        old.apply(.dropped(DroppedSpeech(.command, text: "Scratch that")), at: at(1))
        #expect(old.lines[0].command?.kind == .discard)
    }

    @Test func aDiscardPhraseEndsTheLine() {
        #expect(Transcript.endsInDiscard("Scratch that."))
        #expect(Transcript.endsInDiscard("discard this turn"))
        #expect(!Transcript.endsInDiscard("Zulu."))
        #expect(!Transcript.endsInDiscard("Scratch that idea, book it"))
    }
}

import Foundation

/// Review mode (Manual) as nanoclaw's browser call page runs it (`review.ts`, `livekit-call.ts`): the caller taps
/// talk, speaks, taps done, reads the draft and sends or discards it. The worker owns the draft; the app shows its
/// newest state and asks for changes. Everything here is the synchronous half of the page's callbacks, so every state
/// can be tested; `CallController` does the RPCs and the microphone in between.
public struct Review: Sendable, Equatable {
    public enum Op: String, Sendable {
        case mode, talk, done, send, discard
    }

    /// The operation waiting for the worker's answer; `to` for a mode switch.
    public struct Pending: Sendable, Equatable {
        public let op: Op
        public let to: TurnMode?

        public init(_ op: Op, to: TurnMode? = nil) {
            self.op = op
            self.to = to
        }
    }

    /// A start or stop of the microphone that did not take.
    public enum MicError: Sendable, Equatable { case start, stop }

    /// The last sent draft's delivery: on its way, or confirmed.
    public enum Delivery: Sendable, Equatable { case sending, sent, lost }

    /// The mode in force: the caller's pick before a call, the worker's acknowledged one during it.
    public internal(set) var mode: TurnMode
    /// The worker offers review mode (before a call: assumed).
    public internal(set) var available = true
    public internal(set) var pending: Pending?
    public internal(set) var draft: Draft?
    public internal(set) var micError: MicError?
    /// A one-off line under the mode switch (or on the draft): why something did not happen, or what it found.
    public internal(set) var note: String?
    public internal(set) var delivery: Delivery?
    /// The call ended with this draft unsent: it stays readable until discarded.
    public internal(set) var ended = false
    /// The worker's transcription is getting ready after a draft: talk waits for it.
    public internal(set) var preparing = false

    public init(mode: TurnMode, available: Bool = true, draft: Draft? = nil, ended: Bool = false) {
        self.mode = mode
        self.available = available
        self.draft = draft
        self.ended = ended
    }

    /// How long a note stays.
    public static let noteDuration: Duration = .seconds(5)

    /// Review's keys and readout speak for the call: in review, or for a draft kept after it.
    public var isOn: Bool { mode == .review || (ended && draft != nil) }
}

/// What a CallKit mute action does to the call (`Review.callKitMute`).
public enum CallKitMute: String, Sendable {
    /// Fulfilled with nothing else to do.
    case acknowledge
    /// Failed: CallKit keeps showing the microphone as it was.
    case refuse
    /// Fulfilled once the microphone followed, failed when it could not.
    case apply
}

/// One call's review mode: the state the screen shows, the words being heard, and the page's bookkeeping. The words
/// are apart from `review` so a caption re-renders only the draft.
public struct ReviewSession: Sendable, Equatable {
    public private(set) var review: Review
    /// What the transcription shows of the open recording, not sent.
    public private(set) var words = ""
    /// The caller's pick: where every call starts, kept for the next one.
    public private(set) var pick: TurnMode
    /// The newest worker state taken; an older one arriving late is ignored.
    public private(set) var seq = 0
    /// The newest worker turn number seen, so a switch to review hears of a turn sent meanwhile.
    public private(set) var maxTurn = 0
    /// The caller muted by hand (the mute key, CallKit): back in hands-free the microphone stays muted.
    public var mutedByHand = false

    /// The reply to the operation in flight named this state; it ends once that state is here.
    private var awaitSeq: Int?
    /// Worker turns that are sent drafts, and the newest of them.
    private var reviewTurns: Set<Int> = []
    private var lastReviewTurn = 0
    /// Caption segments of review recordings: never the transcript's, whatever arrives for them later.
    private var reviewSegments: Set<String> = []
    /// The open recording's segments, in the order they came, as the transcription has them so far.
    private var heardOrder: [String] = []
    private var heard: [String: String] = [:]
    /// The recording each segment first showed up in: a late update to an older one is never heard now.
    private var segmentRecording: [String: Int] = [:]
    private var recordings = 0
    /// The call started in review: the worker is asked to switch once it offers it, unless the caller switched by
    /// hand first.
    private var startsInReview = false
    private var asked = false
    private var switchedByHand = false
    /// The initial switch went unanswered: the worker's next state says whether the microphone opens.
    private var initialSwitchUnanswered = false

    public init(pick: TurnMode) {
        self.pick = pick
        review = Review(mode: pick)
    }

    // MARK: - The call

    /// A new call starts from the caller's pick, with nothing of the last call but whether the line offered review.
    /// A draft kept from it is dropped: the caller chose to call again.
    public mutating func startCall() {
        self = ReviewSession(pick: pick)
        startsInReview = pick == .review
        // The worker starts hands-free: until it took the switch the screen says one is coming.
        if startsInReview { review.pending = Self.initialSwitch }
    }

    private static let initialSwitch = Review.Pending(.mode, to: .review)

    /// The call is over. Ended by the caller, a draft goes with it; otherwise a frozen one, or the words of an open
    /// recording (unverified), stay readable but are never sent into another call.
    public mutating func endCall(byCaller: Bool) {
        var kept: Draft?
        if !byCaller, var draft = review.draft {
            switch draft.state {
            case .ready, .failed: kept = draft
            case .recording, .finishing:
                let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    draft.state = .failed
                    draft.text = text
                    kept = draft
                }
            case .empty: break
            }
        }
        let available = review.available
        self = ReviewSession(pick: pick)
        review = Review(mode: pick, available: available, draft: kept, ended: kept != nil)
    }

    // MARK: - The worker

    /// The worker offers review mode.
    public mutating func offered() {
        review.available = true
    }

    /// The worker set no review attribute within its grace: it runs auto, whatever the pick. An offer that comes later
    /// still starts the switch. True when the microphone has to open: a call that started in Manual, with it closed
    /// waiting for the switch, now runs hands-free, unless the caller muted it by hand.
    @discardableResult
    public mutating func notOffered(micMuted: Bool) -> Bool {
        review.available = false
        guard startsInReview, !asked, review.pending == Self.initialSwitch else { return false }
        review.pending = nil
        review.mode = .auto
        review.note = "\(Review.modeName(.review)) isn't available on this line."
        return micMuted && !mutedByHand
    }

    /// The answer to the switch a call picked in Manual asked for. Refused, the call runs hands-free, so the
    /// microphone, closed waiting for the switch, has to open, unless the caller muted it by hand. Unanswered, the
    /// worker may have switched anyway: the state it sends next decides (`resyncedStateReopensMic`).
    public mutating func initialSwitchReopensMic(_ reply: ReviewReply?, micMuted: Bool) -> Bool {
        guard startsInReview, asked else { return false }
        guard let reply else {
            initialSwitchUnanswered = true
            return false
        }
        return !reply.ok && micMuted && !mutedByHand
    }

    /// After a state taken by `receive`: true when it is the first since the initial switch went unanswered and says
    /// the call runs hands-free, so the microphone has to open, unless the caller muted it by hand.
    public mutating func resyncedStateReopensMic(micMuted: Bool) -> Bool {
        guard initialSwitchUnanswered else { return false }
        initialSwitchUnanswered = false
        return review.mode == .auto && micMuted && !mutedByHand
    }

    /// Once the worker offers review, a call picked in review asks for it, once, unless the caller switched by hand
    /// meanwhile. True when it should ask now.
    public mutating func beginInitialSwitch() -> Bool {
        guard startsInReview, !asked, !switchedByHand, review.available,
              review.pending == nil || review.pending == Self.initialSwitch
        else { return false }
        asked = true
        review.pending = Review.Pending(.mode, to: .review)
        return true
    }

    /// The worker's newest state. Nil for one older than the newest taken; otherwise whether the microphone has to
    /// close: the worker stopped the recording (a reply took the channel), and the microphone follows it. An open auto
    /// turn switched to review moves its words from `transcript` into the draft: they were never sent.
    public mutating func receive(_ state: ReviewState, transcript: inout Transcript, micOn: Bool) -> Bool? {
        guard state.seq > seq else { return nil }
        seq = state.seq
        let previous = review
        let draft = state.draft
        if let draft, draft.id != previous.draft?.id, draft.reason == .switch {
            let moved = transcript.takeOpenCallerLines()
            for line in moved { reviewSegments.insert(line.segment) }
            // A segment that kept growing during the switch is already heard in full.
            let movedWords = moved.filter { heard[$0.segment] == nil }.map(\.text)
            words = (movedWords + heardOrder.compactMap { heard[$0] }).joined(separator: " ")
        }
        let done = awaitSeq.map { state.seq >= $0 } ?? false
        if done { awaitSeq = nil }
        review.mode = state.mode
        review.draft = draft
        review.preparing = state.preparing
        if done { review.pending = nil }
        // Already in review: the switch the call started waiting for is moot.
        if startsInReview, !asked, state.mode == .review, review.pending == Self.initialSwitch {
            asked = true
            review.pending = nil
        }
        return state.mode == .review && draft?.state != .recording && micOn && previous.pending?.op != .talk
    }

    /// A caller caption. True when it is review's (a recording's words, never the transcript's): heard only while a
    /// recording is open and only the newest recording's. `knownToTranscript`: the transcript already has its line.
    public mutating func caption(segment: String, text raw: String, knownToTranscript: Bool) -> Bool {
        let text = Transcript.spaceSentences(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard reviewSegments.contains(segment) || (review.mode == .review && !knownToTranscript)
            || review.pending?.to == .review
        else { return false }
        guard !text.isEmpty else { return true }
        reviewSegments.insert(segment)
        if segmentRecording[segment] == nil { segmentRecording[segment] = recordings }
        let state = review.draft?.state
        let open = state == .recording || state == .finishing || review.pending?.op == .talk || review.pending?.to == .review
        guard open, segmentRecording[segment] == recordings else { return true }
        if heard[segment] == nil { heardOrder.append(segment) }
        heard[segment] = text
        words = heardOrder.compactMap { heard[$0] }.joined(separator: " ")
        return true
    }

    /// A turn status from the worker: the newest turn number, and the delivery of the last sent draft.
    public mutating func turnStatus(_ status: TurnStatus) {
        guard status.status != .working else { return }
        maxTurn = max(maxTurn, status.turn)
        let fromDraft = status.status == .sending ? status.draft != nil : reviewTurns.contains(status.turn)
        guard fromDraft else { return }
        switch status.status {
        case .sending:
            guard let text = status.text, !text.isEmpty else { return }
            sent(turn: status.turn)
            review.delivery = .sending
        case .sent where status.turn == lastReviewTurn: review.delivery = .sent
        case .lost where status.turn == lastReviewTurn: review.delivery = .lost
        default: break
        }
    }

    // MARK: - The caller's operations

    /// Before or after a call: only the pick, kept for the next call. True when the pick changed.
    public mutating func pickMode(_ mode: TurnMode) -> Bool {
        guard !review.ended else { return false }
        review.mode = mode
        review.note = nil
        guard mode != pick else { return false }
        pick = mode
        return true
    }

    /// The worker took a switch: it is the pick for the next call too. True when the pick changed.
    public mutating func keepPick(_ mode: TurnMode) -> Bool {
        guard mode != pick else { return false }
        pick = mode
        return true
    }

    /// Mid-call switch: true when it may be asked for. Back to hands-free waits for the draft to be sent or discarded,
    /// and says so.
    public mutating func beginSwitch(to mode: TurnMode) -> Bool {
        guard review.pending == nil, review.mode != mode else { return false }
        if mode == .auto {
            if let block = Review.autoBlock(review.draft) {
                review.note = block
                return false
            }
        } else if !review.available {
            return false
        }
        review.pending = Review.Pending(.mode, to: mode)
        review.note = nil
        review.micError = nil
        switchedByHand = true
        return true
    }

    /// Talk: true when it may be asked for. A new recording's words start from nothing.
    public mutating func beginTalk() -> Bool {
        guard review.pending == nil, review.mode == .review else { return false }
        if let draft = review.draft, draft.state != .empty { return false }
        recordings += 1
        heard.removeAll()
        heardOrder.removeAll()
        words = ""
        review.pending = Review.Pending(.talk)
        review.note = nil
        review.micError = nil
        review.delivery = nil
        return true
    }

    /// Done: the recording's draft id, or nil when there is none to finish.
    public mutating func beginDone() -> Int? {
        guard review.pending == nil, let draft = review.draft, draft.state == .recording else { return nil }
        review.pending = Review.Pending(.done)
        return draft.id
    }

    /// Send: the draft id, or nil when it cannot go (not frozen, too long, the microphone still on, the call over).
    public mutating func beginSend() -> Int? {
        guard review.pending == nil, let draft = review.draft, draft.state == .ready, !draft.tooLong,
              review.micError != .stop, !review.ended
        else { return nil }
        review.pending = Review.Pending(.send)
        review.note = nil
        return draft.id
    }

    /// The worker posted the draft as turn `turn`.
    public mutating func sent(turn: Int) {
        reviewTurns.insert(turn)
        lastReviewTurn = max(lastReviewTurn, turn)
    }

    public enum DiscardStart: Sendable, Equatable {
        case none
        /// After the call only the app holds it: gone already.
        case local
        /// Ask the worker to drop draft `id`.
        case ask(Int)
    }

    public mutating func beginDiscard(live: Bool) -> DiscardStart {
        guard let draft = review.draft, review.pending == nil else { return .none }
        if review.ended || !live {
            review.draft = nil
            review.ended = false
            words = ""
            return .local
        }
        review.pending = Review.Pending(.discard)
        review.note = nil
        return .ask(draft.id)
    }

    public mutating func micFailed(_ error: Review.MicError) {
        review.micError = error
    }

    /// What settles with an operation besides it.
    public struct Outcome: Sendable, Equatable {
        public var delivery: Review.Delivery?
        public var note: String?
        public var mode: TurnMode?
        public var clearWords = false

        public init(delivery: Review.Delivery? = nil, note: String? = nil, mode: TurnMode? = nil, clearWords: Bool = false) {
            self.delivery = delivery
            self.note = note
            self.mode = mode
            self.clearWords = clearWords
        }
    }

    /// The worker's answer to the operation in flight, nil when it did not answer. Taken, the operation is over once
    /// the state its reply named is here (it may already be). True when the worker did not answer: it may have done it
    /// anyway, so its state has to be read again.
    public mutating func settle(_ reply: ReviewReply?, agentName: String, outcome: Outcome = Outcome()) -> Bool {
        defer {
            if let delivery = outcome.delivery { review.delivery = delivery }
            if let mode = outcome.mode { review.mode = mode }
            if outcome.clearWords { words = "" }
        }
        if let reply, reply.ok, reply.seq > seq {
            awaitSeq = reply.seq
            if let note = outcome.note { review.note = note }
            return false
        }
        awaitSeq = nil
        review.pending = nil
        if let reply, !reply.ok, let refused = Review.refusalNote(reply.error, agentName: agentName) { review.note = refused }
        if reply == nil { review.note = "The voice service did not answer - try again." }
        if let note = outcome.note { review.note = note }
        return reply == nil
    }

    /// A note goes after a while; a newer one stays.
    public mutating func noteExpired(_ note: String) {
        if review.note == note { review.note = nil }
    }
}

// MARK: - What the screen shows (the page's `reviewView`)

public extension Review {
    /// Turn modes as the page names them; the protocol keeps `auto` and `review`.
    static func modeName(_ mode: TurnMode) -> String {
        switch mode {
        case .auto: "hands-free"
        case .review: "Manual"
        }
    }

    /// What each mode does, in one line under the switch; `words` are the commands the worker understands.
    static func modeCaption(_ mode: TurnMode, commands: Bool, words: CommandWords, wake: Bool, pauseSends: Bool) -> String {
        if mode == .review { return "Tap talk, read your words, then send." }
        if !commands { return "Stop for a moment to send." }
        if wake, !pauseSends { return "Say \(words.sendHint) to send." }
        return "Stop for a moment, or say \(words.sendHint), to send."
    }

    /// Why the caller cannot leave review for hands-free right now, or nil when they can.
    static func autoBlock(_ draft: Draft?) -> String? {
        guard let draft else { return nil }
        switch draft.state {
        case .recording: return "Tap done, then send or discard."
        case .finishing: return "Finishing transcript."
        case .ready where !draft.tooLong: return "Send or discard before hands-free."
        default: return "Discard before hands-free."
        }
    }

    /// The worker's error for a refused operation, as the caller's next step; nil for one with nothing to do.
    static func refusalNote(_ error: String?, agentName: String) -> String? {
        switch error {
        case "recording": "Tap done, then send or discard."
        case "finishing": "Finishing transcript."
        case "draft_open": "Send or discard before hands-free."
        case "agent_speaking": "Tap talk when \(agentName) finishes."
        default: nil
        }
    }

    /// Whether a switch opens the microphone again: Manual keeps it off between recordings, so back in hands-free it
    /// listens once the worker took the switch, and a switch to Manual that did not happen gives back the microphone it
    /// closed. Never one the caller muted by hand.
    static func reopensMic(to mode: TurnMode, taken: Bool, muted: Bool, mutedByHand: Bool, openBefore: Bool) -> Bool {
        guard muted, !mutedByHand else { return false }
        return mode == .auto ? taken : !taken && openBefore
    }

    /// Manual opens the microphone only for a recording: an unmute from anywhere else (CallKit, AirPods) is refused.
    var holdsMicClosed: Bool {
        (mode == .review || pending?.to == .review) && draft?.state != .recording && pending?.op != .talk
    }

    /// What a CallKit mute action does. One the app asked for to show CallKit a microphone it moved itself is only
    /// acknowledged, so it never moves the microphone back (no loop). Any other is the caller's own (the key, the lock
    /// screen, AirPods) and the microphone follows it, except an unmute while Manual holds the microphone closed.
    func callKitMute(_ muted: Bool, reportedByApp: Bool) -> CallKitMute {
        if reportedByApp { return .acknowledge }
        return !muted && holdsMicClosed ? .refuse : .apply
    }

    /// How many characters a draft has to lose to fit the host's limit (0 when it fits).
    static func charsOver(_ text: String) -> Int {
        var bytes = text.utf8.count
        guard bytes > VoiceProtocol.maxTurnTextBytes else { return 0 }
        var count = 0
        for scalar in text.unicodeScalars.reversed() {
            guard bytes > VoiceProtocol.maxTurnTextBytes else { break }
            bytes -= String(scalar).utf8.count
            count += 1
        }
        return count
    }
}

/// Keys, readout and draft panel for a call in review mode (or switching to or from it), in the page's own words;
/// the app lowercases its chrome with `asWritten`.
public struct ReviewView: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle, connecting, listening, thinking, talking, ended, error

        var isLive: Bool { self == .listening || self == .thinking || self == .talking }
    }

    public enum Action: Sendable, Equatable { case call, cancel, end, discard, talk, done, send }

    public struct Key: Sendable, Equatable {
        public var label: String
        public var action: Action
        public var disabled: Bool

        public init(_ label: String, _ action: Action, disabled: Bool = false) {
            self.label = label
            self.action = action
            self.disabled = disabled
        }
    }

    public enum Tone: Sendable, Equatable { case none, idle, you, off, think, ended, error }

    public struct Panel: Sendable, Equatable {
        public enum Tone: Sendable, Equatable { case hearing, finishing, draft, empty, failed, long }
        /// The draft's lifecycle.
        public var title: String
        public var text: String
        public var tone: Tone
        /// Why it stopped, or that the text is unverified.
        public var note: String?
    }

    public var left: Key
    public var right: Key
    public var chip: String
    public var tone: Tone
    public var hint: String
    /// The right key's label row: the microphone's actual state.
    public var mic: String
    /// The microphone captures right now.
    public var capturing: Bool
    public var panel: Panel?
    /// The mode switch is off while an operation settles, the line reconnects or a transcript finishes.
    public var modeDisabled: Bool
    /// The call can end besides the two keys (the left one is Discard): ending drops the draft.
    public var endable: Bool

    /// The panel for a draft, or for the words being heard.
    private static func panel(_ review: Review, words: String, agentName: String) -> Panel? {
        guard let draft = review.draft else { return nil }
        let why = draft.reason == .agent ? "\(agentName) started speaking - review what was heard" : nil
        switch draft.state {
        case .recording: return Panel(title: "hearing - not sent", text: words, tone: .hearing)
        case .finishing: return Panel(title: "finishing transcript", text: words, tone: .finishing, note: why)
        case .empty: return Panel(title: "nothing heard", text: "", tone: .empty, note: why)
        case .failed: return Panel(title: "couldn't finish transcript", text: draft.text, tone: .failed, note: "unverified - not sendable")
        case .ready where draft.tooLong:
            let over = Review.charsOver(draft.text)
            return Panel(title: "draft too long", text: draft.text, tone: .long, note: over > 0 ? "about \(over) characters over the limit" : why)
        case .ready: return Panel(title: "draft - not sent", text: draft.text, tone: .draft, note: why)
        }
    }

    /// The caller's state first, then the overlays: the agent speaking or working, the worker getting ready, a switch
    /// in flight, microphone failures, a reconnect. `waited`: seconds the agent has been working.
    public init(phase: Phase, agentName: String, reconnecting: Bool, waited: Int, review: Review, words: String, micOn: Bool) {
        let draft = review.draft
        let panel = Self.panel(review, words: words, agentName: agentName)
        let pending = review.pending
        let sendable = draft.map { $0.state == .ready && !$0.tooLong } == true && review.micError != .stop

        guard phase.isLive else {
            let kept = draft != nil && review.ended
            left = phase == .connecting ? Key("Cancel", .cancel)
                : kept ? Key("Discard", .discard)
                : Key(phase == .ended || phase == .error ? "Call again" : "Call", .call)
            right = kept && draft?.state != .empty ? Key("Send", .send, disabled: true) : Key("Talk", .talk, disabled: true)
            chip = switch phase {
            case .connecting: "Connecting…"
            case .ended: "Call ended"
            case .error: ""
            default: "Ready"
            }
            tone = switch phase {
            case .ended: .ended
            case .error: .error
            case .idle: .idle
            default: .none
            }
            hint = kept ? "Draft not sent. Copy it, or discard it to call again."
                : phase == .connecting ? "Setting up the call."
                : phase == .idle ? "Call first, then tap talk."
                : ""
            mic = "Mic off"
            capturing = false
            self.panel = kept ? panel : nil
            modeDisabled = phase == .connecting || kept
            endable = false
            return
        }

        var left = Key("End", .end)
        var right = Key("Talk", .talk)
        var chip = "Mic muted"
        var tone = Tone.off
        var hint = "Tap talk to start."
        var mic = micOn ? "Mic on" : "Mic off"
        let capturing = draft?.state == .recording && micOn

        if pending?.op == .talk {
            right = Key("Talk", .talk, disabled: true)
            chip = "Starting mic"
            hint = "Wait before speaking."
            mic = "Starting mic"
        } else if pending?.op == .discard {
            left = Key("Discard", .discard, disabled: true)
            right = Key("Talk", .talk, disabled: true)
            chip = "Discarding"
            hint = "Mic off - please wait."
        } else if pending?.op == .send {
            right = Key("Talk", .talk, disabled: true)
            chip = "Sending"
            hint = "Mic off - waiting for confirmation."
        } else if let draft {
            switch draft.state {
            case .recording:
                right = Key("Done", .done, disabled: pending?.op == .done)
                chip = "Listening"
                tone = .you
                hint = "Pausing won't send - tap done to read it."
                mic = micOn ? "Recording" : pending?.op == .done ? "Stopping mic" : "Mic off"
            case .finishing:
                left = Key("Discard", .discard)
                right = Key("Send", .send, disabled: true)
                chip = "Finishing transcript"
                hint = "Mic off - nothing sent."
            case .empty:
                left = Key("Discard", .discard)
                chip = "Nothing heard"
                hint = "Nothing heard - tap talk to retry."
            case .failed:
                left = Key("Discard", .discard)
                right = Key("Send", .send, disabled: true)
                chip = "Transcript failed"
                tone = .error
                hint = "Couldn't finish transcript - discard and try again."
            case .ready where draft.tooLong:
                left = Key("Discard", .discard)
                right = Key("Send", .send, disabled: true)
                chip = "Draft too long"
                tone = .error
                hint = "Discard and try a shorter turn."
            case .ready:
                left = Key("Discard", .discard)
                right = Key("Send", .send, disabled: !sendable)
                chip = "Review draft"
                hint = "Check the words, then send."
            }
        } else if review.delivery == .sending {
            chip = "Sending"
            hint = "Mic off - waiting for confirmation."
        } else if review.delivery == .sent {
            hint = "Sent - tap talk for another turn."
        }

        // The agent's activity: its own chip, and talk waits for its speech to end.
        if phase == .talking {
            chip = "\(agentName) is speaking"
            tone = .none
            if right.action == .talk { right.disabled = true }
            if draft == nil || draft?.state == .empty {
                hint = "Tap talk when \(agentName) finishes."
            } else if sendable {
                hint = "You can send it now; \(agentName) gets it next."
            }
        } else if phase == .thinking {
            chip = "\(agentName) is working"
            tone = .think
            if draft == nil, pending == nil {
                hint = "Tap talk to add more · waiting \(waited / 60):\(String(format: "%02d", waited % 60))"
            } else if draft?.state == .recording {
                hint = "Recording - tap done to read it."
            } else if sendable {
                hint = "You can send it now; \(agentName) gets it next."
            }
        }

        // The worker restarts its transcription after a draft; talk opens once it takes audio again.
        if review.preparing, right.action == .talk, pending == nil {
            right.disabled = true
            if phase == .listening {
                chip = "Getting ready"
                tone = .none
                hint = "Talk opens in a moment."
            } else if phase == .thinking {
                hint = "Talk opens in a moment."
            }
        }

        // A switch in flight: the last acknowledged mode stays, nothing else can start.
        if pending?.op == .mode {
            chip = "Switching to \(Review.modeName(pending?.to ?? .auto))"
            tone = .none
            left = draft != nil ? Key("Discard", .discard, disabled: true) : Key("End", .end)
            right.disabled = true
            hint = micOn ? "Please wait." : "Mic off - please wait."
        }

        // The microphone did not do what was asked: say so, never claim it is off.
        if review.micError == .start {
            hint = "Mic didn't start - tap talk to retry."
            mic = "Mic off"
        } else if review.micError == .stop {
            hint = "Mic couldn't stop - end call to stop capture."
            mic = "Mic still on"
            if right.action == .send { right.disabled = true }
        }

        if reconnecting {
            chip = "Reconnecting…"
            tone = .none
            hint = "Wait before speaking."
            left = draft != nil ? Key("Discard", .discard, disabled: true) : Key("End", .end)
            right.disabled = true
        }

        self.left = left
        self.right = right
        self.chip = chip
        self.tone = tone
        self.hint = hint
        self.mic = mic
        self.capturing = capturing
        self.panel = panel
        modeDisabled = reconnecting || pending != nil || draft?.state == .finishing
        endable = left.action != .end
    }

    /// A key that just changed what it does ignores taps this long.
    public static let rearm: Duration = .milliseconds(500)

    /// What a key does, for the re-arm guard (a key that just changed what it does ignores taps for a moment): every
    /// hang-up is one thing, so the end key never fades when it keeps ending the call; any other key is its action on
    /// its draft, so a double tap on discard cannot end the call.
    public static func keyIdentity(_ action: Action?, draft: Int?) -> String {
        switch action {
        case .cancel, .end: "hangup"
        case nil: "none"
        case let action?: "\(action):\(draft.map(String.init) ?? "")"
        }
    }
}

/// The page's chrome is lowercase, but some words stay as written (`Manual`, the wake phrase): `text` lowercased
/// except where one of `keep` occurs.
public func asWritten(_ text: String, keep: [String]) -> String {
    let words = keep.filter { !$0.isEmpty }
    var out = ""
    var rest = Substring(text)
    while !rest.isEmpty {
        // The earliest kept word, the longest of those starting there.
        var next: Range<Substring.Index>?
        for word in words {
            guard let found = rest.range(of: word) else { continue }
            if let best = next, best.lowerBound < found.lowerBound || (best.lowerBound == found.lowerBound && best.upperBound >= found.upperBound) {
                continue
            }
            next = found
        }
        guard let next else { break }
        out += rest[..<next.lowerBound].lowercased()
        out += rest[next]
        rest = rest[next.upperBound...]
    }
    return out + rest.lowercased()
}

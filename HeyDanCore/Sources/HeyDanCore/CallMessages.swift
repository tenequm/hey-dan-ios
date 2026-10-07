import Foundation

/// The worker's in-call messages, as nanoclaw's `src/channels/voice-livekit-protocol.ts` defines them and its
/// browser call page reads them. A shape or value this app does not know is ignored, as the page ignores it.
public extension VoiceProtocol {
    /// Captions of both sides, as LiveKit text streams: the caller's per turn segment, interim then final; the
    /// agent's one final per spoken line.
    static let transcriptionTopic = "lk.transcription"
    static let segmentIDAttribute = "lk.segment_id"
    static let transcriptionFinalAttribute = "lk.transcription_final"
    static let transcribedTrackAttribute = "lk.transcribed_track_id"
    /// `TurnMessage`s: what became of each caller turn, words the worker dropped, speech it did not hear.
    static let turnTopic = "nanoclaw.voice.turn"
    /// One `ReplyInfo` right before each line the worker speaks, and again after one it could not.
    static let replyTopic = "nanoclaw.voice.reply"
    /// One `ReviewState` whenever the worker's turn state (auto mode's wake state included) changes.
    static let reviewTopic = "nanoclaw.voice.review"
    static let streamTopics = [transcriptionTopic, turnTopic, replyTopic, reviewTopic]

    /// One of `commandsVersions` when the worker understands spoken commands and the settings RPC; any other value
    /// (or none) is a vocabulary this app does not know, so it offers no commands. "3" only marks a worker that also
    /// drops "send it", which this app never offered, so both read the same here.
    static let commandsAttribute = "nanoclaw.voice.commands"
    static let commandsVersions: Set<String> = ["2", "3"]
    /// The spoken commands the worker understands (`CommandWords`), set with `commandsAttribute`.
    static let commandWordsAttribute = "nanoclaw.voice.command-words"
    /// On a caller caption, both or neither: the command its text ends in (`send`, `discard`), and the words before it.
    static let captionCommandAttribute = "nanoclaw.voice.command"
    static let captionWordsAttribute = "nanoclaw.voice.words"
    /// Takes a `SettingsRequest` from the caller only, answers a `ReviewReply`.
    static let settingsMethod = "nanoclaw.voice.settings"
    /// A `mode` request naming no mode only makes the worker send its `ReviewState` again.
    static let modeMethod = "nanoclaw.voice.mode"
    static let rpcTimeout: TimeInterval = 10
    /// LiveKit's own wait for an RPC's ack (`maxRoundTripLatency`): an RPC whose ack comes later fails, though the
    /// worker may have got and applied it.
    static let rpcAckTimeout: TimeInterval = 7
    /// The ack wait of a call's first settings send only. That request can be lost outright (RpcError 1501 after
    /// `rpcAckTimeout`), and its resend arrives within milliseconds.
    static let firstSettingsAckTimeout: TimeInterval = 0.75
    /// Sends of one settings request, the first included. Settings are safe to send twice: the worker applies every
    /// request it gets, and a resend carries the same picks.
    static let settingsAttempts = 3

    /// The ack wait of a call's `send`th settings send (1: its first). Every other send waits LiveKit's default:
    /// cut short, a slow ack would fail a request the worker took.
    static func settingsAckTimeout(send: Int) -> TimeInterval {
        send == 1 ? firstSettingsAckTimeout : rpcAckTimeout
    }
    /// "1" when the worker runs review mode (Manual); the app offers it only then.
    static let reviewAttribute = "nanoclaw.voice.review"
    /// A worker sets its attributes right after its session starts, an older one in more than one go; without them
    /// after this long it has none. An offer that comes later still counts.
    static let agentAttributeGrace: Duration = .seconds(8)
    /// The host takes a caller turn of at most this many UTF-8 bytes; a longer review draft cannot be sent.
    static let maxTurnTextBytes = 8 * 1024
    /// Handlers of streams sent back to back finish within milliseconds of each other: this bounds that skew with
    /// room to spare and stays below what a reader of the captions notices.
    static let streamOrderHold: Duration = .milliseconds(100)
}

/// A message on the turn topic: one of three shapes, told apart by their fields.
public enum TurnMessage: Sendable, Equatable {
    case status(TurnStatus)
    case dropped(DroppedSpeech)
    /// The caller spoke while the agent's line played; none of it was transcribed.
    case unheard

    /// Nil for anything that is none of the three, or a status or drop kind this app does not know.
    public init?(json: Data) {
        let decoder = JSONDecoder()
        if let unheard = try? decoder.decode(Unheard.self, from: json), unheard.unheard == "agent_speaking" {
            self = .unheard
        } else if let dropped = try? decoder.decode(DroppedSpeech.self, from: json) {
            self = .dropped(dropped)
        } else if let status = try? decoder.decode(TurnStatus.self, from: json) {
            self = .status(status)
        } else {
            return nil
        }
    }

    private struct Unheard: Decodable {
        let unheard: String
    }
}

/// What became of caller turn `turn` (the worker's number, which counts noises too).
public struct TurnStatus: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Closed and on its way to the host; an auto turn shows no mark for it.
        case sending
        case sent
        /// The agent's runner picked it up; the page shows nothing for it.
        case working
        case lost
    }

    public enum Reason: String, Codable, Sendable {
        case stt, rejected, timeout, empty
        case rateLimited = "rate_limited"
    }

    public let turn: Int
    public let status: Status
    /// Why a turn was lost; nil when none was given or this app does not know it.
    public let reason: Reason?
    /// The final transcript, when there is one.
    public let text: String?
    /// On a sent review draft's `sending`: its draft id.
    public let draft: Int?

    public init(turn: Int, status: Status, reason: Reason? = nil, text: String? = nil, draft: Int? = nil) {
        self.turn = turn
        self.status = status
        self.reason = reason
        self.text = text
        self.draft = draft
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turn = try container.decode(Int.self, forKey: .turn)
        status = try container.decode(Status.self, forKey: .status)
        reason = try container.decodeIfPresent(String.self, forKey: .reason).flatMap(Reason.init(rawValue:))
        text = try container.decodeIfPresent(String.self, forKey: .text)
        draft = try container.decodeIfPresent(Int.self, forKey: .draft)
    }
}

/// Caller words the worker will never send; `text` is what was heard.
public struct DroppedSpeech: Decodable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A spoken discard.
        case discarded
        /// Heard while the wake switch waits for the wake phrase.
        case unaddressed
        /// A send word or discard phrase said alone, with nothing open to act on.
        case command
        /// A turn the wake phrase opened that heard nothing more for too long.
        case asleep
    }

    public let dropped: Kind
    public let text: String
    /// On a `command` drop: which command had nothing to act on. Nil from an older worker, or one this app does not know.
    public let command: CommandKind?
    /// On a `command` drop: the caption segment the command was said in.
    public let segment: String?

    public init(_ dropped: Kind, text: String, command: CommandKind? = nil, segment: String? = nil) {
        self.dropped = dropped
        self.text = text
        self.command = command
        self.segment = segment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dropped = try container.decode(Kind.self, forKey: .dropped)
        text = try container.decode(String.self, forKey: .text)
        command = try container.decodeIfPresent(String.self, forKey: .command).flatMap(CommandKind.init(rawValue:))
        segment = try container.decodeIfPresent(String.self, forKey: .segment).flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case dropped, text, command, segment
    }
}

public enum CommandKind: String, Sendable, Equatable {
    case send, discard
}

/// The command a caller caption ends in, as the worker marked it: one it would act on if the caller stopped now
/// (interim), or the one the turn ended on (final).
public struct SpokenCommand: Sendable, Equatable {
    public let kind: CommandKind
    /// The caption's text before the command; empty when the command was said alone.
    public let words: String

    public init(_ kind: CommandKind, words: String) {
        self.kind = kind
        self.words = words
    }

    /// From a caption stream's attributes; nil when it carries no mark, half of one, or a command this app does not know.
    public init?(captionAttributes attributes: [String: String]) {
        guard let kind = attributes[VoiceProtocol.captionCommandAttribute].flatMap(CommandKind.init(rawValue:)),
              let words = attributes[VoiceProtocol.captionWordsAttribute]
        else { return nil }
        self.init(kind, words: words)
    }
}

/// The spoken commands, in the order the caller is shown them: the worker's own, as it announces them
/// (`VoiceProtocol.commandWordsAttribute`), or the built-in ones until it does (an older worker never does).
public struct CommandWords: Sendable, Equatable {
    public struct Word: Sendable, Equatable, Decodable {
        /// As the caller is shown it, quoted verbatim.
        public let say: String
        /// Counts only as its own sentence: "Make a copy." is words.
        public let ownSentence: Bool
        /// Short hints quote it.
        public let hint: Bool

        public init(_ say: String, ownSentence: Bool = false, hint: Bool = false) {
            self.say = say
            self.ownSentence = ownSentence
            self.hint = hint
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            say = try container.decode(String.self, forKey: .say).trimmingCharacters(in: .whitespacesAndNewlines)
            ownSentence = try container.decodeIfPresent(Bool.self, forKey: .ownSentence) ?? false
            hint = try container.decodeIfPresent(Bool.self, forKey: .hint) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case say, ownSentence, hint
        }
    }

    public let send: [Word]
    public let discard: [Word]

    public init(send: [Word], discard: [Word]) {
        self.send = send
        self.discard = discard
    }

    /// What a worker that announces nothing is taken to understand.
    public static let builtIn = CommandWords(
        send: [Word("zulu", hint: true), Word("copy", ownSentence: true, hint: true), Word("copy that", ownSentence: true), Word("прийом")],
        discard: [Word("scratch that", hint: true), Word("discard turn"), Word("discard this turn")]
    )

    /// The announcement's version this app reads; any other is no announcement.
    static let version = 1

    /// Nil for anything but a valid announcement: no attribute, another version, unparsable JSON, or no send words.
    public init?(attribute: String?) {
        guard let attribute, let announced = try? JSONDecoder().decode(Announcement.self, from: Data(attribute.utf8)),
              announced.v == Self.version
        else { return nil }
        let send = announced.send.filter { !$0.say.isEmpty }
        guard !send.isEmpty else { return nil }
        self.init(send: send, discard: (announced.discard ?? []).filter { !$0.say.isEmpty })
    }

    private struct Announcement: Decodable {
        let v: Int
        let send: [Word]
        let discard: [Word]?
    }

    /// The words short hints quote: the flagged ones in order, else the first.
    public var sendHints: [String] { Self.hints(send) }
    public var discardHints: [String] { Self.hints(discard) }

    /// `"zulu" or "copy"`: the send words short hints quote.
    public var sendHint: String { Self.join(sendHints) }

    /// The voice commands panel's line: every send word, and the discard words short hints quote.
    public var explainer: String {
        let send = "say \(Self.join(self.send.map(\.say))) to send now"
        return discard.isEmpty ? "\(send)." : "\(send), \(Self.join(discardHints)) to drop it."
    }

    /// `"a"`, `"a" or "b"`, `"a", "b" or "c"`; unquoted, for VoiceOver.
    public static func join(_ words: [String], quoted: Bool = true) -> String {
        let shown = quoted ? words.map { "\"\($0)\"" } : words
        guard let last = shown.last else { return "" }
        let rest = shown.dropLast()
        return rest.isEmpty ? last : "\(rest.joined(separator: ", ")) or \(last)"
    }

    private static func hints(_ words: [Word]) -> [String] {
        let flagged = words.filter(\.hint)
        return (flagged.isEmpty ? Array(words.prefix(1)) : flagged).map(\.say)
    }
}

/// What the next spoken line answers: caller turn `turn` (the worker's number), no turn (`unprompted`), or the
/// worker's own `notice`. With `unspoken`, sent after the line: it could not be synthesized, `text` is what it said.
public struct ReplyInfo: Codable, Sendable, Equatable {
    public let reply: Int
    public let turn: Int?
    public let unprompted: Bool?
    public let notice: Bool?
    /// Counts the messages answering that turn so far.
    public let part: Int?
    /// Another line is already queued behind this one.
    public let more: Bool?
    public let unspoken: Bool?
    public let text: String?

    public init(
        reply: Int, turn: Int? = nil, unprompted: Bool? = nil, notice: Bool? = nil, part: Int? = nil,
        more: Bool? = nil, unspoken: Bool? = nil, text: String? = nil
    ) {
        self.reply = reply
        self.turn = turn
        self.unprompted = unprompted
        self.notice = notice
        self.part = part
        self.more = more
        self.unspoken = unspoken
        self.text = text
    }
}

/// The worker's turn state: the mode, review mode's draft and auto mode's wake switch. `seq` grows with every
/// change, the newest wins.
public struct ReviewState: Decodable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// Hands-free: a pause or a spoken command sends the turn.
        case auto
        /// Manual: talk, done, then send or discard the draft.
        case review
    }

    public let seq: Int
    public let mode: Mode
    public let draft: Draft?
    /// Talk is setting up the recording's transcription: talk stays off meanwhile. Absent from an older worker.
    public let preparing: Bool
    /// Auto mode's wake switch, from a worker that understands spoken commands.
    public let wake: WakeState?

    public init(seq: Int, mode: Mode, draft: Draft? = nil, preparing: Bool = false, wake: WakeState? = nil) {
        self.seq = seq
        self.mode = mode
        self.draft = draft
        self.preparing = preparing
        self.wake = wake
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        mode = try container.decode(Mode.self, forKey: .mode)
        draft = try container.decodeIfPresent(Draft.self, forKey: .draft)
        preparing = try container.decodeIfPresent(Bool.self, forKey: .preparing) ?? false
        wake = try container.decodeIfPresent(WakeState.self, forKey: .wake)
    }

    private enum CodingKeys: String, CodingKey {
        case seq, mode, draft, preparing, wake
    }
}

public typealias TurnMode = ReviewState.Mode

/// One review turn as the worker holds it: `recording` from talk to done, `finishing` while the transcription is
/// flushed, then frozen: `ready` to send, `empty` (nothing heard) or `failed` (`text` unverified).
public struct Draft: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable {
        case recording, finishing, ready, empty, failed
    }

    /// Why it stopped without done.
    public enum Reason: String, Decodable, Sendable {
        /// A reply took the channel.
        case agent
        /// An open auto turn the caller switched to review.
        case `switch`
    }

    public let id: Int
    public var state: State
    public var text: String
    /// Over `VoiceProtocol.maxTurnTextBytes`: it cannot be sent.
    public var tooLong: Bool
    /// Nil when none was given or this app does not know it.
    public var reason: Reason?

    public init(id: Int, state: State, text: String = "", tooLong: Bool = false, reason: Reason? = nil) {
        self.id = id
        self.state = state
        self.text = text
        self.tooLong = tooLong
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        state = try container.decode(State.self, forKey: .state)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        tooLong = try container.decodeIfPresent(Bool.self, forKey: .tooLong) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason).flatMap(Reason.init(rawValue:))
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, text, tooLong, reason
    }
}

/// Auto mode's wake switch as the worker runs it.
public struct WakeState: Decodable, Sendable, Equatable {
    /// Nothing is kept or sent until the wake phrase.
    public let on: Bool
    /// After the wake phrase a pause sends too, not only a send word.
    public let pauseSends: Bool
    /// Waiting for the wake phrase right now.
    public let waiting: Bool
    /// The acoustic wake word's phrase (`Hey LiveKit`); nil when `hey <agent>` in the transcript opens a turn.
    public let phrase: String?
    /// How many times this call the wake phrase opened a turn.
    public let heard: Int?
    /// How many times this call an open turn went back to waiting.
    public let slept: Int?
    /// The last wake was the acoustic one: the turn's transcript starts after the phrase.
    public let cut: Bool?

    public init(
        on: Bool, pauseSends: Bool, waiting: Bool, phrase: String? = nil, heard: Int? = nil, slept: Int? = nil,
        cut: Bool? = nil
    ) {
        self.on = on
        self.pauseSends = pauseSends
        self.waiting = waiting
        self.phrase = phrase
        self.heard = heard
        self.slept = slept
        self.cut = cut
    }
}

/// The `settings` RPC's payload; `gen` is the app's own operation counter, echoed back.
public struct SettingsRequest: Encodable, Sendable, Equatable {
    public let gen: Int
    public let wake: Bool
    public let pauseSends: Bool
    public let cues: Bool
    public let typing: Bool

    public init(gen: Int, picks: SettingsPicks, cues: Bool = true) {
        self.gen = gen
        wake = picks.wake
        pauseSends = picks.pauseSends
        self.cues = cues
        typing = picks.typing
    }

    public var payload: String { rpcPayload(self) }
}

/// A review RPC's payload (`mode`, `talk`, `done`, `send`, `discard`); `gen` is the app's own operation counter,
/// echoed back, and `draft` names the draft an operation is for.
public struct ReviewRequest: Encodable, Sendable, Equatable {
    public let gen: Int
    public let draft: Int?
    /// For `mode`: the mode to switch to; nil, the worker only sends its state again.
    public let mode: TurnMode?
    /// With `mode`: the newest worker turn number seen, to hear of a turn auto mode sent meanwhile.
    public let afterTurn: Int?

    public init(gen: Int, draft: Int? = nil, mode: TurnMode? = nil, afterTurn: Int? = nil) {
        self.gen = gen
        self.draft = draft
        self.mode = mode
        self.afterTurn = afterTurn
    }

    public var payload: String { rpcPayload(self) }
}

/// An RPC payload as the worker reads it: JSON with sorted keys.
private func rpcPayload(_ request: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: (try? encoder.encode(request)) ?? Data("{}".utf8), as: UTF8.self)
}

/// The worker's answer to a review or settings RPC; `seq` is the `ReviewState` that shows what it did.
public struct ReviewReply: Decodable, Sendable, Equatable {
    public let gen: Int
    public let ok: Bool
    public let seq: Int
    /// The draft `talk` opened.
    public let draft: Int?
    /// The turn number a sent draft got.
    public let turn: Int?
    /// On a switch to review: a turn auto mode had already sent after `afterTurn`.
    public let submitted: Int?
    /// Why nothing happened: `stale`, `recording`, `finishing`, `draft_open`, `agent_speaking`, `not_review`,
    /// `unsendable`, `closed`.
    public let error: String?

    /// Nil when the payload is not a reply.
    public init?(payload: String) {
        guard let reply = try? JSONDecoder().decode(Self.self, from: Data(payload.utf8)) else { return nil }
        self = reply
    }
}

/// The caller's own picks for auto mode's commands and the typing sound, kept for the next call.
public struct SettingsPicks: Codable, Sendable, Equatable {
    public var wake: Bool
    public var pauseSends: Bool
    public var typing: Bool

    /// A caller with nothing remembered, and what a worker runs before it is told: wake switch and typing on.
    public static let defaults = SettingsPicks(wake: true, pauseSends: false, typing: true)

    public init(wake: Bool, pauseSends: Bool, typing: Bool) {
        self.wake = wake
        self.pauseSends = pauseSends
        self.typing = typing
    }
}

/// Auto mode's spoken-command settings during a call: the wake switch as the worker last said it runs it (or as
/// asked, until it says), and the sound switches as it last took them (as asked, after a request it never
/// acknowledged: no state shows them).
public struct CommandSettings: Sendable, Equatable {
    public var wake: Bool
    public var pauseSends: Bool
    /// The worker waits for the wake phrase right now: nothing said is kept until it hears it.
    public var waiting: Bool
    /// The acoustic wake word's phrase; nil: `Hey <agent>`.
    public var phrase: String?
    public var cues: Bool
    public var typing: Bool

    public init(picks: SettingsPicks, cues: Bool = true) {
        wake = picks.wake
        pauseSends = picks.pauseSends
        waiting = false
        phrase = nil
        self.cues = cues
        typing = picks.typing
    }

    /// The worker's newest wake state.
    public mutating func apply(_ state: WakeState) {
        wake = state.on
        pauseSends = state.pauseSends
        waiting = state.on && state.waiting
        phrase = state.phrase
    }

    /// The worker refused a request, or answered nothing at all: back to what it runs, or to what a worker starts
    /// with before it said.
    public mutating func revert(running: WakeState?, taken: SettingsPicks) {
        wake = running?.on ?? SettingsPicks.defaults.wake
        pauseSends = running?.pauseSends ?? SettingsPicks.defaults.pauseSends
        typing = taken.typing
    }
}

/// The worker's stream events back in the order it sent them. LiveKit runs each incoming stream's handler as its own
/// task, so two streams sent back to back can finish in either order; the fold above depends on their order. The
/// worker sends one stream at a time and every header carries its open time (milliseconds), so an event is held for
/// `VoiceProtocol.streamOrderHold` after it arrives and released only once no earlier-sent event is still held.
/// Events sent in the same millisecond keep their arrival order.
public struct StreamOrder<Event: Sendable>: Sendable {
    private struct Held: Sendable {
        let sentAt: Date
        let due: ContinuousClock.Instant
        let event: Event
    }

    private let hold: Duration
    private var held: [Held] = []

    public init(hold: Duration = VoiceProtocol.streamOrderHold) {
        self.hold = hold
    }

    /// When `release` next has something to give, nil while nothing is held.
    public var nextDue: ContinuousClock.Instant? { held.first?.due }

    public mutating func add(_ event: Event, sentAt: Date, at now: ContinuousClock.Instant) {
        let entry = Held(sentAt: sentAt, due: now + hold, event: event)
        let index = held.lastIndex { $0.sentAt <= sentAt }.map { $0 + 1 } ?? 0
        held.insert(entry, at: index)
    }

    /// The events whose hold is over at `now`, in sending order. An event still held blocks every one sent after it.
    public mutating func release(at now: ContinuousClock.Instant) -> [Event] {
        let count = held.prefix { $0.due <= now }.count
        defer { held.removeFirst(count) }
        return held.prefix(count).map(\.event)
    }

    /// Everything still held, in sending order: the call is over and nothing earlier can come.
    public mutating func drain() -> [Event] {
        defer { held.removeAll() }
        return held.map(\.event)
    }
}

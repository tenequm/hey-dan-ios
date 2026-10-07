import Foundation

/// A call's live transcript: caption segments, turn statuses, dropped words and reply labels folded into
/// ordered lines the way nanoclaw's browser call page folds them (`livekit-call.ts`: the captions effect,
/// `applyTurn`, `applyDropped`, `showUnspoken`, the wake marks). A review draft shows here only once it is sent;
/// the words of a recording are `ReviewSession`'s.
public struct Transcript: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public enum Speaker: Sendable, Equatable {
            case caller, agent
        }

        public enum Kind: Sendable, Equatable {
            case caption
            /// Not a caption: the caller spoke over the agent's line and none of it was heard. `text` is empty.
            case unheard
        }

        public let id: Int
        public let speaker: Speaker
        public let kind: Kind
        public internal(set) var text: String
        /// When the line started.
        public let at: Date
        /// False while the transcription may still revise a caller line; agent lines are always final.
        public internal(set) var isFinal: Bool
        /// What became of the caller turn this line belongs to; nil while it is open.
        public internal(set) var mark: Mark?
        /// The caller turn's number as the transcript counts them (from 1, noises not counted).
        public internal(set) var turn: Int?
        /// The spoken message an agent line belongs to: one message's lines read as one.
        public internal(set) var reply: Int?
        /// What an agent message answers, on its first line only.
        public internal(set) var answers: ReplyLabel?
        /// The worker heard the wake phrase as this caller line was spoken (or just before it).
        public internal(set) var wake = false
        /// The line is the wake phrase alone: no part of any turn, never marked.
        public internal(set) var wakeOnly = false
        /// The line opens with words said before the wake phrase, which the worker ignored.
        public internal(set) var preWake = false
        /// An agent line the worker could not speak: its text, shown instead of heard.
        public internal(set) var unspoken = false
        /// A caller line: the command its newest caption ends in, as the worker marked it; on a command drop, the
        /// command that had nothing to act on.
        public internal(set) var command: SpokenCommand?
    }

    public enum Mark: Sendable, Equatable {
        /// A sent review draft on its way, before the host answers.
        case sending
        case sent
        case lost(TurnStatus.Reason?)
        case dropped(DroppedSpeech.Kind)
    }

    public enum ReplyLabel: Sendable, Equatable {
        /// Answers the transcript's turn `turn`; `part` from the second message answering it on.
        case turn(Int, part: Int?)
        case unprompted
    }

    /// A caption line whose final never came stops reading as interim after this long unchanged.
    public static let interimStale: TimeInterval = 5
    /// A wake heard this soon after the caller's newest line changed belongs to that line.
    public static let wakeLineWindow: TimeInterval = 1.5
    /// The line that last got new words reads as still streaming for this long.
    public static let streamingWindow: TimeInterval = 0.7

    public private(set) var lines: [Line] = []
    /// The line that last got new words, and when.
    public private(set) var streamingLineID: Int?
    public private(set) var lastDeltaAt: Date?
    /// The worker announced its command words, so it marks the captions that hold one: no words are matched here.
    public private(set) var marksCommands = false

    private let maxLines: Int
    private var nextID = 1
    private var segmentLine: [String: Int] = [:]
    private var segmentText: [String: String] = [:]
    private var interimSegments: [String: Date] = [:]
    private var finalSegments: Set<String> = []
    /// Caller lines a turn status or a drop already claimed.
    private var covered: Set<Int> = []
    /// The worker's turn numbers count noises too; the transcript numbers the turns it shows.
    private var shownTurns: [Int: Int] = [:]
    private var currentReply: CurrentReply?
    private var labelledReplies: Set<Int> = []
    private var replyLabels: [Int: ReplyLabel] = [:]
    private var unheardReplies: Set<Int> = []
    private var wakeNext = false
    private var wakeHeard = 0
    private var wakeCut = false
    private var lastCallerAt: Date?

    public init(maxLines: Int = 300) {
        self.maxLines = max(1, maxLines)
    }

    // MARK: - Events

    /// One caption update: segment `segment`'s text so far. `fromCaller` says whose words they are; a segment
    /// keeps the side it started on. `command`: the worker's mark on a caller caption, replacing the line's last one.
    public mutating func caption(
        segment: String, text raw: String, isFinal: Bool, fromCaller: Bool, command: SpokenCommand? = nil, at now: Date
    ) {
        let known = segmentLine[segment]
        if let known, known < firstRetainedID { return }
        let mine = known.flatMap { id in lines.first { $0.id == id }?.speaker }.map { $0 == .caller } ?? fromCaller
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = mine ? Self.spaceSentences(trimmed) : trimmed
        let interim = mine && !isFinal
        // The worker never sends an interim after a segment's final: one arriving late here is stale.
        if interim, finalSegments.contains(segment) { return }
        let changed = segmentText[segment] != text
        let command = mine ? command : nil
        let remarked = known.flatMap { id in lines.first { $0.id == id } }.map { $0.command != command } ?? false
        guard !text.isEmpty, changed || remarked || (interimSegments[segment] != nil) != interim else { return }
        segmentText[segment] = text
        if interim { interimSegments[segment] = now } else {
            interimSegments[segment] = nil
            finalSegments.insert(segment)
        }
        if let known {
            update(known) {
                $0.text = text
                $0.isFinal = !interim
                $0.command = command
            }
            // A final that only firms the text up is no new words: no caret, and the wake timing stands.
            guard changed else { return }
            touch(known, at: now)
        } else {
            let id = takeID()
            segmentLine[segment] = id
            var line = Line(id: id, speaker: mine ? .caller : .agent, kind: .caption, text: text, at: now, isFinal: !interim)
            line.command = command
            // An agent line joins the message being spoken; only its first line says what it answers.
            if !mine, let reply = currentReply {
                line.reply = reply.group
                if labelledReplies.insert(reply.group).inserted { line.answers = reply.label }
            }
            if mine, wakeNext {
                wakeNext = false
                line.wake = true
            }
            append(line)
            touch(id, at: now)
        }
        if mine { lastCallerAt = now }
    }

    public mutating func apply(_ message: TurnMessage, at now: Date) {
        switch message {
        case .unheard:
            // One note per reply the caller spoke over, however many times they tried.
            let reply = currentReply?.group ?? -1
            guard unheardReplies.insert(reply).inserted else { return }
            append(Line(id: takeID(), speaker: .agent, kind: .unheard, text: "", at: now, isFinal: true))
        case let .dropped(dropped):
            applyDropped(dropped)
        case let .status(status):
            // The page knows no `working`: it neither numbers nor marks a turn.
            if status.status == .working { return }
            let shown = shownTurns[status.turn] ?? (shownTurns.count + 1)
            shownTurns[status.turn] = shown
            switch status.status {
            // An auto turn shows no mark while it goes out; a sent review draft enters the history here, once, with
            // exactly the text the caller approved.
            case .sending:
                guard status.draft != nil, let text = status.text, !text.isEmpty else { return }
                var line = Line(id: takeID(), speaker: .caller, kind: .caption, text: text, at: now, isFinal: true)
                line.mark = .sending
                line.turn = shown
                covered.insert(line.id)
                append(line)
            case .working: return
            case .sent: applyTurn(.sent, text: status.text, wordless: false, shown: shown, at: now)
            case .lost:
                let said = Self.norm(status.text ?? "")
                applyTurn(.lost(status.reason), text: status.text, wordless: said.isEmpty, shown: shown, at: now)
            }
        }
    }

    /// What the next spoken line answers; arrives before its caption, which takes it.
    public mutating func apply(_ info: ReplyInfo, at now: Date) {
        if info.unspoken == true { return showUnspoken(info, at: now) }
        let label: ReplyLabel? = if let turn = info.turn, let shown = shownTurns[turn] {
            .turn(shown, part: (info.part ?? 0) > 1 ? info.part : nil)
        } else if info.unprompted == true {
            .unprompted
        } else {
            nil
        }
        currentReply = CurrentReply(group: info.reply, label: label)
        replyLabels[info.reply] = label
    }

    /// The worker's newest wake state: a wake it heard marks the caller line spoken as it was heard, or the next one.
    public mutating func apply(wake state: WakeState, at now: Date) {
        wakeCut = state.cut ?? false
        if let heard = state.heard, heard > wakeHeard {
            wakeHeard = heard
            let last = lines.last { $0.speaker == .caller && $0.kind == .caption }
            let current = last.map { line in
                line.mark == nil && !covered.contains(line.id)
                    && lastCallerAt.map { now.timeIntervalSince($0) < Self.wakeLineWindow } == true
            } ?? false
            if state.cut == true {
                // The transcription restarted right after the phrase: a caption of the phrase itself is found
                // when the turn settles.
                wakeNext = false
            } else if current, let last {
                update(last.id) { $0.wake = true }
                wakeNext = false
            } else {
                wakeNext = true
            }
        }
        if state.on, state.waiting { wakeNext = false }
    }

    /// The worker announced its command words: from now on it marks every caption that holds one.
    public mutating func commandsAnnounced() {
        marksCommands = true
    }

    /// Whether caption segment `segment` already has a line (or had one, since dropped at the cap or taken back).
    public func knows(segment: String) -> Bool {
        segmentLine[segment] != nil
    }

    /// Takes the open caller lines out: the words of an auto turn switched to review, which become its draft and were
    /// never sent. Returns each line's segment and text, oldest first.
    public mutating func takeOpenCallerLines() -> [(segment: String, text: String)] {
        let open = openCallerLines
        guard !open.isEmpty else { return [] }
        let ids = Set(open.map(\.id))
        let segments = Dictionary(segmentLine.filter { ids.contains($0.value) }.map { ($0.value, $0.key) }) { first, _ in first }
        lines.removeAll { ids.contains($0.id) }
        if let streamingLineID, ids.contains(streamingLineID) { self.streamingLineID = nil }
        return open.compactMap { line in segments[line.id].map { (segment: $0, text: line.text) } }
    }

    /// Interim caller lines unchanged for `interimStale` stop reading as unsettled; true when one did.
    @discardableResult
    public mutating func settleStaleInterims(at now: Date) -> Bool {
        let stale = interimSegments.filter { now.timeIntervalSince($0.value) >= Self.interimStale }
        guard !stale.isEmpty else { return false }
        for (segment, _) in stale {
            interimSegments[segment] = nil
            if let id = segmentLine[segment] { update(id) { $0.isFinal = true } }
        }
        return true
    }

    /// The call is over: no final comes after it, so its last interim captions stand as heard.
    public mutating func end() {
        interimSegments.removeAll()
        streamingLineID = nil
        for index in lines.indices { lines[index].isFinal = true }
    }

    // MARK: - Folding rules

    /// Put a turn's mark on the caller lines it is made of: the latest open one its final text contains, else the
    /// latest open one, and the open ones before it. A turn with no caption, or lost with no words, gets a line of
    /// its own. With the transcript cut at the wake phrase, an earlier open line the text does not contain is the
    /// phrase's own caption. A second status for a turn replaces the mark on its lines.
    private mutating func applyTurn(_ mark: Mark, text: String?, wordless: Bool, shown: Int, at now: Date) {
        if lines.contains(where: { $0.speaker == .caller && $0.turn == shown }) {
            for index in lines.indices where lines[index].speaker == .caller && lines[index].turn == shown {
                lines[index].mark = mark
            }
            return
        }
        let open = openCallerLines
        let said = Self.norm(text ?? "")
        // A turn lost with no words never claims a caption with words: those came late, for the next turn.
        let target = wordless ? nil : ((said.isEmpty ? nil : open.last { within(said, $0) }) ?? open.last)
        guard let target else {
            var line = Line(
                id: takeID(), speaker: .caller, kind: .caption,
                text: text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", at: now, isFinal: true
            )
            line.mark = mark
            line.turn = shown
            covered.insert(line.id)
            return append(line)
        }
        for line in open {
            covered.insert(line.id)
            if wakeCut, !said.isEmpty, line.id != target.id, !within(said, line) {
                update(line.id) {
                    $0.wake = true
                    $0.wakeOnly = true
                }
            } else {
                update(line.id) {
                    $0.mark = mark
                    $0.turn = shown
                }
            }
            if line.id == target.id { break }
        }
    }

    /// Mark the caller lines of words the worker dropped. A discard, or a turn gone back to waiting, drops every
    /// open line. Speech before the wake phrase is the latest open line it contains and the open ones before it,
    /// else the oldest open line; a line it is only the start of keeps going, tagged `preWake`.
    private mutating func applyDropped(_ dropped: DroppedSpeech) {
        let open = openCallerLines
        let said = Self.norm(dropped.text)
        if dropped.dropped == .command {
            // A command with nothing open is one line of its own: never the caller's next words.
            let ofSegment = dropped.segment.flatMap { segment in open.last { segmentLine[segment] == $0.id } }
            guard let target = ofSegment ?? open.last(where: isLoneCommand) ?? open.last(where: { Self.norm($0.text) == said })
            else { return }
            covered.insert(target.id)
            // Which command it was: the drop says, else the line's mark; an older worker's only from the words.
            let kind = dropped.command ?? target.command?.kind
                ?? (!marksCommands && Self.endsInDiscard(target.text) ? .discard : .send)
            return update(target.id) {
                $0.mark = .dropped(.command)
                $0.command = SpokenCommand(kind, words: $0.command?.words ?? "")
            }
        }
        let whole = dropped.dropped == .unaddressed ? open.last { within(said, $0) } : nil
        if dropped.dropped == .unaddressed, whole == nil, !said.isEmpty,
           let part = open.last(where: {
               let key = saidKey($0)
               return key.utf16.count > said.utf16.count && key.contains(said)
           }),
           let partIndex = open.firstIndex(where: { $0.id == part.id })
        {
            for line in open[..<partIndex] {
                covered.insert(line.id)
                update(line.id) { $0.mark = .dropped(.unaddressed) }
            }
            return update(part.id) { $0.preWake = true }
        }
        let target = dropped.dropped == .discarded || dropped.dropped == .asleep ? open.last : (whole ?? open.first)
        guard let target else { return }
        for line in open {
            covered.insert(line.id)
            update(line.id) { $0.mark = .dropped(dropped.dropped) }
            if line.id == target.id { break }
        }
    }

    /// A line the worker could not speak: its text joins the reply as an agent line marked unspoken, or a caption of
    /// the same text is marked instead.
    private mutating func showUnspoken(_ info: ReplyInfo, at now: Date) {
        let text = info.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty, let caption = lines.first(where: {
            $0.speaker == .agent && $0.kind == .caption && $0.reply == info.reply && Self.norm($0.text) == Self.norm(text)
        }) {
            return update(caption.id) { $0.unspoken = true }
        }
        var line = Line(id: takeID(), speaker: .agent, kind: .caption, text: text, at: now, isFinal: true)
        line.reply = info.reply
        line.unspoken = true
        if labelledReplies.insert(info.reply).inserted { line.answers = replyLabels[info.reply] }
        append(line)
    }

    // MARK: - Bookkeeping

    private struct CurrentReply: Sendable, Equatable {
        let group: Int
        let label: ReplyLabel?
    }

    private var openCallerLines: [Line] {
        lines.filter { $0.speaker == .caller && $0.kind == .caption && !covered.contains($0.id) }
    }

    private var firstRetainedID: Int { lines.first?.id ?? nextID }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private mutating func touch(_ id: Int, at now: Date) {
        streamingLineID = id
        lastDeltaAt = now
    }

    private mutating func update(_ id: Int, _ change: (inout Line) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[index])
    }

    /// Appends, then forgets the oldest lines past the cap. Their segments stay known, so a late update to one is
    /// dropped instead of opening a new line.
    private mutating func append(_ line: Line) {
        lines.append(line)
        guard lines.count > maxLines else { return }
        let gone = lines.prefix(lines.count - maxLines)
        lines.removeFirst(gone.count)
        let goneIDs = Set(gone.map(\.id))
        covered.subtract(goneIDs)
        for (segment, id) in segmentLine where goneIDs.contains(id) {
            segmentText[segment] = nil
            interimSegments[segment] = nil
            finalSegments.remove(segment)
        }
        if let streamingLineID, goneIDs.contains(streamingLineID) { self.streamingLineID = nil }
    }
}

// MARK: - Reading (the page's transcript view, `App.tsx`)

public extension Transcript {
    /// Whether line `index` carries on the caller line above it: the transcription cuts a turn at each pause, and its
    /// pieces (the open turn's, or one sent turn's) read as one block under one speaker row. Wake lines keep theirs.
    func continuesAbove(_ index: Int) -> Bool {
        guard index > 0, index < lines.count else { return false }
        let line = lines[index]
        let previous = lines[index - 1]
        guard line.speaker == .caller, line.kind == .caption, previous.speaker == .caller, previous.kind == .caption,
              !line.wake, !line.preWake
        else { return false }
        if let turn = line.turn { return previous.turn == turn }
        return line.mark == nil && previous.mark == nil && previous.turn == nil
    }

    /// The lines that read as the newest: the newest caption, the rest of the spoken message it belongs to, and the
    /// caller block it closes. A note never counts as the newest line.
    var liveLineIDs: Set<Int> {
        guard let lastIndex = lines.lastIndex(where: { $0.kind == .caption }) else { return [] }
        var from = lastIndex
        while from > 0, continuesAbove(from) { from -= 1 }
        var ids = Set(lines[from...].map(\.id))
        if let group = lines[lastIndex].reply {
            ids.formUnion(lines.lazy.filter { $0.reply == group }.map(\.id))
        }
        return ids
    }
}

// MARK: - Text matching (the page's `review.ts`)

extension Transcript {
    /// A caller line as a sent turn's text holds it: the words before its command. Only a worker that announces no
    /// command words leaves them to be found here.
    private func saidKey(_ line: Line) -> String {
        if let command = line.command { return Self.norm(command.words) }
        return marksCommands ? Self.norm(line.text) : Self.lineKey(line.text)
    }

    /// A caption line that is only a spoken command ("Zulu."), with nothing else said.
    private func isLoneCommand(_ line: Line) -> Bool {
        !Self.norm(line.text).isEmpty && saidKey(line).isEmpty
    }

    /// Whether a caption line belongs to the text the worker reports (a line of only a command does).
    private func within(_ said: String, _ line: Line) -> Bool {
        guard !Self.norm(line.text).isEmpty else { return false }
        let key = saidKey(line)
        return key.isEmpty || said.contains(key)
    }

    // An older worker marks no captions: they are matched against the built-in words, as `norm` leaves them, and their
    // other spellings. A caption ending in one holds that command.
    static let sendWords = CommandWords.builtIn.send.filter { !$0.ownSentence }.map { norm($0.say) } + ["зулу", "приём"]
    /// Send words that count only as their own sentence: "Make a copy." is words.
    static let sentenceSendWords = CommandWords.builtIn.send.filter(\.ownSentence).map { norm($0.say) }
    static let discardPhrases = CommandWords.builtIn.discard.map { norm($0.say) }
    private static let commandWords = sendWords + discardPhrases

    /// A caption line that ends in a discard phrase ("Scratch that."): said alone, there was nothing to discard.
    static func endsInDiscard(_ text: String) -> Bool {
        let normalized = norm(text)
        return discardPhrases.contains { normalized.hasSuffix($0) }
    }

    /// Lowercase, letters and digits only (any script).
    static func norm(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where isLetterOrNumber(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// A caption line as a sent turn's text holds it: a spoken command that ended the turn is not sent.
    static func lineKey(_ text: String) -> String {
        let normalized = norm(text)
        let last = norm(lastSentence(text))
        if sentenceSendWords.contains(last) { return String(normalized.dropLast(last.count)) }
        // The longest command the text ends with: the leftmost match of the page's end-anchored alternation.
        guard let longest = commandWords.filter({ normalized.hasSuffix($0) }).max(by: { $0.count < $1.count }) else {
            return normalized
        }
        return String(normalized.dropLast(longest.count))
    }

    /// The text after the last sentence end, not counting the ones it ends with.
    private static func lastSentence(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let before = scalars.index(before: end)
            guard sentenceEnds.contains(scalars[before]) || scalars[before].properties.isWhitespace else { break }
            end = before
        }
        let start = scalars[..<end].lastIndex(where: sentenceEnds.contains).map(scalars.index(after:)) ?? scalars.startIndex
        return String(scalars[start ..< end])
    }

    /// A caption text that is only a built-in command ("Zulu."), with nothing else said.
    static func isCommandOnly(_ text: String) -> Bool {
        !norm(text).isEmpty && lineKey(text).isEmpty
    }

    /// The streaming transcription's interim text can run two segments together ("test.Please"): a space goes back
    /// after a sentence end where a lowercase letter or digit meets a capital.
    static func spaceSentences(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            out.append(scalar)
            index += 1
            guard isLowercaseOrNumber(scalar) else { continue }
            var end = index
            while end < scalars.count, sentenceEnds.contains(scalars[end]) { end += 1 }
            guard end > index, end < scalars.count, scalars[end].properties.generalCategory == .uppercaseLetter else { continue }
            out.append(contentsOf: scalars[index ..< end])
            out.append(" ")
            index = end
        }
        return String(out)
    }

    private static let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?", "…"]

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    private static func isLowercaseOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .lowercaseLetter, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
}

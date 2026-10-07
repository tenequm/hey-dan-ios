import AVFAudio
import CallKit
import HeyDanCore
import LiveKit
import Observation
import os
import Security
import UIKit

/// One call at a time: CallKit owns its lifecycle (lock screen, AirPods, interruptions),
/// NanoClaw admits it and LiveKit carries the audio.
@MainActor
@Observable
final class CallController: NSObject {
    static let shared = CallController()

    enum Phase: Equatable {
        case idle
        case connecting
        case live(VoiceProtocol.AgentActivity)
        case reconnecting
        case ended(Ending)
    }

    /// How a call ended: the screen words a hangup by the caller, a failure and the other side ending it differently.
    struct Ending: Equatable {
        enum Cause { case caller, failure, remote }
        let cause: Cause
        let message: String
        /// What failed, when the call ended on a `CallFailure`: an intent words some of them for where it was run.
        var failure: CallFailure?

        static let byCaller = Ending(cause: .caller, message: "Call ended.")
        static func failure(_ failure: CallFailure) -> Ending { Ending(cause: .failure, message: failure.message, failure: failure) }
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            trace(.call, "phase \(oldValue.logName) -> \(phase.logName)")
            switch phase {
            case .live: if liveSince == nil { liveSince = .now }
            case .idle, .connecting:
                liveSince = nil
                endedAt = nil
            case .ended:
                // An ending with no call before it (no line to call) is no call that was live.
                if case .ended = oldValue {
                    liveSince = nil
                    endedAt = nil
                }
                if endedAt == nil { endedAt = .now }
            case .reconnecting: break
            }
            thinkingSince = phase == .live(.thinking) ? thinkingSince ?? .now : nil
        }
    }
    /// When the call first went live; kept after it ends, so it also says the call ever was.
    private(set) var liveSince: Date?
    private(set) var endedAt: Date?
    /// When the agent started on the current turn.
    private(set) var thinkingSince: Date?

    /// Only a call that never went live failed to connect; one that was live ended, whatever the reason. Hanging up
    /// before it went live is no failure either.
    static func isFailure(_ ending: Ending, liveSince: Date?) -> Bool { liveSince == nil && ending.cause != .caller }
    private(set) var isMuted = false
    /// Who the screen is about: the shown line's agent, or the call's once its host named it.
    private(set) var agentName = VoiceLines.unnamedAgent
    /// Every saved voice line and the one a call goes to unless an intent names another.
    private(set) var lines = VoiceLines()
    /// The line the screen shows: the picked one, or the one the last call used until the pick changes.
    private(set) var shownLineID: UUID?
    /// The picked line, the one the Action Button calls.
    var line: VoiceLine? { lines.selected?.line }
    /// The call's live transcript: cleared when a call starts, kept readable (all final) after it ends.
    private(set) var transcript = Transcript()
    /// Auto mode's spoken-command settings: nil unless this call's worker speaks the commands vocabulary this
    /// app knows (`Names.commandsAttribute` in `VoiceProtocol.commandsVersions`).
    private(set) var commands: CommandSettings?
    /// The spoken commands hints quote: the ones this call's worker announced, else the built-in ones.
    private(set) var commandWords = CommandWords.builtIn
    /// The caller's picks: where every call starts, changed by `updateSettings`.
    private(set) var settingsPicks = SettingsStore.load()
    /// Review mode (Manual) as the screen shows it, and apart from it the words of the open recording, so a caption
    /// re-renders only the draft. Both follow `reviewSession`.
    private(set) var review = ReviewSession(pick: TurnModeStore.load()).review
    private(set) var draftWords = ""

    var isCallActive: Bool {
        switch phase {
        case .connecting, .live, .reconnecting: true
        case .idle, .ended: false
        }
    }

    /// A host's grant on a protocol this app speaks, with that protocol's names: held as one so neither is set alone.
    private struct AcceptedGrant {
        let grant: CallGrant
        let names: VoiceProtocol.Names
    }

    /// Everything one call owns, created when it starts and dropped in one assignment when it ends,
    /// so a late callback from an earlier call can never touch the current one.
    private struct ActiveCall {
        let id: UUID
        /// The line the call was admitted on: a link saved mid-call must not redirect its hangup.
        let line: VoiceLine
        let claimedAt = ContinuousClock.now
        var callId: String?
        /// Set before the room exists: before CallKit when the precheck said Tailscale is off, and setup then uses it
        /// instead of asking again.
        var grant: AcceptedGrant?
        /// The worker's names on the protocol the host said it speaks.
        var names: VoiceProtocol.Names? { grant?.names }
        /// Stream events received per topic, for the end-of-call summary.
        var streamCounts: [String: Int] = [:]
        var room: Room?
        /// The caller's microphone, made before it is published so a mute asked for during setup holds from the start
        /// (at the mixer: see `syncMic`).
        var mic: LocalAudioTrack?
        /// Setup published `mic`: until then the call cannot go live.
        var micPublished = false
        /// A pass of `syncMic` is under way; a mute asked for meanwhile is taken by its next round.
        var micSyncing = false
        /// `room.connect` returned: only from then can the agent leave or the room end the call. A connect that
        /// times out makes the SDK report both while tearing the room down, and that is a failure to connect.
        var roomConnected = false
        var reportedConnected = false
        /// The host names why it ended the call in the room metadata; the SDK clears it before it reports the disconnect.
        var endReason: String?
        var connectTask: Task<Void, Never>?
        var agentTimer: Task<Void, Never>?
        /// Ends the call if CallKit never activates its audio session (`didActivate`), which iOS 27 sometimes skips.
        var activationTimer: Task<Void, Never>?
        var interimTimer: Task<Void, Never>?
        var streams = StreamOrder<StreamEvent>()
        var streamFlush: Task<Void, Never>?
        /// Runs out when the worker sets no review attribute in time: it has no Manual mode.
        var reviewGrace: Task<Void, Never>?
        /// The worker's review attribute arrived on this call.
        var reviewOffered = false
        /// The wake state the worker last said it runs.
        var workerWake: WakeState?
        /// The `gen` of the last RPC sent, and the newest settings request: only its outcome counts.
        var rpcGen = 0
        var settingsRequest = 0
        var settingsSent = false
        /// Settings RPCs sent on this call, resends included: only the first is cut short.
        var settingsSends = 0
        /// What the worker last took from this call's settings requests.
        var takenPicks: SettingsPicks?
    }

    @ObservationIgnored private var call: ActiveCall?
    /// The last call that ended, and how: what an intent that started it reports.
    @ObservationIgnored private var lastEnded: (id: UUID, ending: Ending)?
    /// Review mode's state and bookkeeping; the one call's part of it is reset when a call starts.
    @ObservationIgnored private var reviewSession = ReviewSession(pick: TurnModeStore.load())
    @ObservationIgnored private var reviewNoteTimer: Task<Void, Never>?
    /// The Keychain item was read: until then a save would overwrite lines this launch never saw.
    @ObservationIgnored private var linesLoaded = false
    /// Before the first unlock the Keychain keeps the lines out of reach: they load once protected data is there.
    @ObservationIgnored private var unlockObserver: (any NSObjectProtocol)?
    /// Created on the first call, not at launch: on iOS 27 a provider made right after unlock (an Action Button
    /// launch) can be left without `didActivate` (Apple developer forums thread 837211).
    @ObservationIgnored private var provider: CXProvider?
    @ObservationIgnored private let callKit = CXCallController()
    /// Mute actions the app asked CallKit for to show a microphone it moved itself: their `perform` only fulfils them.
    @ObservationIgnored private var appMuteActions: Set<UUID> = []

    /// DTX off on every publish, a republish after a full reconnect included: the worker times the caller's turn by
    /// the silence it hears.
    private static let micPublishOptions = AudioPublishOptions(dtx: VoiceProtocol.micDTX, red: false)

    /// Short enough that a dead tailnet shows its hint quickly; the host answers in about a second.
    private static let http = session(timeout: 10)
    /// The token request after a precheck that says Tailscale is off: a host that answers still gets the call, and a
    /// dead tailnet's hint still comes fast.
    private static let quickHTTP = session(timeout: 4)

    private static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    /// Setup's own waits before the agent's join timer starts (precheck, token, room, audio activation), with room to spare.
    static let setupBound = VoiceProtocol.agentJoinTimeout + .seconds(20)

    override private init() {
        super.init()
        CallActivity.follow(self)
        loadLines()
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // Tests set the turn mode calls start in, as the caller's hands-free | Manual pick would.
        if let mode = env["HEYDAN_TURN_MODE"].flatMap(TurnMode.init(rawValue:)) {
            TurnModeStore.save(mode)
            editReview { $0 = ReviewSession(pick: mode) }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        // `just sim` hands the call link in at launch: the Simulator's pasteboard does not take a CLI copy.
        if let link = env["HEYDAN_CALL_LINK"] { saveCallLink(link) }
        // Screenshots: fake lines named for the agents listed, never a real link; the first listed is picked.
        if let names = env["HEYDAN_PREVIEW_LINES"] {
            _ = keep { next in
                let ids = names.split(separator: ",").compactMap { name in
                    VoiceLine(callLink: "https://lines.example/voice?t=fake-\(name.lowercased())").map {
                        next.add($0, agent: String(name))
                    }
                }
                if let first = ids.first { next.select(first) }
            }
            showLine(lines.selected)
        }
        #endif
        // CallKit activates the audio session; LiveKit's engine runs only between didActivate and didDeactivate.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        setEngine(.none)
    }

    private func callProvider() -> CXProvider {
        if let provider {
            // Re-pushing the configuration before each call is the documented workaround for a stale audio session.
            provider.configuration = provider.configuration
            return provider
        }
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        let provider = CXProvider(configuration: configuration)
        // nil: delegate callbacks arrive on the main queue, which the delegate methods rely on.
        provider.setDelegate(self, queue: nil)
        self.provider = provider
        return provider
    }

    /// Calls the line `lineID` names, or the picked one. The id of the call it claimed; nil when another call is on or
    /// there is no such line.
    @discardableResult
    func start(lineID: UUID? = nil) async -> UUID? {
        guard !isCallActive else { return nil }
        let entry = if let lineID { lines.entry(lineID) } else { lines.selected }
        guard let entry else {
            // A shortcut can name a line deleted since: that is no phone without a line.
            phase = .ended(.failure(lines.entries.isEmpty ? .noLine : .lineGone))
            return nil
        }
        let id = UUID()
        // Claimed before any await, so a second tap or Action Button press finds the call already active.
        call = ActiveCall(id: id, line: entry.line)
        showLine(entry)
        phase = .connecting
        transcript = Transcript()
        commands = nil
        commandWords = .builtIn
        editReview { $0.startCall() }
        trace(.call, "claim line=\(Self.short(entry.id)) mode=\(reviewSession.pick.rawValue)")
        #if DEBUG
        // Tests end every call, one the App Intent started too, this many seconds after it was claimed.
        if let seconds = ProcessInfo.processInfo.environment["HEYDAN_HANGUP_AFTER"].flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                if self?.call?.id == id { self?.hangUp() }
            }
        }
        #endif
        // Manual never opens the microphone before talk: the track is published muted.
        if review.mode == .review { isMuted = true }
        await place(id, on: entry.line)
        return id
    }

    private func place(_ id: UUID, on line: VoiceLine) async {
        // Before the microphone prompt and CallKit: with Tailscale off the token request would only fail at its timeout.
        let checking = ContinuousClock.now
        let tailnet = await Tailnet.check(host: line.host)
        trace(.net, "tailscale precheck \(tailnet.logName) ms=\(CallLog.ms(since: checking))", id, level: tailnet == .off ? .error : .default)
        if tailnet == .off, await !grantEarly(id, line) { return }
        guard call?.id == id else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        trace(.audio, "mic permission granted=\(granted)", id)
        guard granted else { return finish(id, .failure(.microphoneDenied), endedBy: nil) }
        guard call?.id == id else { return }
        _ = callProvider()
        let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: agentName))
        do {
            try await callKit.request(CXTransaction(action: start))
            trace(.callkit, "start transaction ok", id)
            if isMuted { reportMute(for: id) }
        } catch {
            trace(.callkit, "start transaction failed \(CallLog.describe(error))", id, level: .error)
            finish(id, .failure(.callKitRefused(error.localizedDescription)), endedBy: nil)
        }
    }

    /// A precheck can misread, so it never blocks a call alone: the host gets a short try, and only when that cannot
    /// reach it does the call end on the Tailscale hint. False when the call is over.
    private func grantEarly(_ id: UUID, _ line: VoiceLine) async -> Bool {
        let asked = ContinuousClock.now
        do {
            let accepted = try await requestGrant(line, over: Self.quickHTTP)
            guard call?.id == id else {
                endOnHost(line, callId: accepted.grant.callId)
                return false
            }
            call?.callId = accepted.grant.callId
            call?.grant = accepted
            trace(.net, "token ok despite the precheck protocol=\(accepted.names.version) ms=\(CallLog.ms(since: asked))", id)
            return true
        } catch {
            trace(.net, "token failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: asked))", id, level: .error)
            finish(id, .failure(error == .unreachable ? .tailscaleOff : error), endedBy: nil)
            return false
        }
    }

    #if DEBUG
    func isCurrent(_ id: UUID) -> Bool { call?.id == id }
    /// The call on now, from its claim to its end.
    var callID: UUID? { call?.id }
    #endif

    /// Whether call `id` is still setting up.
    func isConnecting(_ id: UUID) -> Bool { call?.id == id && phase == .connecting }

    /// How call `id` failed; nil while it runs, when it ended otherwise, or when a later call ended since.
    func failure(of id: UUID) -> Ending? {
        guard let lastEnded, lastEnded.id == id, lastEnded.ending.cause == .failure else { return nil }
        return lastEnded.ending
    }

    func hangUp() {
        guard let id = call?.id else { return }
        trace(.call, "hangup asked")
        Task {
            do { try await callKit.request(CXTransaction(action: CXEndCallAction(call: id))) } catch {
                // CallKit never knew the call (still asking for the mic) or no longer does; end it here.
                trace(.callkit, "end transaction failed \(CallLog.describe(error))", id)
                finish(id, .byCaller, endedBy: nil)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let id = call?.id else { return }
        trace(.call, "mute asked muted=\(muted)")
        Task { try? await callKit.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) }
    }

    /// Changes auto mode's wake switch, whether a pause sends after the wake phrase, or the typing sound. Mid-call
    /// the worker has to take it: true once it did, and only then is it kept for the next call; until it answers
    /// `commands` shows the change, and a refusal puts back what the worker runs (no answer: what its state says it
    /// runs). Without commands on the call (none yet, or none at all) it only becomes the pick the next call starts
    /// with.
    @discardableResult
    func updateSettings(wake: Bool? = nil, pauseSends: Bool? = nil, typing: Bool? = nil) async -> Bool {
        var picks = commands.map { SettingsPicks(wake: $0.wake, pauseSends: $0.pauseSends, typing: $0.typing) } ?? settingsPicks
        if let wake { picks.wake = wake }
        if let pauseSends { picks.pauseSends = pauseSends }
        if let typing { picks.typing = typing }
        guard let id = call?.id, commands != nil else {
            keepPicks(picks)
            return true
        }
        return await requestSettings(picks, for: id)
    }

    /// Takes the caller's wish for call `id` at once and brings its microphone to it. False for any other call, or
    /// when the microphone could not follow: the key then shows what the microphone does.
    private func applyMute(_ muted: Bool, for id: UUID) async -> Bool {
        guard call?.id == id else { return false }
        isMuted = muted
        do {
            try await syncMic(id)
        } catch {
            guard call?.id == id else { return false }
            isMuted = !micSends()
            trace(.audio, "mic follow failed muted=\(muted) \(CallLog.describe(error))", id, level: .error)
            return false
        }
        trace(.audio, "mic muted=\(muted)", id)
        return call?.id == id
    }

    /// Brings call `id`'s microphone to `isMuted`, one pass at a time, rechecking after every await. Once setup
    /// published it, an unmute also publishes it again where a full reconnect left it out (the SDK republishes only
    /// unmuted tracks).
    ///
    /// Until then the track stays unmuted and a mute holds at the mixer instead: LiveKit's publish waits for the
    /// track's first captured frame and fails after 5 s without one, and a muted (disabled) track can capture none.
    /// The mixer's silence still reaches the track as frames.
    private func syncMic(_ id: UUID) async throws {
        guard call?.id == id, call?.micSyncing == false else { return }
        call?.micSyncing = true
        defer { if call?.id == id { call?.micSyncing = false } }
        while let current = call, current.id == id, let mic = current.mic {
            if !current.micPublished {
                Self.silenceMixer(isMuted)
                return
            }
            if isMuted != mic.isMuted {
                if isMuted { try await mic.mute() } else { try await mic.unmute() }
            } else if !isMuted, current.micPublished, let room = current.room, room.connectionState == .connected,
                      !Self.isPublished(mic, in: room)
            {
                try await room.localParticipant.publish(audioTrack: mic, options: Self.micPublishOptions)
                trace(.audio, "mic published again after a reconnect", id)
            } else {
                return
            }
        }
    }

    /// Silences the microphone at LiveKit's mixer, upstream of every track; only setup turns it on.
    private static func silenceMixer(_ silent: Bool) {
        let volume: Float = silent ? 0 : 1
        if AudioManager.shared.mixer.micVolume != volume { AudioManager.shared.mixer.micVolume = volume }
    }

    private func micSends() -> Bool {
        guard let mic = call?.mic, !mic.isMuted, let room = call?.room else { return false }
        return Self.isPublished(mic, in: room)
    }

    private static func isPublished(_ mic: LocalAudioTrack, in room: Room) -> Bool {
        room.localParticipant.trackPublications.values.contains { $0.track === mic }
    }

    // MARK: - Call lifecycle

    private func connect(_ id: UUID) {
        guard let line = call?.line else { return }
        call?.connectTask = Task {
            do {
                let accepted: AcceptedGrant
                if let early = call?.grant {
                    accepted = early
                } else {
                    let asked = ContinuousClock.now
                    do { accepted = try await requestGrant(line, over: Self.http) } catch {
                        trace(.net, "token failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: asked))", id, level: .error)
                        throw error
                    }
                    guard call?.id == id else { return endOnHost(line, callId: accepted.grant.callId) }
                    call?.callId = accepted.grant.callId
                    call?.grant = accepted
                    trace(.net, "token ok protocol=\(accepted.names.version) ms=\(CallLog.ms(since: asked))", id)
                }
                let (grant, names) = (accepted.grant, accepted.names)
                if let agent = grant.agent, !agent.isEmpty { setAgentName(agent, for: id) }
                let room = Room(delegate: self, roomOptions: RoomOptions(defaultAudioPublishOptions: Self.micPublishOptions))
                call?.room = room
                await listen(to: room, names: names, for: id)
                guard call?.id == id else { return }
                let connecting = ContinuousClock.now
                trace(.room, "connect start", id)
                do { try await room.connect(url: grant.url, token: grant.token) } catch {
                    trace(.room, "connect failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: connecting))", id, level: .error)
                    throw CallFailure.roomConnect
                }
                guard call?.id == id else { return }
                call?.roomConnected = true
                trace(.room, "connected ms=\(CallLog.ms(since: connecting))", id)
                let mic = await LocalAudioTrack.createTrack()
                guard call?.id == id else { return }
                call?.mic = mic
                // Setup done, the mixer opens; a call that is gone leaves no later call's microphone silent there
                // (unless one is already setting up its own). A failed setup leaves it closed: `finish` opens it once
                // the engine is off.
                var micReady = false
                defer { if call?.id == id ? micReady : call?.mic == nil { Self.silenceMixer(false) } }
                try await syncMic(id)
                guard call?.id == id else { return }
                let publishing = ContinuousClock.now
                try await room.localParticipant.publish(audioTrack: mic, options: Self.micPublishOptions)
                guard call?.id == id else { return }
                call?.micPublished = true
                // Mutes the track before the mixer opens (the defer above), so a muted caller is not heard in between.
                try await syncMic(id)
                guard call?.id == id else { return }
                micReady = true
                trace(.audio, "mic published muted=\(isMuted) track=\(mic.isMuted ? "muted" : "open") ms=\(CallLog.ms(since: publishing))", id)
                startAgentTimer(id)
                startInterimTimer(id)
                refresh()
            } catch {
                // A hangup cancels this task, and what it then throws belongs to a call that is over.
                guard call?.id == id else { return }
                trace(.call, "setup failed \(CallLog.describe(error))", id, level: .error)
                finish(id, .failure(error as? CallFailure ?? .setupFailed), endedBy: .failed)
            }
        }
    }

    /// The host's grant and the names of the protocol it speaks. A grant on a protocol this app does not speak is never
    /// joined: its call ends on the host right away.
    private func requestGrant(_ line: VoiceLine, over http: URLSession) async throws(CallFailure) -> AcceptedGrant {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: line.tokenRequest)
        } catch {
            throw CallFailure(transportError: error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        CallLog.log(.net, "token status=\(status) bytes=\(data.count)", level: status == 200 ? .info : .error)
        let grant = try CallGrant(status: status, body: data)
        guard let names = grant.names else {
            endOnHost(line, callId: grant.callId, reason: .updating)
            throw .unsupportedProtocol(grant.protocolVersion)
        }
        return AcceptedGrant(grant: grant, names: names)
    }

    private func setAgentName(_ name: String, for id: UUID) {
        agentName = name
        if let line = call?.line, let lineID = lines.id(of: line) { nameLine(lineID, agent: name) }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        provider?.reportCall(with: id, updated: update)
    }

    private func startActivationTimer(_ id: UUID) {
        call?.activationTimer = Task { [weak self] in
            try? await Task.sleep(for: VoiceProtocol.audioActivationTimeout)
            guard !Task.isCancelled, let self, call?.id == id else { return }
            trace(.callkit, "audio activation timed out", id, level: .error)
            finish(id, .failure(.audioNotStarted), endedBy: .failed)
        }
    }

    private func startAgentTimer(_ id: UUID) {
        call?.agentTimer = Task { [weak self] in
            try? await Task.sleep(for: VoiceProtocol.agentJoinTimeout)
            guard !Task.isCancelled, let self, call?.id == id, call?.reportedConnected == false else { return }
            trace(.room, "agent join timed out", id, level: .error)
            finish(id, .failure(.noAgent), endedBy: .failed, hostReason: .noAgent)
        }
    }

    /// Re-reads the room: every delegate callback lands here, so their order does not matter.
    private func refresh() {
        guard let call, let room = call.room, let names = call.names else { return }
        if room.connectionState == .reconnecting { return phase = .reconnecting }
        guard let agent = room.remoteParticipants.values.first(where: \.isAgent) else { return }
        let attributes = agent.attributes
        if names.isUpdating(attributes) {
            trace(.room, "worker is updating", level: .error)
            return finish(call.id, .failure(.updating), endedBy: .failed, hostReason: .updating)
        }
        refreshCommandWords(attributes, names: names, for: call.id)
        refreshCommands(attributes, names: names, for: call)
        guard let activity = names.activity(attributes) else { return }
        if !call.reportedConnected {
            // Live only once the caller can be heard: in the room, microphone published.
            guard call.micPublished, room.connectionState == .connected else { return }
            self.call?.reportedConnected = true
            trace(.call, "live")
            #if DEBUG
            ReconnectDrill.run(on: room, for: call.id)
            #endif
            call.agentTimer?.cancel()
            provider?.reportOutgoingCall(with: call.id, connectedAt: nil)
        }
        phase = .live(activity)
        refreshReview(attributes, names: names, for: call.id)
    }

    /// Before `room.connect` returned this is the SDK cleaning up a connect that failed; `connect` reports that.
    private func roomEnded(_ room: Room, reason: String?, fallback: String) {
        guard let call, room === call.room else { return }
        guard call.roomConnected else { return trace(.room, "room end ignored before connect", level: .debug) }
        finish(call.id, Ending(cause: .remote, message: reason ?? call.endReason ?? fallback), endedBy: .remoteEnded)
    }

    /// Ends call `id` everywhere, once: on the host, in LiveKit and, unless CallKit asked, in CallKit.
    private func finish(
        _ id: UUID, _ ending: Ending, endedBy reason: CXCallEndedReason?, hostReason: VoiceLine.EndReason? = nil,
        site: String = #function
    ) {
        guard let current = call, current.id == id else { return }
        let streams = current.streamCounts.sorted { $0.key < $1.key }.map { "\($0.key.split(separator: ".").last ?? "")=\($0.value)" }
        trace(
            .call,
            "finish site=\(site) cause=\(ending.cause) cx=\(reason.map { "\($0.rawValue)" } ?? "-") host=\(hostReason?.rawValue ?? "-") "
                + "connected=\(current.roomConnected) mic=\(current.micPublished) live=\(current.reportedConnected) "
                + "streams=[\(streams.joined(separator: ","))]",
            id
        )
        // What was still held for ordering belongs to this call's transcript.
        call?.streamFlush?.cancel()
        for event in call?.streams.drain() ?? [] { apply(event, for: id) }
        guard let ended = call else { return }
        call = nil
        appMuteActions.removeAll()
        ended.connectTask?.cancel()
        ended.agentTimer?.cancel()
        ended.activationTimer?.cancel()
        ended.interimTimer?.cancel()
        if let callId = ended.callId { endOnHost(ended.line, callId: callId, reason: hostReason) }
        if let room = ended.room {
            let topics = ended.names?.streamTopics ?? []
            Task {
                for topic in topics { await room.unregisterTextStreamHandler(for: topic) }
                await room.disconnect()
            }
        }
        editTranscript { $0.end() }
        editReview { $0.endCall(byCaller: ending.cause == .caller) }
        commands = nil
        if let reason { provider?.reportCall(with: id, endedAt: nil, reason: reason) }
        // didDeactivate does not always follow (a reset, a call CallKit never knew).
        setEngine(.none)
        Self.silenceMixer(false)
        #if targetEnvironment(simulator)
        Self.deactivateAudioByHand()
        #endif
        isMuted = false
        lastEnded = (id, ending)
        phase = .ended(ending)
    }

    private func endOnHost(_ line: VoiceLine, callId: String, reason: VoiceLine.EndReason? = nil) {
        let request = line.endRequest(callId: callId, reason: reason)
        let tag = "cid=\(callId.prefix(8)) end reason=\(reason?.rawValue ?? "hangup")"
        Task {
            let asked = ContinuousClock.now
            do {
                let (_, response) = try await Self.http.data(for: request)
                CallLog.log(.net, "\(tag) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) ms=\(CallLog.ms(since: asked))")
            } catch {
                CallLog.log(.net, "\(tag) failed \(CallLog.describe(error))", level: .error)
            }
        }
    }

    nonisolated private func setEngine(_ availability: AudioEngineAvailability) {
        let state = availability.isInputAvailable ? "on" : "off"
        do {
            try AudioManager.shared.setEngineAvailability(availability)
            CallLog.log(.audio, "engine \(state)")
        } catch {
            CallLog.log(.audio, "engine \(state) failed \(CallLog.describe(error))", level: .error)
        }
    }

    private static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            CallLog.log(.audio, "session playAndRecord voiceChat")
        } catch {
            CallLog.log(.audio, "session failed \(CallLog.describe(error))", level: .error)
        }
    }
}

// MARK: - Logging

extension CallController {
    /// One line for call `id` (the current call when nil): `c=` is the app's call, `cid=` the first 8 characters of
    /// the host's callId (the server's logs name the caller `caller-<cid>`), `+ms` the time since the call was claimed.
    func trace(_ category: CallLog.Category, _ event: String, _ id: UUID? = nil, level: OSLogType = .default) {
        let current = call.flatMap { id == nil || $0.id == id ? $0 : nil }
        let key = (id ?? current?.id).map { "c=" + $0.uuidString.prefix(8).lowercased() } ?? "c=-"
        let cid = current?.callId.map { " cid=\($0.prefix(8))" } ?? ""
        let elapsed = current.map { " +\(CallLog.ms(since: $0.claimedAt))ms" } ?? ""
        CallLog.log(category, "\(key)\(cid)\(elapsed) \(event)", level: level)
    }
}

extension CallController.Phase {
    var logName: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case let .live(activity): "live(\(activity))"
        case .reconnecting: "reconnecting"
        case let .ended(ending): "ended(\(ending.cause))"
        }
    }
}

// MARK: - Voice lines

extension CallController {
    /// Saves a call link as a line and picks it; nil when it is not one or the Keychain refused it. Who answers
    /// is asked of the host right after, or learned on the line's first call.
    @discardableResult
    func saveCallLink(_ link: String) -> UUID? {
        guard let parsed = VoiceLine(callLink: link) else {
            CallLog.log(.store, "line save rejected: not a call link", level: .error)
            return nil
        }
        var known = false
        var added: UUID?
        guard keep({
            known = $0.id(of: parsed) != nil
            added = $0.add(parsed)
        }), let id = added else { return nil }
        CallLog.log(.store, "line save line=\(Self.short(id)) known=\(known) lines=\(lines.entries.count)")
        pick(id)
        return id
    }

    func selectLine(_ id: UUID) {
        guard keep({ $0.select(id) }) else { return }
        CallLog.log(.store, "line pick line=\(Self.short(id))")
        pick(id)
    }

    func removeLine(_ id: UUID) {
        guard keep({ $0.remove(id) }) else { return }
        CallLog.log(.store, "line remove line=\(Self.short(id)) lines=\(lines.entries.count)")
        pick(lines.selected?.id)
    }

    /// A line's log name: the start of its random id, never anything from its link.
    nonisolated static func short(_ id: UUID?) -> String {
        id.map { $0.uuidString.prefix(8).lowercased() } ?? "-"
    }

    /// Asks the host who answers line `id` and names the line for it.
    @discardableResult
    func nameLine(_ id: UUID) async throws(CallFailure) -> String {
        guard let entry = lines.entry(id) else { throw .noLine }
        let data: Data
        let response: URLResponse
        let asked = ContinuousClock.now
        let tag = "line info line=\(Self.short(id))"
        do {
            (data, response) = try await Self.http.data(for: entry.line.infoRequest)
        } catch {
            CallLog.log(.net, "\(tag) failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: asked))", level: .error)
            throw CallFailure(transportError: error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let info: LineInfo
        do { info = try LineInfo(status: status, body: data) } catch {
            CallLog.log(.net, "\(tag) status=\(status) \(error.logName) ms=\(CallLog.ms(since: asked))", level: .error)
            throw error
        }
        CallLog.log(.net, "\(tag) status=\(status) ms=\(CallLog.ms(since: asked))")
        nameLine(id, agent: info.agent)
        return info.agent
    }

    /// Names every line the host has not named yet; one it cannot reach keeps waiting for its first call.
    private func nameLines() async {
        for entry in lines.entries where entry.agent == nil {
            // nameLine(_:) logs why it failed; the line stays unnamed until it answers or takes a call.
            _ = try? await nameLine(entry.id)
        }
    }

    private func nameLine(_ id: UUID, agent: String) {
        var named = false
        guard keep({ named = $0.name(id, agent: agent) }), named else { return }
        CallLog.log(.store, "line named line=\(Self.short(id))")
        if shownLineID == id, !isCallActive { agentName = lines.entry(id)?.name ?? agentName }
    }

    /// A new pick is what the screen shows next, unless a call is on: the ended call's words make way for it.
    private func pick(_ id: UUID?) {
        guard !isCallActive, id != shownLineID else { return }
        showLine(id.flatMap(lines.entry))
        if case .ended = phase {
            phase = .idle
            transcript = Transcript()
        }
    }

    private func showLine(_ entry: VoiceLines.Entry?) {
        shownLineID = entry?.id
        agentName = entry?.name ?? VoiceLines.unnamedAgent
    }

    /// Reads the saved lines; locked before the first unlock, it tries again once the phone is unlocked.
    private func loadLines() {
        switch LineStore.load() {
        case let .loaded(loaded):
            linesLoaded = true
            lines = loaded
            if let unlockObserver {
                NotificationCenter.default.removeObserver(unlockObserver)
                self.unlockObserver = nil
                HeyDanShortcuts.updateAppShortcutParameters()
            }
            if !isCallActive { showLine(lines.selected) }
            if lines.entries.contains(where: { $0.agent == nil }) { Task { await nameLines() } }
        case .locked:
            guard unlockObserver == nil else { return }
            CallLog.log(.store, "keychain locked until the first unlock: lines load then", level: .error)
            unlockObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadLines() }
            }
        case .unreadable:
            break
        }
    }

    /// The saved lines are unreadable for now: nothing can be saved over them.
    var linesUnreadable: Bool { !linesLoaded }

    /// Reads the saved lines now if they could not be read yet (before the first unlock after a restart).
    func readLinesIfNeeded() {
        if !linesLoaded { loadLines() }
    }

    /// Saves `change` made to the saved lines. Lines that failed to load are read again first (a Keychain error can
    /// pass), so the change is made to what is really saved, never to an empty stand-in.
    private func keep(_ change: (inout VoiceLines) -> Void) -> Bool {
        if !linesLoaded { loadLines() }
        guard linesLoaded else {
            CallLog.log(.store, "line save refused: the saved lines could not be read", level: .error)
            return false
        }
        var next = lines
        change(&next)
        guard next != lines else { return true }
        guard LineStore.save(next) else { return false }
        lines = next
        HeyDanShortcuts.updateAppShortcutParameters()
        return true
    }
}

// MARK: - Transcript and spoken commands

extension CallController {
    /// The worker's captions and topics for this call's room; registered before it connects, so nothing early is
    /// missed, and dropped with the room. A stream from a room that is no longer the call's changes nothing.
    private func listen(to room: Room, names: VoiceProtocol.Names, for id: UUID) async {
        for topic in names.streamTopics {
            do {
                try await room.registerTextStreamHandler(for: topic) { [weak self] reader, sender in
                    let text = try await reader.readAll()
                    await self?.received(text, info: reader.info, sender: sender.stringValue, room: room, id: id)
                }
            } catch {
                trace(.stream, "register \(topic) failed \(CallLog.describe(error))", id, level: .error)
            }
        }
    }

    fileprivate enum StreamEvent: Sendable {
        case caption(segment: String, text: String, isFinal: Bool, fromCaller: Bool, command: SpokenCommand?)
        case turn(TurnMessage)
        case reply(ReplyInfo)
        case review(ReviewState)
    }

    /// Stream handlers finish in any order, so each event waits in `streams` until it is next in sending order.
    private func received(_ text: String, info: TextStreamInfo, sender: String, room: Room, id: UUID) {
        guard call?.id == id, room === call?.room, let names = call?.names else { return }
        call?.streamCounts[info.topic, default: 0] += 1
        let json = Data(text.utf8)
        let event: StreamEvent
        switch info.topic {
        case VoiceProtocol.transcriptionTopic:
            let attributes = info.attributes
            let segment = attributes[VoiceProtocol.segmentIDAttribute].flatMap { $0.isEmpty ? nil : $0 } ?? info.id
            // The worker transcribes the caller against the caller's own microphone track.
            let mic = room.localParticipant.audioTracks.first?.sid.stringValue
            let fromCaller = (mic != nil && attributes[VoiceProtocol.transcribedTrackAttribute] == mic)
                || sender == room.localParticipant.identity?.stringValue
            let isFinal = attributes[VoiceProtocol.transcriptionFinalAttribute] == "true"
            let command = fromCaller ? SpokenCommand(captionAttributes: attributes, names: names) : nil
            event = .caption(segment: segment, text: text, isFinal: isFinal, fromCaller: fromCaller, command: command)
        case names.turnTopic:
            guard let message = TurnMessage(json: json) else { return trace(.stream, "undecodable \(info.topic)", id, level: .error) }
            event = .turn(message)
        case names.replyTopic:
            guard let reply = try? JSONDecoder().decode(ReplyInfo.self, from: json) else {
                return trace(.stream, "undecodable \(info.topic)", id, level: .error)
            }
            event = .reply(reply)
        case names.reviewTopic:
            guard let state = try? JSONDecoder().decode(ReviewState.self, from: json) else {
                return trace(.stream, "undecodable \(info.topic)", id, level: .error)
            }
            event = .review(state)
        default:
            return
        }
        call?.streams.add(event, sentAt: info.timestamp, at: ContinuousClock.now)
        scheduleStreamFlush(id)
    }

    private func scheduleStreamFlush(_ id: UUID) {
        guard call?.id == id, call?.streamFlush == nil, let due = call?.streams.nextDue else { return }
        call?.streamFlush = Task { [weak self] in
            try? await Task.sleep(until: due)
            guard !Task.isCancelled, let self, call?.id == id else { return }
            call?.streamFlush = nil
            for event in call?.streams.release(at: ContinuousClock.now) ?? [] { apply(event, for: id) }
            scheduleStreamFlush(id)
        }
    }

    private func apply(_ event: StreamEvent, for id: UUID) {
        guard call?.id == id else { return }
        let now = Date()
        switch event {
        case let .caption(segment, text, isFinal, fromCaller, command):
            // A review recording's words are the draft's, never the transcript's.
            let known = transcript.knows(segment: segment)
            if fromCaller, editReview({ $0.caption(segment: segment, text: text, knownToTranscript: known) }) { return }
            editTranscript { $0.caption(segment: segment, text: text, isFinal: isFinal, fromCaller: fromCaller, command: command, at: now) }
        case let .turn(message):
            if case let .status(status) = message { editReview { $0.turnStatus(status) } }
            editTranscript { $0.apply(message, at: now) }
        case let .reply(reply):
            editTranscript { $0.apply(reply, at: now) }
        case let .review(state):
            var next = transcript
            guard let closeMic = editReview({ $0.receive(state, transcript: &next, micOn: !isMuted) }) else {
                return trace(.stream, "review state seq=\(state.seq) stale, have seq=\(reviewSession.seq)", id, level: .debug)
            }
            trace(
                .stream,
                "review state seq=\(state.seq) mode=\(state.mode.rawValue) draft=\(state.draft.map { "\($0.id)/\($0.state.rawValue)" } ?? "-") preparing=\(state.preparing)",
                id, level: .info
            )
            if next != transcript { transcript = next }
            if closeMic {
                trace(.call, "review recording stopped by the worker, mic closes", id)
                Task { _ = await setMic(false, for: id) }
            }
            let muted = isMuted
            if editReview({ $0.resyncedStateReopensMic(micMuted: muted) }) {
                trace(.call, "review initial switch unanswered, the worker runs hands-free: mic opens", id)
                Task { _ = await setMic(true, for: id) }
            }
            guard let wake = state.wake else { return }
            call?.workerWake = wake
            commands?.apply(wake)
            editTranscript { $0.apply(wake: wake, at: now) }
        }
    }

    /// Assigns only a real change, so an event that changes nothing re-renders nothing.
    private func editTranscript(_ edit: (inout Transcript) -> Void) {
        var next = transcript
        edit(&next)
        if next != transcript { transcript = next }
    }

    /// A caption whose final never comes (the transcription was cut off) stops reading as interim.
    private func startInterimTimer(_ id: UUID) {
        call?.interimTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, call?.id == id else { return }
                editTranscript { $0.settleStaleInterims(at: Date()) }
            }
        }
    }

    /// Once the worker announces its command words they are the call's, for the rest of it, and it marks the captions
    /// that hold one. Until then (an older worker never does) the built-in words stand in.
    private func refreshCommandWords(_ attributes: [String: String], names: VoiceProtocol.Names, for id: UUID) {
        guard let announced = CommandWords(attribute: attributes[names.commandWordsAttribute]) else { return }
        if !transcript.marksCommands {
            trace(.room, "command words announced send=\(announced.send.count) discard=\(announced.discard.count)", id, level: .info)
        }
        if announced != commandWords { commandWords = announced }
        editTranscript { $0.commandsAnnounced() }
    }

    /// Commands appear once the worker says it speaks this app's vocabulary, and the caller's picks go to it once
    /// per call right then: the worker holds its first cue until they come.
    private func refreshCommands(_ attributes: [String: String], names: VoiceProtocol.Names, for call: ActiveCall) {
        guard let version = attributes[names.commandsAttribute], VoiceProtocol.commandsVersions.contains(version) else {
            if commands != nil { commands = nil }
            return
        }
        if commands == nil {
            var settings = CommandSettings(picks: settingsPicks)
            // A wake state that came before the attribute still says whether the worker waits now.
            if let wake = call.workerWake {
                settings.waiting = wake.on && wake.waiting
                settings.phrase = wake.phrase
            }
            commands = settings
        }
        guard !call.settingsSent else { return }
        // The attribute can come before setup finished, and an RPC sent then never reaches the worker (RpcError 1501
        // after its timeout) while the worker holds its first cue for it. Setup's last refresh sends it.
        guard call.micPublished else { return trace(.rpc, "settings wait for setup", call.id, level: .debug) }
        self.call?.settingsSent = true
        let id = call.id
        trace(.rpc, "settings send once", id, level: .info)
        Task { await requestSettings(settingsPicks, for: id) }
    }

    /// Asks the worker to run `picks`, again when it does not answer (`VoiceProtocol.settingsAttempts` sends in all).
    /// Only the newest request's outcome counts: taken, the picks are kept for the next call; refused, `commands` goes
    /// back to what the worker runs; never acknowledged, the worker may have taken it anyway, so its state is read again.
    @discardableResult
    private func requestSettings(_ picks: SettingsPicks, for id: UUID) async -> Bool {
        guard call?.id == id else { return false }
        call?.settingsRequest += 1
        let request = call?.settingsRequest
        commands?.wake = picks.wake
        commands?.pauseSends = picks.pauseSends
        commands?.typing = picks.typing
        var reply = await settingsRPC(picks, for: id)
        // A newer request supersedes this one: retrying would put older picks back on the worker after it took them.
        for _ in 1 ..< VoiceProtocol.settingsAttempts where reply == nil && call?.id == id && call?.settingsRequest == request {
            reply = await settingsRPC(picks, for: id)
        }
        let taken = reply?.ok == true
        guard call?.id == id, call?.settingsRequest == request else { return taken }
        if taken {
            call?.takenPicks = picks
            commands?.cues = true
            commands?.typing = picks.typing
            keepPicks(picks)
        } else if reply != nil {
            commands?.revert(running: call?.workerWake, taken: call?.takenPicks ?? .defaults)
        } else {
            // The state the worker sends again carries its wake switch, which `commands` follows.
            trace(.rpc, "settings unanswered, asking the worker for its state again", id)
            let resynced = await reviewRPC(.mode, for: id)
            if resynced == nil, call?.id == id, call?.settingsRequest == request {
                commands?.revert(running: call?.workerWake, taken: call?.takenPicks ?? .defaults)
            }
        }
        return taken
    }

    /// The worker's answer to one settings request; nil when it did not answer or the call is over.
    private func settingsRPC(_ picks: SettingsPicks, for id: UUID) async -> ReviewReply? {
        guard let method = call?.names?.settingsMethod, let gen = nextRPCGen(for: id) else { return nil }
        call?.settingsSends += 1
        let ackTimeout = VoiceProtocol.settingsAckTimeout(send: call?.settingsSends ?? 0)
        return await workerRPC(
            method, payload: SettingsRequest(gen: gen, picks: picks).payload, ackTimeout: ackTimeout, for: id
        )
    }

    /// After a full reconnect the worker's state may have moved on: a mode request naming no mode makes it send
    /// its state again, never changes it.
    private func resyncWorkerState() {
        guard let id = call?.id, reviewSession.seq > 0 else { return }
        Task { _ = await reviewRPC(.mode, for: id) }
    }

    private func nextRPCGen(for id: UUID) -> Int? {
        guard call?.id == id else { return nil }
        call?.rpcGen += 1
        return call?.rpcGen
    }

    /// The worker takes these RPCs from the caller only, so they go to the agent participant from this one. Without
    /// the worker's ack within `ackTimeout` (LiveKit's default unless given) the request fails.
    @discardableResult
    private func workerRPC(
        _ method: String, payload: String, ackTimeout: TimeInterval = VoiceProtocol.rpcAckTimeout, for id: UUID
    ) async -> ReviewReply? {
        guard call?.id == id, let room = call?.room,
              let agent = room.remoteParticipants.values.first(where: \.isAgent)?.identity
        else { return nil }
        let asked = ContinuousClock.now
        do {
            let raw = try await room.localParticipant.performRpc(
                destinationIdentity: agent, method: method, payload: payload, responseTimeout: VoiceProtocol.rpcTimeout,
                maxRoundTripLatency: ackTimeout
            )
            let reply = ReviewReply(payload: raw)
            trace(
                .rpc, "\(method) ok=\(reply?.ok ?? false) gen=\(reply?.gen ?? -1) error=\(reply?.error ?? "-") ms=\(CallLog.ms(since: asked))", id,
                level: reply?.ok == true ? .default : .error
            )
            return call?.id == id ? reply : nil
        } catch {
            trace(.rpc, "\(method) failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: asked))", id, level: .error)
            return nil
        }
    }

    private func keepPicks(_ picks: SettingsPicks) {
        guard picks != settingsPicks else { return }
        settingsPicks = picks
        SettingsStore.save(picks)
    }
}

// MARK: - Review mode (Manual)

extension CallController {
    /// Hands-free or Manual. Outside a call it is only the pick for the next one; mid-call the worker has to take it,
    /// and then it is the pick too.
    func setTurnMode(_ mode: TurnMode) async {
        guard let id = call?.id else {
            if editReview({ $0.pickMode(mode) }) {
                TurnModeStore.save(mode)
                CallLog.log(.call, "review pick mode=\(mode.rawValue) (next call)")
            }
            return
        }
        guard case .live = phase, call?.micPublished == true, editReview({ $0.beginSwitch(to: mode) }) else {
            return trace(.call, "review mode=\(mode.rawValue) skipped phase=\(phase.logName) pending=\(review.pending?.op.rawValue ?? "-")", id, level: .info)
        }
        // Manual starts with the microphone off: it stops before the worker is asked.
        let openBefore = !isMuted
        if mode == .review, openBefore { _ = await setMic(false, for: id) }
        let reply = await reviewRPC(.mode, mode: mode, afterTurn: reviewSession.maxTurn, for: id)
        guard call?.id == id else { return }
        let taken = reply?.ok == true
        if taken, editReview({ $0.keepPick(mode) }) { TurnModeStore.save(mode) }
        trace(.call, "review mode=\(mode.rawValue) taken=\(taken) submitted=\(reply?.submitted.map(String.init) ?? "-")", id)
        // Hands-free listens: the microphone opens again once the worker took the switch, or when a switch to Manual
        // did not happen, unless muted by hand.
        if Review.reopensMic(to: mode, taken: taken, muted: isMuted, mutedByHand: reviewSession.mutedByHand, openBefore: openBefore) {
            _ = await setMic(true, for: id)
        }
        settle(reply, for: id, outcome: .init(note: taken && reply?.submitted != nil ? "Previous turn already submitted." : nil))
    }

    /// Opens a recording: the worker sets up its transcription first, then the microphone opens.
    func talk() async {
        guard let id = call?.id, case let .live(activity) = phase, activity != .speaking, editReview({ $0.beginTalk() })
        else { return skipped(.talk) }
        let reply = await reviewRPC(.talk, for: id)
        guard call?.id == id else { return }
        guard let reply, reply.ok, let draft = reply.draft else { return settle(reply, for: id) }
        if await setMic(true, for: id) {
            // A reply may have stopped the recording meanwhile: the microphone follows the worker.
            if let current = review.draft, current.id != draft || current.state != .recording {
                trace(.call, "review talk draft=\(draft) stopped by the worker meanwhile, mic closes", id)
                _ = await setMic(false, for: id)
            }
            return settle(reply, for: id)
        }
        guard call?.id == id else { return }
        trace(.call, "review talk draft=\(draft) mic did not open, discarding", id, level: .error)
        editReview { $0.micFailed(.start) }
        settle(await reviewRPC(.discard, draft: draft, for: id), for: id)
    }

    /// Ends the recording: the microphone stops, and the worker freezes what it heard into the draft.
    func done() async {
        guard let id = call?.id, let draft = editReview({ $0.beginDone() }) else { return skipped(.done) }
        if await !setMic(false, for: id), call?.id == id {
            trace(.call, "review done draft=\(draft) mic did not close", id, level: .error)
            editReview { $0.micFailed(.stop) }
        }
        settle(await reviewRPC(.done, draft: draft, for: id), for: id)
    }

    func send() async {
        guard let id = call?.id, let draft = editReview({ $0.beginSend() }) else { return skipped(.send) }
        let reply = await reviewRPC(.send, draft: draft, for: id)
        guard call?.id == id else { return }
        let taken = reply?.ok == true
        if taken, let turn = reply?.turn {
            trace(.call, "review sent draft=\(draft) turn=\(turn)", id)
            editReview { $0.sent(turn: turn) }
        }
        settle(reply, for: id, outcome: .init(delivery: taken ? .sending : nil))
    }

    /// Drops the draft: on the worker mid-call, here for one kept after the call.
    func discard() async {
        let live = if case .live = phase { true } else { false }
        let start = editReview { $0.beginDiscard(live: live) }
        guard case let .ask(draft) = start, let id = call?.id else {
            return start == .local ? CallLog.log(.call, "review discard: the kept draft dropped here") : skipped(.discard)
        }
        if !isMuted { _ = await setMic(false, for: id) }
        settle(await reviewRPC(.discard, draft: draft, for: id), for: id, outcome: .init(clearWords: true))
    }

    /// Manual is on offer once the worker says it runs it, and a call picked in Manual asks for it then, once.
    /// Without the attribute after its grace the worker has none: the call runs hands-free.
    private func refreshReview(_ attributes: [String: String], names: VoiceProtocol.Names, for id: UUID) {
        guard attributes[names.reviewAttribute] == "1" else {
            guard call?.reviewGrace == nil else { return }
            trace(.call, "review attribute absent, grace started", id, level: .info)
            call?.reviewGrace = Task { [weak self] in
                try? await Task.sleep(for: VoiceProtocol.agentAttributeGrace)
                guard let self, call?.id == id else { return }
                guard call?.room?.remoteParticipants.values.first(where: \.isAgent)?.attributes[names.reviewAttribute] != "1" else {
                    return trace(.call, "review grace ran out, worker offers it meanwhile", id, level: .info)
                }
                trace(.call, "review grace ran out: not offered, the call runs hands-free", id)
                let muted = isMuted
                if editReview({ $0.notOffered(micMuted: muted) }) {
                    trace(.call, "review not offered: hands-free opens the mic", id)
                    _ = await setMic(true, for: id)
                }
            }
            return
        }
        if call?.reviewOffered == false {
            call?.reviewOffered = true
            trace(.call, "review offered", id)
        }
        editReview { $0.offered() }
        guard editReview({ $0.beginInitialSwitch() }) else { return }
        trace(.call, "review initial switch asked", id)
        Task {
            let reply = await reviewRPC(.mode, mode: .review, afterTurn: reviewSession.maxTurn, for: id)
            // Refused, the worker stays in hands-free: so does the call, and its microphone opens unless muted by hand.
            // Unanswered, the state the worker sends again decides.
            let refused = ReviewSession.Outcome(note: "\(Review.modeName(.review)) didn't start - the call is \(Review.modeName(.auto)).", mode: .auto)
            let taken = reply?.ok == true
            trace(.call, "review initial switch taken=\(taken) answered=\(reply != nil)", id, level: taken ? .default : .error)
            let muted = isMuted
            guard call?.id == id else { return }
            let reopens = editReview { $0.initialSwitchReopensMic(reply, micMuted: muted) }
            settle(reply, for: id, outcome: reply.map { $0.ok ? .init() : refused } ?? .init())
            guard reopens else { return }
            trace(.call, "review initial switch refused: hands-free opens the mic", id)
            _ = await setMic(true, for: id)
        }
    }

    /// The operation in flight is answered (nil: it was not); nothing for a call that is over. Unanswered, the worker
    /// may have done it anyway, so its state is read again.
    private func settle(_ reply: ReviewReply?, for id: UUID, outcome: ReviewSession.Outcome = .init()) {
        guard call?.id == id else { return }
        let agentName = agentName
        guard editReview({ $0.settle(reply, agentName: agentName, outcome: outcome) }) else { return }
        trace(.rpc, "review unanswered, asking the worker for its state again", id)
        resyncWorkerState()
    }

    /// A key pressed in a state that has no such operation (another one in flight, the wrong draft state).
    private func skipped(_ op: Review.Op) {
        trace(.call, "review \(op.rawValue) skipped phase=\(phase.logName) pending=\(review.pending?.op.rawValue ?? "-") draft=\(review.draft.map { "\($0.id)/\($0.state.rawValue)" } ?? "-")", level: .info)
    }

    /// One review operation on the worker; nil when it did not answer, answered another request, or the call is over.
    private func reviewRPC(
        _ op: Review.Op, draft: Int? = nil, mode: TurnMode? = nil, afterTurn: Int? = nil, for id: UUID
    ) async -> ReviewReply? {
        guard let names = call?.names, let gen = nextRPCGen(for: id) else { return nil }
        let request = ReviewRequest(gen: gen, draft: draft, mode: mode, afterTurn: afterTurn)
        trace(.rpc, "review \(op.rawValue) ask gen=\(gen) draft=\(draft.map(String.init) ?? "-") mode=\(mode?.rawValue ?? "-")", id, level: .info)
        let reply = await workerRPC(names.method(op), payload: request.payload, for: id)
        if let reply, reply.gen != gen {
            trace(.rpc, "review \(op.rawValue) reply dropped: gen=\(reply.gen) answers another request than gen=\(gen)", id, level: .error)
            return nil
        }
        return reply
    }

    /// Manual opens and closes the microphone itself, apart from the caller's own mute; true once the track did it.
    private func setMic(_ on: Bool, for id: UUID) async -> Bool {
        let followed = await applyMute(!on, for: id)
        reportMute(for: id)
        guard followed else { return false }
        return call?.mic.map { $0.isMuted == !on } ?? false
    }

    /// Shows CallKit (lock screen, AirPods) the microphone as the app left it, so its mute key never claims otherwise.
    private func reportMute(for id: UUID) {
        guard call?.id == id else { return }
        let action = CXSetMutedCallAction(call: id, muted: isMuted)
        appMuteActions.insert(action.uuid)
        Task {
            do { try await callKit.request(CXTransaction(action: action)) } catch {
                appMuteActions.remove(action.uuid)
                trace(.callkit, "mute report failed \(CallLog.describe(error))", id, level: .error)
            }
        }
    }

    /// The caller's own mute (the key, CallKit): back in hands-free the microphone stays as they left it.
    private func muteByHand(_ muted: Bool, for id: UUID) async -> Bool {
        let done = await applyMute(muted, for: id)
        if call?.id == id, done { reviewSession.mutedByHand = muted }
        return done
    }

    /// Assigns only a real change, so an event that changes nothing re-renders nothing; a new note goes after a while.
    @discardableResult
    private func editReview<Result>(_ edit: (inout ReviewSession) -> Result) -> Result {
        var next = reviewSession
        let result = edit(&next)
        reviewSession = next
        if next.review != review {
            if let note = next.review.note, note != review.note { expireNote(note) }
            review = next.review
        }
        if next.words != draftWords { draftWords = next.words }
        return result
    }

    private func expireNote(_ note: String) {
        reviewNoteTimer?.cancel()
        reviewNoteTimer = Task { [weak self] in
            try? await Task.sleep(for: Review.noteDuration)
            guard !Task.isCancelled else { return }
            self?.editReview { $0.noteExpired(note) }
        }
    }
}

// MARK: - CallKit

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_: CXProvider) {
        MainActor.assumeIsolated {
            trace(.callkit, "provider reset", level: .error)
            if let id = call?.id { finish(id, Ending(cause: .failure, message: "The call was reset."), endedBy: nil) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let id = action.callUUID
        let current = MainActor.assumeIsolated { call?.id == id }
        MainActor.assumeIsolated { trace(.callkit, "perform start current=\(current)", id) }
        guard current else { return action.fail() }
        provider.reportOutgoingCall(with: id, startedConnectingAt: nil)
        action.fulfill()
        MainActor.assumeIsolated {
            Self.configureAudioSession()
            startActivationTimer(id)
            #if targetEnvironment(simulator)
            activateAudioByHand()
            #endif
            connect(id)
        }
    }

    nonisolated func provider(_: CXProvider, perform action: CXEndCallAction) {
        let id = action.callUUID
        action.fulfill()
        MainActor.assumeIsolated {
            trace(.callkit, "perform end", id)
            finish(id, .byCaller, endedBy: nil)
        }
    }

    nonisolated func provider(_: CXProvider, perform action: CXSetMutedCallAction) {
        let id = action.callUUID
        let muted = action.isMuted
        let actionID = action.uuid
        // CallKit actions are not Sendable; this one is only fulfilled or failed, on the main queue it came from.
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            // CallKit resets the mute of a call that just ended (systemInitiated); there is no microphone left to move.
            guard call?.id == id else {
                trace(.callkit, "perform mute muted=\(muted) for a call that is over", id, level: .info)
                return action.fail()
            }
            let decision = review.callKitMute(muted, reportedByApp: appMuteActions.remove(actionID) != nil)
            trace(.callkit, "perform mute muted=\(muted) \(decision)", id, level: decision == .acknowledge ? .info : .default)
            switch decision {
            case .acknowledge: action.fulfill()
            case .refuse: action.fail()
            case .apply:
                _ = Task {
                    if await muteByHand(muted, for: id) { action.fulfill() } else { action.fail() }
                }
            }
        }
    }

    nonisolated func provider(_: CXProvider, didActivate _: AVAudioSession) {
        MainActor.assumeIsolated { audioActivated(by: "callkit") }
    }

    private func audioActivated(by activator: String) {
        trace(.callkit, "audio session activated by=\(activator)")
        call?.activationTimer?.cancel()
        setEngine(.default)
    }

    #if targetEnvironment(simulator)
    /// The Simulator's callservicesd cannot activate an app's audio session from outside the app (it logs "Error
    /// setting audio active to true" with OSStatus -50), so `didActivate` never comes there. Once the start action is
    /// fulfilled the app activates the session itself, where CallKit would, and the rest of the call runs as on a phone.
    private func activateAudioByHand() {
        do { try AVAudioSession.sharedInstance().setActive(true) } catch {
            return trace(.callkit, "simulator audio activation failed \(CallLog.describe(error))", level: .error)
        }
        audioActivated(by: "simulator")
    }

    /// What `didDeactivate` would follow with on a phone.
    private static func deactivateAudioByHand() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            CallLog.log(.callkit, "simulator audio session deactivated")
        } catch {
            CallLog.log(.callkit, "simulator audio deactivation failed \(CallLog.describe(error))", level: .error)
        }
    }
    #endif

    nonisolated func provider(_: CXProvider, didDeactivate _: AVAudioSession) {
        MainActor.assumeIsolated { trace(.callkit, "audio session deactivated") }
        setEngine(.none)
    }

    nonisolated func provider(_: CXProvider, timedOutPerforming action: CXAction) {
        let name = String(describing: type(of: action))
        MainActor.assumeIsolated { trace(.callkit, "timed out performing \(name)", level: .error) }
    }
}

// MARK: - LiveKit

extension CallController: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from old: ConnectionState) {
        let reconnected = old == .reconnecting && state == .connected
        Task { @MainActor in
            guard room === call?.room else { return }
            trace(.room, "state \(old) -> \(state)")
            if reconnected { resyncWorkerState() }
            refresh()
        }
    }

    #if DEBUG
    /// A quick reconnect (an ICE restart, what a network change asks for first) never reaches the connection state.
    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in if room === call?.room { trace(.room, "reconnect start mode=\(reconnectMode)") } }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in if room === call?.room { trace(.room, "reconnect done mode=\(reconnectMode)") } }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard participant.isAgent, let track = publication.track as? RemoteAudioTrack else { return }
        let sid = publication.sid.stringValue
        if ProcessInfo.processInfo.environment["HEYDAN_AUDIO_METER"] == "1" { track.add(audioRenderer: AudioMeter.track) }
        Task { @MainActor in if room === call?.room { trace(.room, "agent audio subscribed sid=\(sid)") } }
    }
    #endif

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let who = "sid=\(participant.sid?.stringValue ?? "-") agent=\(participant.isAgent)"
        Task { @MainActor in
            guard room === call?.room else { return }
            trace(.room, "joined \(who)")
            refresh()
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateAttributes changed: [String: String]) {
        let agentAttributes = participant.isAgent ? participant.attributes : nil
        Task { @MainActor in
            guard room === call?.room else { return }
            if let agentAttributes, let names = call?.names {
                trace(.room, "agent \(Self.attributeSummary(agentAttributes, changed: changed, names: names))", level: .info)
            }
            refresh()
        }
    }

    /// The worker's protocol attributes as they stand now (`-`: not set) and which of them this update changed:
    /// states and versions only, nothing the caller said.
    private static func attributeSummary(_ current: [String: String], changed: [String: String], names: VoiceProtocol.Names) -> String {
        let keys = [
            VoiceProtocol.agentStateAttribute, names.thinkingAttribute, names.updatingAttribute, names.commandsAttribute,
            names.reviewAttribute, names.protocolAttribute,
        ].compactMap(\.self)
        func name(_ key: String) -> Substring { key.split(separator: ".").last ?? "" }
        let values = keys.map { "\(name($0))=\(current[$0] ?? "-")" }.joined(separator: " ")
        let changedKeys = keys.filter { changed[$0] != nil }.map(name).joined(separator: ",")
        return "\(values) changed=[\(changedKeys)]"
    }

    nonisolated func room(_ room: Room, participant _: LocalParticipant, remoteDidSubscribeTrack _: LocalTrackPublication) {
        Task { @MainActor in if room === call?.room { trace(.room, "agent subscribed to the mic") } }
    }

    nonisolated func room(_ room: Room, didUpdateMetadata metadata: String?) {
        guard let reason = VoiceProtocol.endReasonText(roomMetadata: metadata) else { return }
        Task { @MainActor in
            guard room === call?.room else { return }
            trace(.room, "host named the end")
            call?.endReason = reason
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        // A full reconnect drops every remote participant before it rejoins; that is not the agent leaving.
        let who = "sid=\(participant.sid?.stringValue ?? "-")"
        let state = room.connectionState
        guard participant.isAgent, state != .reconnecting else {
            Task { @MainActor in if room === call?.room { trace(.room, "left \(who) state=\(state) (not the end)") } }
            return
        }
        let reason = VoiceProtocol.endReasonText(roomMetadata: room.metadata)
        Task { @MainActor in
            if room === call?.room { trace(.room, "agent left \(who)") }
            roomEnded(room, reason: reason, fallback: "\(agentName) left the call.")
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let reason = VoiceProtocol.endReasonText(roomMetadata: room.metadata)
        let cause = error.map { CallLog.describe($0) } ?? "none"
        Task { @MainActor in
            if room === call?.room { trace(.room, "disconnected error=\(cause)") }
            roomEnded(room, reason: reason, fallback: "The call ended.")
        }
    }
}

// MARK: - Settings

/// The caller's picks for spoken commands and the typing sound; nothing secret, so plain defaults.
private enum SettingsStore {
    private static let key = "voice-settings"

    static func load() -> SettingsPicks {
        guard let data = UserDefaults.standard.data(forKey: key),
              let picks = try? JSONDecoder().decode(SettingsPicks.self, from: data)
        else { return .defaults }
        return picks
    }

    static func save(_ picks: SettingsPicks) {
        guard let data = try? JSONEncoder().encode(picks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The caller's turn mode pick (hands-free or Manual), kept for the next call.
private enum TurnModeStore {
    private static let key = "voice-turn-mode"

    static func load() -> TurnMode {
        UserDefaults.standard.string(forKey: key).flatMap(TurnMode.init(rawValue:)) ?? .auto
    }

    static func save(_ mode: TurnMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

// MARK: - Keychain

/// The call links hold their lines' bearer tokens: kept on this device only, readable after the first unlock so a
/// launch in the background, or a call already running when the phone locks, can still read them. One item holds
/// every line; the single link older versions kept moves into it on first load.
private enum LineStore {
    private static let service = Bundle.main.bundleIdentifier ?? "HeyDan"
    private static let account = "voice-lines"
    private static let legacyAccount = "call-link"

    enum Load {
        case loaded(VoiceLines)
        /// Before the first unlock since boot: the item is there but out of reach until then.
        case locked
        /// Neither absent nor readable: it must not be overwritten.
        case unreadable
    }

    static func load() -> Load {
        switch read(account) {
        case let .found(data):
            guard let lines = try? JSONDecoder().decode(VoiceLines.self, from: data) else { return setAside(data) }
            let unreadable = lines.unreadableCount
            CallLog.log(
                .store, "keychain lines loaded lines=\(lines.entries.count) unreadable=\(unreadable)",
                level: unreadable > 0 ? .error : .default
            )
            return .loaded(lines)
        case let .failed(status):
            return status == errSecInteractionNotAllowed ? .locked : .unreadable
        case .absent:
            break
        }
        switch read(legacyAccount) {
        case .absent:
            return .loaded(VoiceLines())
        case let .failed(status):
            return status == errSecInteractionNotAllowed ? .locked : .unreadable
        case let .found(legacy):
            let lines = VoiceLines(legacyLink: String(decoding: legacy, as: UTF8.self))
            let saved = save(lines)
            if saved { delete(legacyAccount) }
            CallLog.log(.store, "keychain migrated call-link lines=\(lines.entries.count) saved=\(saved)", level: saved ? .default : .error)
            return .loaded(lines)
        }
    }

    /// An item that holds no list of lines at all is copied to an account of its own, never read again but never
    /// lost, and the lines start empty; while the copy fails the item stays as it is and nothing is saved over it.
    private static func setAside(_ data: Data) -> Load {
        let backup = "\(account)-unreadable-\(Int(Date().timeIntervalSince1970))"
        let status = SecItemAdd(
            query(backup).merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { $1 } as CFDictionary,
            nil
        )
        guard status == errSecSuccess else {
            CallLog.log(.store, "keychain lines unreadable, set aside failed status=\(status)", level: .error)
            return .unreadable
        }
        CallLog.log(.store, "keychain lines unreadable: set aside as \(backup), lines start empty")
        delete(account)
        return .loaded(VoiceLines())
    }

    static func save(_ lines: VoiceLines) -> Bool {
        guard let data = try? JSONEncoder().encode(lines) else {
            CallLog.log(.store, "keychain save failed: lines did not encode", level: .error)
            return false
        }
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query(account) as CFDictionary, fields as CFDictionary)
        let added = updated == errSecItemNotFound
        let status = added ? SecItemAdd(query(account).merging(fields) { $1 } as CFDictionary, nil) : updated
        CallLog.log(
            .store, "keychain save \(added ? "add" : "update") status=\(status) lines=\(lines.entries.count)",
            level: status == errSecSuccess ? .default : .error
        )
        return status == errSecSuccess
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private enum Read {
        case found(Data)
        /// The normal answer for a phone with no lines yet, or none from an older version.
        case absent
        case failed(OSStatus)
    }

    private static func read(_ account: String) -> Read {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = item as? Data else {
            CallLog.log(.store, "keychain load \(account) status=\(status)", level: .error)
            return .failed(status)
        }
        return .found(data)
    }

    private static func delete(_ account: String) {
        let status = SecItemDelete(query(account) as CFDictionary)
        CallLog.log(.store, "keychain delete \(account) status=\(status)", level: status == errSecSuccess ? .default : .error)
    }
}

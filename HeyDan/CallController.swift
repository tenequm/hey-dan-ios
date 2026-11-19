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

    private(set) var pairedCallTarget: CallTarget?
    private(set) var captionOrder: Int64 = 0

    func matches(_ target: PairedCallTarget) -> Bool {
        guard let paired = pairedCallTarget?.paired else { return false }
        return paired.host == target.host && paired.deviceId == target.deviceId && paired.conversation.id == target.conversation.id
    }

    @discardableResult
    func openActiveConversation() -> Bool {
        guard isCallActive, let paired = pairedCallTarget?.paired,
              Pairings.shared.entries.contains(where: { $0.host == paired.host && $0.deviceId == paired.deviceId }) else { return false }
        if Pairings.shared.active?.host != paired.host {
            do { try Pairings.shared.setActive(host: paired.host) } catch { return false }
        }
        ChatController.shared.openConversation(paired.conversation.id)
        return true
    }


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
    private(set) var agentName = "Agent"
    /// The call's live transcript: cleared when a call starts, kept readable (all final) after it ends.
    private(set) var transcript = Transcript()
    /// Auto mode's spoken-command settings: nil unless this call's worker speaks the commands vocabulary this
    /// app knows (`Names.commandsAttribute` in `VoiceProtocol.commandsVersions`).
    private(set) var commands: CommandSettings?
    /// The spoken commands hints quote: the ones this call's worker announced, else the built-in ones.
    private(set) var commandWords = CommandWords.builtIn
    /// The caller's picks: where every call starts, changed by `updateSettings`.
    private(set) var settingsPicks = SettingsStore.load()
    private(set) var liveVoice: CallVoiceState?

    var isCallActive: Bool {
        switch phase {
        case .connecting, .live, .reconnecting: true
        case .idle, .ended: false
        }
    }

    /// Everything one call owns, created when it starts and dropped in one assignment when it ends,
    /// so a late callback from an earlier call can never touch the current one.
    private struct ActiveCall {
        let id: UUID
        let target: CallTarget
        let claimedAt = ContinuousClock.now
        var callId: String?
        var grant: CallTarget.Grant?
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
        var stateSequence = 0
        /// The wake state the worker last said it runs.
        var workerWake: WakeState?
        /// The `gen` of the last RPC sent, and the newest settings request: only its outcome counts.
        var rpcGen = 0
        var voice: LiveVoice?
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
    /// Created on the first call, not at launch: on iOS 27 a provider made right after unlock (an Action Button
    /// launch) can be left without `didActivate` (Apple developer forums thread 837211).
    @ObservationIgnored private var provider: CXProvider?
    @ObservationIgnored private let callKit = CXCallController()
    /// Mute actions the app asked CallKit for to show a microphone it moved itself: their `perform` only fulfils them.
    @ObservationIgnored private var appMuteActions: Set<UUID> = []

    /// DTX off on every publish, a republish after a full reconnect included: the worker times the caller's turn by
    /// the silence it hears.
    private static let micPublishOptions = AudioPublishOptions(dtx: VoiceProtocol.micDTX, red: false)

    static let setupBound = VoiceProtocol.agentJoinTimeout + .seconds(20)

    override private init() {
        super.init()
        CallActivity.follow(self)
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

    func start(target: CallTarget) async -> UUID? {
        guard !isCallActive else {
            trace(.call, "start refused: call active")
            return nil
        }
        let id = UUID()
        // Claimed before any await, so a second tap or Action Button press finds the call already active.
        pairedCallTarget = target
        call = ActiveCall(id: id, target: target)
        call?.voice = LiveVoice(callID: id)
        liveVoice = nil
        agentName = target.paired.conversation.agent.name
        phase = .connecting
        openActiveConversation()
        captionOrder = ChatController.shared.thread.compactMap(\.order).max() ?? target.paired.conversation.readOrder
        transcript = Transcript()
        commands = nil
        commandWords = .builtIn
        trace(.call, "claim paired=true")
        #if DEBUG
        // Tests end every call, one the App Intent started too, this many seconds after it was claimed.
        if let seconds = ProcessInfo.processInfo.environment["HEYDAN_HANGUP_AFTER"].flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                if self?.call?.id == id { self?.hangUp() }
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if fixtureCall {
            phase = .live(.speaking)
            transcript.caption(segment: "sample", text: "Checking the backup.", isFinal: false, fromCaller: false, at: .now)
            return id
        }
        #endif
        await place(id)
        return id
    }

    private func place(_ id: UUID) async {
        VoiceMessagePlayback.shared.recording?.finish(.interrupted)
        VoiceMessagePlayback.shared.stop()
        await VoiceSample.stop()
        trace(.audio, "sample stop drained", id)
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

    #if DEBUG && targetEnvironment(simulator)
    private var fixtureCall: Bool {
        call?.target.service is FixtureAppService && ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_LIVE_CALL"] == "1"
    }
    #endif

    func hangUp() {
        guard let id = call?.id else { return }
        #if DEBUG && targetEnvironment(simulator)
        if fixtureCall { return finish(id, .byCaller, endedBy: nil) }
        #endif
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
        #if DEBUG && targetEnvironment(simulator)
        if fixtureCall { isMuted = muted; return }
        #endif
        trace(.call, "mute asked muted=\(muted)")
        Task { try? await callKit.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) }
    }

    /// During a call the worker must accept the change before it is kept for the next call.
    @discardableResult
    func updateSettings(typing: Bool) async -> Bool {
        var picks = commands.map { SettingsPicks(wake: $0.wake, pauseSends: $0.pauseSends, typing: $0.typing) } ?? settingsPicks
        picks.typing = typing
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
        guard let target = call?.target else { return }
        call?.connectTask = Task {
            do {
                let grant: CallTarget.Grant
                let asked = ContinuousClock.now
                do { grant = try await target.grant() } catch {
                    trace(.net, "token failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: asked))", id, level: .error)
                    throw error
                }
                guard call?.id == id else { return endOnHost(target, callId: grant.callId) }
                call?.callId = grant.callId
                call?.grant = grant
                trace(.net, "token ok protocol=\(grant.names.version) ms=\(CallLog.ms(since: asked))", id)
                let names = grant.names
                if let agent = grant.agent, !agent.isEmpty { setAgentName(agent, for: id) }
                let room = Room(delegate: self, roomOptions: RoomOptions(defaultAudioPublishOptions: Self.micPublishOptions))
                call?.room = room
                await listen(to: room, names: names, for: id)
                guard call?.id == id else { return }
                let connecting = ContinuousClock.now
                trace(.room, "connect start ice=\(target.usesRelay ? "relay" : "all")", id)
                do { try await room.connect(url: grant.url, token: grant.token, connectOptions: ConnectOptions(iceTransportPolicy: target.usesRelay ? .relay : .all)) } catch {
                    trace(.room, "connect failed \(CallLog.describe(error)) ms=\(CallLog.ms(since: connecting))", id, level: .error)
                    throw CallFailure.pairedTransport
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

    private func setAgentName(_ name: String, for id: UUID) {
        agentName = name
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
        refreshVoice(attributes, names: names, for: call.id)
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
    }

    /// Before `room.connect` returned this is the SDK cleaning up a connect that failed; `connect` reports that.
    private func roomEnded(_ room: Room, reason: String?, fallback: String) {
        guard let call, room === call.room else { return }
        guard call.roomConnected else { return trace(.room, "room end ignored before connect", level: .debug) }
        finish(call.id, Ending(cause: .remote, message: reason ?? call.endReason ?? fallback), endedBy: .remoteEnded)
    }

    /// Ends call `id` everywhere, once: on the host, in LiveKit and, unless CallKit asked, in CallKit.
    private func finish(
        _ id: UUID, _ ending: Ending, endedBy reason: CXCallEndedReason?, hostReason: CallTarget.EndReason? = nil,
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
        liveVoice = nil
        #if DEBUG && targetEnvironment(simulator)
        VoiceDebug.callEnded(id)
        #endif
        appMuteActions.removeAll()
        ended.connectTask?.cancel()
        ended.agentTimer?.cancel()
        ended.activationTimer?.cancel()
        ended.interimTimer?.cancel()
        if let callId = ended.callId {
            endOnHost(ended.target, callId: callId, reason: hostReason)
        } else {
            Task {
                do { try await ended.target.cancel() }
                catch { CallLog.log(.net, "call cancel failed \(CallLog.describe(error))", level: .error) }
            }
        }
        if let room = ended.room {
            let topics = ended.names?.streamTopics ?? []
            Task {
                for topic in topics { await room.unregisterTextStreamHandler(for: topic) }
                await room.disconnect()
            }
        }
        editTranscript { $0.end() }
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

    @ObservationIgnored private var hostEnd: Task<Void, Never>?
    #if DEBUG
    func waitForHostEnd() async { await hostEnd?.value }
    #endif

    private func endOnHost(_ target: CallTarget, callId: String, reason: CallTarget.EndReason? = nil) {
        hostEnd = Task {
            try? await target.end(callId: callId, reason: reason)
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
        case review(WorkerTurnState)
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
            guard let state = try? JSONDecoder().decode(WorkerTurnState.self, from: json) else {
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
            #if DEBUG
            if isFinal, !text.isEmpty {
                trace(.stream, "e2e caption final caller=\(fromCaller)", id)
            }
            #endif
            editTranscript { $0.caption(segment: segment, text: text, isFinal: isFinal, fromCaller: fromCaller, command: command, at: now) }
        case let .turn(message):
            editTranscript { $0.apply(message, at: now) }
        case let .reply(reply):
            #if DEBUG
            trace(.stream, "e2e reply turn=\(reply.turn != nil) notice=\(reply.notice == true) unspoken=\(reply.unspoken == true)", id)
            #endif
            editTranscript { $0.apply(reply, at: now) }
        case let .review(state):
            guard state.seq > (call?.stateSequence ?? 0) else { return }
            call?.stateSequence = state.seq
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
            let resynced = await requestWorkerState(id)
            if resynced == nil, call?.id == id, call?.settingsRequest == request {
                commands?.revert(running: call?.workerWake, taken: call?.takenPicks ?? .defaults)
            }
        }
        return taken
    }

    /// The worker's answer to one settings request; nil when it did not answer or the call is over.
    private func settingsRPC(_ picks: SettingsPicks, for id: UUID) async -> WorkerReply? {
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
        guard let id = call?.id, call?.stateSequence != 0 else { return }
        Task { _ = await requestWorkerState(id) }
    }

    private func requestWorkerState(_ id: UUID) async -> WorkerReply? {
        guard let method = call?.names?.stateMethod, let gen = nextRPCGen(for: id) else { return nil }
        return await workerRPC(method, payload: "{\"gen\":\(gen)}", for: id)
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
        _ method: String, payload: String, ackTimeout: TimeInterval = VoiceProtocol.rpcAckTimeout, traceReply: Bool = true, for id: UUID
    ) async -> WorkerReply? {
        guard call?.id == id, let room = call?.room,
              let agent = room.remoteParticipants.values.first(where: \.isAgent)?.identity
        else { return nil }
        let asked = ContinuousClock.now
        do {
            let raw = try await room.localParticipant.performRpc(
                destinationIdentity: agent, method: method, payload: payload, responseTimeout: VoiceProtocol.rpcTimeout,
                maxRoundTripLatency: ackTimeout
            )
            let reply = WorkerReply(payload: raw)
            if traceReply {
                trace(
                    .rpc, "\(method) ok=\(reply?.ok ?? false) gen=\(reply?.gen ?? -1) error=\(reply?.error ?? "-") ms=\(CallLog.ms(since: asked))", id,
                    level: reply?.ok == true ? .default : .error
                )
            }
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

extension CallController {
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
            if appMuteActions.remove(actionID) != nil { action.fulfill() } else {
                _ = Task {
                    if await applyMute(muted, for: id) { action.fulfill() } else { action.fail() }
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

    #endif

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in
            guard room === call?.room else { return }
            trace(.room, "reconnect done mode=\(reconnectMode)")
            refresh()
        }
    }

    #if DEBUG
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
            names.protocolAttribute, names.voiceAttribute,
        ].compactMap(\.self)
        func name(_ key: String) -> Substring { key.split(separator: ".").last ?? "" }
        let values = keys.map { key in
            if key == names.voiceAttribute {
                guard let voice = current[key].flatMap(CallVoiceState.init(attribute:)) else { return "voice=-" }
                return "voice=gen:\(voice.gen ?? -1),active:\(voice.active.provider)/\(voice.active.model ?? "-")/\(voice.active.voice ?? "-"),pending:\(voice.pending?.provider ?? "-")/\(voice.pending?.model ?? "-")/\(voice.pending?.voice ?? "-")"
            }
            return "\(name(key))=\(current[key] ?? "-")"
        }.joined(separator: " ")
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


// MARK: - Live voice

extension CallController {
    var liveVoiceService: (any VoicePickerService)? { call?.target.voicePickerService }

    var liveCallID: UUID? {
        return call?.id
    }

    func requestVoice(_ choice: TTSChoice, for id: UUID) async -> VoiceRequestOutcome {
        guard call?.id == id else { return .over }
        guard liveVoice != nil, let method = call?.names?.settingsMethod else { return .unsupported }
        guard call?.voice?.inFlight == false else {
            trace(.rpc, "voice request skipped: one in flight", id)
            return .unconfirmed
        }
        guard let gen = nextRPCGen(for: id), call?.voice?.begin(choice, gen: gen, for: id) == true else { return .unsupported }
        let reply = await workerRPC(method, payload: VoiceRequest(gen: gen, tts: choice).payload, traceReply: false, for: id)
        guard call?.id == id else { return .over }
        if let reply, reply.gen == gen {
            call?.voice?.apply(reply: reply, for: id)
        } else {
            call?.voice?.timeout(gen: gen, for: id)
        }
        refresh()
        guard call?.id == id else { return .over }
        let outcome = call?.voice?.outcome ?? .unconfirmed
        let label: String
        switch outcome {
        case .queued: label = "queued"
        case let .refused(reason):
            let code = ["tts_invalid", "tts_unavailable", "closed", "stale"].contains(reason) ? reason : "refused"
            label = "refused(\(code))"
        case .unconfirmed, .unsupported, .over: label = "unconfirmed"
        }
        trace(.rpc, "voice gen=\(gen) outcome=\(label)", id)
        return outcome
    }

    private func refreshVoice(_ attributes: [String: String], names: VoiceProtocol.Names, for id: UUID) {
        guard call?.id == id else { return }
        let attribute = names.voiceAttribute.flatMap { attributes[$0] }
        call?.voice?.apply(attribute: attribute, for: id)
        let state = call?.voice?.state
        if liveVoice != state { liveVoice = state }
    }
}

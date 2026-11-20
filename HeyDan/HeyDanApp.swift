import AppIntents
import Intents
import HeyDanCore
import LiveKit
#if DEBUG
import AVFAudio
import os
#endif
#if targetEnvironment(simulator)
import ObjectiveC.runtime
#endif
import SwiftUI
import Security

@main
struct HeyDanApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    @State private var redialError: String?
    @State private var pairedHost: Pairings.Entry?
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #if DEBUG
    private let uiTest = ProcessInfo.processInfo.environment["HEYDAN_UITEST"] == "1"
    #endif

    init() {
        // Before anything touches LiveKit: its logger is fixed on first use. Debug builds keep the SDK's own story of
        // every call (subsystem io.livekit.sdk) next to the app's; Release keeps LiveKit's default, info and above.
        #if DEBUG
        if uiTest { UIView.setAnimationsEnabled(false) }
        LiveKitSDK.setLogLevel(.debug)
        #endif
        #if targetEnvironment(simulator)
        SimulatorICE.gatherOnAnyAddress()
        #endif
        CallLog.log(.call, "launch")
    }

    private static func removeLegacyLinks() {
        let defaults = UserDefaults.standard
        let marker = "removedLegacyCallLinksAndBackups"
        guard IdentityKeychain.callTestRun == nil, !defaults.bool(forKey: marker) else { return }
        if removeLegacyLinks(service: Bundle.main.bundleIdentifier ?? "HeyDan") {
            defaults.set(true, forKey: marker)
        }
    }

    static func removeLegacyLinks(service: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        var search = base
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return false }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { return false }
            guard account == "voice-lines" || account == "call-link" || account.hasPrefix("voice-lines-unreadable-") else { continue }
            var query = base
            query[kSecAttrAccount as String] = account
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        }
        return true
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                #if targetEnvironment(simulator)
                if let path = ProcessInfo.processInfo.environment["HEYDAN_CAPTURE_REQUEST"] {
                    ScreenCaptureFixture(requestURL: URL(fileURLWithPath: path))
                } else { debugRoot }
                #else
                debugRoot
                #endif
                #else
                root
                #endif
            }
                .environment(\.pairingConfirmation, $pairedHost)
                .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
                    guard let intent = activity.interaction?.intent as? INStartCallIntent else { return }
                    Task {
                        do {
                            guard let id = IntentCall.redialAgent(in: intent) else { throw IntentCall.unavailableAgent }
                            try await IntentCall.run(agentID: id, inBackground: false, exactAgent: true)
                        } catch let error as IntentCall.CallNotStarted { redialError = error.message }
                        catch { redialError = error.localizedDescription }
                    }
                }
                .alert("Could not redial", isPresented: Binding(get: { redialError != nil }, set: { if !$0 { redialError = nil } })) {
                    Button("OK") { redialError = nil }
                } message: { Text(redialError ?? "") }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    Self.removeLegacyLinks()
                    ChatController.shared.setActive(phase != .background)
                    if phase == .active { CallController.shared.prepareStartImpact() }
                    if phase == .background { wasBackgrounded = true }
                    if phase == .active, wasBackgrounded {
                        wasBackgrounded = false
                        if CallController.shared.openActiveConversation() { pairedHost = nil }
                    }
                }
                .sensoryFeedback(trigger: CallController.shared.phase) { old, new in
                    Self.callFeedback(from: old, to: new, liveSince: CallController.shared.liveSince)
                }
                .environment(\.theme, Theme.dark)
                .preferredColorScheme(.dark)
                .environment(ChatController.shared)
                .environment(CallController.shared)
                #if DEBUG
                .task { await Self.debugScript() }
                .transaction { if uiTest { $0.disablesAnimations = true; $0.animation = nil } }
                #endif
        }
    }

    static func callFeedback(from old: CallController.Phase, to new: CallController.Phase, liveSince: Date?) -> SensoryFeedback? {
        switch new {
        case .live where old.isStarting: .success
        case .ended(let ending): CallController.isFailure(ending, liveSince: liveSince) ? .error : .impact(weight: .light)
        default: nil
        }
    }

    #if DEBUG
    @ViewBuilder private var debugRoot: some View {
        if let name = ProcessInfo.processInfo.environment["HEYDAN_GALLERY"] {
            if name.hasPrefix("List/") { ConversationListSpecimen(name: name) }
            else { Gallery(name: name) }
        } else { root }
    }
    #endif

    @ViewBuilder private var root: some View {
        if let pairedHost {
            PairingView(paired: pairedHost)
        } else if showsPairingForChecks {
            PairingView()
        } else if ChatController.shared.pairing != nil {
            ConversationList()
        } else {
            PairingView()
        }
    }

    /// Pairing checks open the pairing screen even on a Simulator an earlier check left paired.
    private var showsPairingForChecks: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["HEYDAN_SHOW_PAIRING"] == "1"
        #else
        false
        #endif
    }
}

#if DEBUG
extension HeyDanApp {
    /// `just sim-call` and `just device-call` drive a real call end to end: HEYDAN_AUTOCALL starts it,
    /// HEYDAN_HANGUP_AFTER (seconds; CallController ends every call by it) ends it, and HEYDAN_FEED_WAV (48 kHz mono;
    /// a relative path is under the app's Caches) is what the caller says, HEYDAN_FEED_AFTER seconds after launch (the
    /// call starts at launch too). HEYDAN_STEPS (`seconds:step,...`, timed from launch) presses keys mid-call; see
    /// `DebugStep`.
    @MainActor
    static func debugScript() async {
        let env = ProcessInfo.processInfo.environment
        if env["HEYDAN_E2E_MIC_PERMISSION"] == "1" {
            _ = await AVAudioApplication.requestRecordPermission()
            return
        }
        #if targetEnvironment(simulator)
        let launched = ContinuousClock.now
        // Read here, not in App.init: before a scene connects the content size category is still unspecified.
        CallLog.log(.call, "a11y reduceMotion=\(UIAccessibility.isReduceMotionEnabled) contentSize=\(UIApplication.shared.preferredContentSizeCategory.rawValue)")
        if let steps = env["HEYDAN_VOICE_STEPS"], !steps.isEmpty { VoiceDebug.schedule(steps, launched: launched) }
        #endif
        if env["HEYDAN_AUDIO_METER"] == "1" { AudioManager.shared.add(remoteAudioRenderer: AudioMeter.playout) }
        if env["HEYDAN_CHAT_CHECKS"] == "1", env["HEYDAN_CHECK_REVOKED_REQUEST"] == "1" {
            let path = URL.cachesDirectory.appending(path: "revoked-request.json").path
            let chat = ChatController.shared
            let deadline = ContinuousClock.now + .seconds(30)
            while chat.conversations.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            do {
                guard let client = chat.service as? SignedClient else { return }
                let request = try client.checkRevocationRequest()
                let data = try JSONSerialization.data(withJSONObject: ["url": request.url!.absoluteString,
                    "authorization": request.value(forHTTPHeaderField: "Authorization")!])
                guard FileManager.default.createFile(atPath: path, contents: data,
                    attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else { return }
            } catch { CallLog.log(.net, "check revocation prepare_failed") }
            return
        }
        if env["HEYDAN_CHAT_CHECKS"] == "1", env["HEYDAN_CHECK_VOICE"] == "1" || env["HEYDAN_CHECK_HISTORY"] == "1" {
            let chat = ChatController.shared
            let deadline = ContinuousClock.now + .seconds(30)
            while chat.conversations.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let conversation = chat.conversations.first else { return }
            if env["HEYDAN_CHECK_HISTORY"] == "1" {
                do {
                    let newest = try await chat.service.history(conversationId: conversation.id, query: HistoryQuery(limit: 1))
                    guard let last = newest.items.compactMap(\.order).last else { return }
                    let before = try await chat.service.history(conversationId: conversation.id, query: HistoryQuery(before: last, limit: 1))
                    guard let previous = before.items.compactMap(\.order).last, previous < last else { return }
                    let after = try await chat.service.history(conversationId: conversation.id, query: HistoryQuery(after: previous, limit: 1))
                    CallLog.log(.net, "check history before=true after=\(after.items.compactMap(\.order).first == last)")
                } catch { CallLog.log(.net, "check history failed") }
                return
            }
            do {
                let original = try await chat.service.voice(conversationId: conversation.id)
                let saved = original.saved
                let restore: TTSPatch = saved.provider.map { .choice(TTSChoice(provider: $0, model: saved.model, voice: saved.voice)) } ?? .reset
                var matched = false
                do {
                    let choice = original.effective
                    _ = try await chat.service.updateVoice(conversationId: conversation.id,
                        request: .choice(choice))
                    let readback = try await chat.service.voice(conversationId: conversation.id)
                    matched = readback.saved == SavedTTSChoice(provider: choice.provider, model: choice.model, voice: choice.voice)
                } catch { CallLog.log(.net, "check voice save_failed") }
                _ = try await chat.service.updateVoice(conversationId: conversation.id, request: restore)
                let restored = try await chat.service.voice(conversationId: conversation.id)
                CallLog.log(.net, "check voice saved=\(matched) restored=\(restored.saved == saved)")
            } catch { CallLog.log(.net, "check voice failed") }
            return
        }
        guard env["HEYDAN_AUTOCALL"] == "1", let run = IdentityKeychain.callTestRun else { return }
        if let steps = env["HEYDAN_STEPS"], !steps.isEmpty { DebugStep.schedule(steps) }
        var feed: Task<Void, Never>?
        defer { feed?.cancel() }
        if let path = env["HEYDAN_FEED_WAV"], !path.isEmpty {
            // No microphone at all: the engine takes the frames AudioFeed hands it. On a phone iOS still
            // activates the call's session and gates the engine; a manual-rendering engine just never uses the device.
            do {
                try AudioManager.shared.setManualRenderingMode(true)
                CallLog.log(.audio, "debug feed: manual rendering on")
            } catch {
                CallLog.log(.audio, "debug feed: manual rendering failed \(CallLog.describe(error))", level: .error)
            }
            let delay = env["HEYDAN_FEED_AFTER"].flatMap(Double.init) ?? 8
            #if targetEnvironment(simulator)
            let gated = env["HEYDAN_FEED_ON_VOICE"] == "1"
            if gated { VoiceDebug.gateFeed(launched: launched) }
            feed = Task.detached {
                await AudioFeed.run(path: path, after: delay, gated: gated)
            }
            #else
            feed = Task.detached { await AudioFeed.run(path: path, after: delay) }
            #endif
        }
        do {
            try await IntentCall.readyPairings()
            if let link = env["HEYDAN_CALL_PAIR_LINK"] {
                guard Pairings.shared.entries.isEmpty else { throw AppError.callActive }
                try await Pairings.shared.pair(link)
            }
            guard let entry = Pairings.shared.active else { throw AppError.notPaired }
            CallLog.log(.net, "test pair run=\(run) device=\(entry.deviceId)")
            if env["HEYDAN_CALL_CLEANUP"] != "1" {
                let agent = try IntentCall.testAgent(in: entry, expected: env["HEYDAN_CALL_AGENT"])
                if env["HEYDAN_CALL_SEED"] == "1" {
                    CallLog.log(.net, "test intent ready run=\(run)")
                    return
                }
                let target = try await IntentCall.pairedTarget(id: PairedAgentID.make(host: entry.host, agentId: agent.id))
                _ = await CallController.shared.start(target: target)
                while CallController.shared.isCallActive { try await Task.sleep(for: .milliseconds(100)) }
                await CallController.shared.waitForHostEnd()
            }
        } catch { CallLog.log(.call, "debug autocall refused") }
        if let entry = Pairings.shared.active {
            let failure = await ChatController.shared.unpair(host: entry.host)
            CallLog.log(.net, "test unpair run=\(run) ok=\(failure == nil)")
        } else if env["HEYDAN_CALL_CLEANUP"] == "1", Pairings.shared.state == .none {
            CallLog.log(.net, "test unpair run=\(run) ok=true")
        }
    }
}

private enum DebugStep: String {
    case mute, unmute

    /// Steps press keys on the first call they find on, and only while it is on: one due after it ended would
    /// otherwise make its switch the next call's pick, or start a next call's recording.
    @MainActor private static var owner: UUID?

    @MainActor
    static func schedule(_ script: String) {
        let launched = ContinuousClock.now
        for item in script.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]), let step = DebugStep(rawValue: String(parts[1])) else {
                CallLog.log(.call, "debug step unreadable: \(item)", level: .error)
                continue
            }
            Task { @MainActor in
                try? await Task.sleep(until: launched + .seconds(at))
                let controller = CallController.shared
                guard let id = controller.callID, id == Self.owner ?? id else {
                    return CallLog.log(.call, "debug step \(step.rawValue) at=\(at)s dropped: its call is over")
                }
                Self.owner = id
                CallLog.log(.call, "debug step \(step.rawValue) at=\(at)s")
                await step.run(controller)
            }
        }
    }

    @MainActor
    private func run(_ controller: CallController) async {
        switch self {
        case .mute: controller.setMuted(true)
        case .unmute: controller.setMuted(false)
        }
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum VoiceDebug {
    nonisolated static let feedDeadline = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    private static var firstVoiceOutcome: VoiceRequestOutcome?
    private static var feedGated = false
    private static var feedTriggered = false
    private static var voiceSteps: Task<Void, Never>?
    private static var feedTimer: Task<Void, Never>?
    private static var voiceFeedTimer: Task<Void, Never>?
    static func callEnded(_ id: UUID) {
        voiceSteps?.cancel()
        feedTimer?.cancel()
        voiceFeedTimer?.cancel()
    }

    static func schedule(_ script: String, launched: ContinuousClock.Instant) {
        let steps = script.split(separator: ",").compactMap { item -> (Double, TTSChoice)? in
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]), at.isFinite, at >= 0 else { return nil }
            let choice = parts[1].split(separator: "/", maxSplits: 1)
            guard choice.count == 2 else { return nil }
            return (at, TTSChoice(provider: String(choice[0]), voice: String(choice[1])))
        }.sorted { $0.0 < $1.0 }
        voiceSteps = Task {
            let controller = CallController.shared
            var owner: UUID?
            for (at, choice) in steps {
                do { try await Task.sleep(until: launched + .seconds(at)) } catch { return }
                while controller.liveVoice == nil {
                    guard !Task.isCancelled else { return }
                    if let owner, controller.liveCallID != owner { return }
                    if case .ended = controller.phase { return }
                    if owner == nil { owner = controller.liveCallID }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let id = controller.liveCallID, id == owner ?? id else { return }
                owner = id
                let outcome = await controller.requestVoice(choice, for: id)
                if firstVoiceOutcome == nil {
                    firstVoiceOutcome = outcome
                    if case .queued = outcome { triggerFeed("voice") }
                }
            }
        }
    }

    static func gateFeed(launched: ContinuousClock.Instant) {
        feedGated = true
        if case .queued = firstVoiceOutcome { triggerFeed("voice") }
        feedTimer = Task {
            do { try await Task.sleep(until: launched + .seconds(30)) } catch { return }
            triggerFeed("timeout", deadline: launched + .seconds(30))
        }
    }

    private static func triggerFeed(_ trigger: String, deadline: ContinuousClock.Instant? = nil) {
        guard feedGated, !feedTriggered else { return }
        guard let deadline else {
            voiceFeedTimer = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                triggerFeed(trigger, deadline: .now)
            }
            return
        }
        feedTriggered = true
        feedDeadline.withLock { $0 = deadline }
        CallLog.log(.audio, "feed trigger=\(trigger)")
    }
}
#endif

#if targetEnvironment(simulator)
/// LiveKit's WebRTC keeps only the interfaces on the default network path, and in the Simulator that leaves out the
/// Mac's Tailscale utun (Tailscale does not own the default route), so a tailnet-only LiveKit gets no candidate.
/// WebRTC's any-address ports (0.0.0.0) let the Mac's routing take the tunnel. LiveKit 2.17 does not expose the
/// setting, so every peer connection's configuration gets it on its way into WebRTC; device builds are untouched.
private enum SimulatorICE {
    static func gatherOnAnyAddress() {
        let selector = NSSelectorFromString("createNativeConfiguration")
        guard let type = NSClassFromString("LKRTCConfiguration"), let method = class_getInstanceMethod(type, selector) else {
            return assertionFailure("LKRTCConfiguration.createNativeConfiguration is gone")
        }
        typealias Native = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        let original = unsafeBitCast(method_getImplementation(method), to: Native.self)
        let replacement: @convention(block) (NSObject) -> UnsafeMutableRawPointer? = { configuration in
            configuration.setValue(true, forKey: "enableIceGatheringOnAnyAddressPorts")
            return original(configuration, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
#endif

#if DEBUG
/// HEYDAN_AUDIO_METER=1: what the app plays, measured, so a reply is checked in the log and not by ear. `playout` is the
/// mix of every remote track on its way to the speaker (WebRTC's render stream, pulled only while the output plays);
/// `track` is the agent's track as decoded. Each logs its first buffer, then every second that has sound in it.
final class AudioMeter: NSObject, AudioRenderer, @unchecked Sendable {
    static let playout = AudioMeter("playout")
    static let track = AudioMeter("track")

    private struct Window {
        var started: ContinuousClock.Instant?
        var frames = 0
        var squares = 0.0
        var peak = 0.0
        var seenFirst = false
    }

    private let name: String
    private let window = OSAllocatedUnfairLock(initialState: Window())
    /// Quieter than this is the silence between words, or none at all.
    private static let soundFloor = -55.0

    private init(_ name: String) { self.name = name }

    func render(pcmBuffer buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var squares = 0.0
        var peak = 0.0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0 ..< count {
                let value = Double(samples[index])
                squares += value * value
                peak = max(peak, abs(value))
            }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0 ..< count {
                let value = Double(samples[index]) / 32768
                squares += value * value
                peak = max(peak, abs(value))
            }
        } else { return }
        let now = ContinuousClock.now
        let (bufferSquares, bufferPeak) = (squares, peak)
        let (first, closed) = window.withLock { window -> (Bool, Window?) in
            let first = !window.seenFirst
            window.seenFirst = true
            if window.started == nil { window.started = now }
            window.frames += count
            window.squares += bufferSquares
            window.peak = max(window.peak, bufferPeak)
            guard let started = window.started, now - started >= .seconds(1) else { return (first, nil) }
            let closed = window
            window = Window(seenFirst: true)
            return (first, closed)
        }
        let name = name
        if first {
            let format = "sr=\(Int(buffer.format.sampleRate)) ch=\(buffer.format.channelCount) frames=\(count)"
            Task { @MainActor in CallController.shared.trace(.audio, "meter \(name) first buffer \(format)") }
        }
        guard let closed, closed.frames > 0 else { return }
        let rms = 20 * log10(max((closed.squares / Double(closed.frames)).squareRoot(), 1e-9))
        guard rms > Self.soundFloor else { return }
        let peakDB = 20 * log10(max(closed.peak, 1e-9))
        Task { @MainActor in
            CallController.shared.trace(.audio, "meter \(name) rms=\(Int(rms.rounded()))dBFS peak=\(Int(peakDB.rounded()))dBFS")
        }
    }
}

/// HEYDAN_SIMULATE (e.g. `quick@15,full@40`): LiveKit's own test scenarios, each this many seconds after the call went
/// live, to drive the reconnect paths a network change takes on a phone. `quick` and `full` are the client's
/// reconnects; `node`, `migration` and `leave` ask the server for a node failure, a migration or a server leave.
enum ReconnectDrill {
    @MainActor
    static func run(on room: Room, for id: UUID) {
        guard let plan = ProcessInfo.processInfo.environment["HEYDAN_SIMULATE"], !plan.isEmpty else { return }
        for step in plan.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let seconds = Double(parts[1]), let scenario = scenario(String(parts[0])) else {
                CallLog.log(.room, "drill step unreadable: \(step)", level: .error)
                continue
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard CallController.shared.isCurrent(id) else { return }
                CallController.shared.trace(.room, "drill \(parts[0]) asked", id)
                do {
                    try await room.debug_simulate(scenario: scenario)
                    CallController.shared.trace(.room, "drill \(parts[0]) sent", id)
                } catch {
                    CallController.shared.trace(.room, "drill \(parts[0]) failed \(CallLog.describe(error))", id, level: .error)
                }
            }
        }
    }

    private static func scenario(_ name: String) -> SimulateScenario? {
        switch name {
        case "quick": .quickReconnect
        case "full": .fullReconnect
        case "node": .nodeFailure
        case "migration": .migration
        case "leave": .serverLeave
        default: nil
        }
    }
}

/// Feeds the call 10 ms frames in real time: silence, the file once, then silence, like a caller who speaks and stops.
/// Silence keeps flowing because the worker ends a turn on the silence it hears.
private enum AudioFeed {
    static func run(path: String, after delay: Double, gated: Bool = false) async {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else { return }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL.cachesDirectory.appending(path: path)
        let speech = load(url, format: format)
        CallLog.log(.audio, "debug feed: wav frames=\(speech?.frameLength ?? 0) after=\(delay)s", level: speech == nil ? .error : .default)
        let frame: AVAudioFrameCount = 480
        let clock = ContinuousClock()
        let start = clock.now
        var next = start
        var offset: AVAudioFrameCount = 0
        while !Task.isCancelled {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frame), let out = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = frame
            out.update(repeating: 0, count: Int(frame))
            let ready: Bool
            #if targetEnvironment(simulator)
            ready = gated ? VoiceDebug.feedDeadline.withLock { $0.map { clock.now >= $0 } ?? false } : clock.now - start >= .seconds(delay)
            #else
            ready = clock.now - start >= .seconds(delay)
            #endif
            if ready, let speech, let source = speech.floatChannelData?[0], offset < speech.frameLength {
                let count = min(frame, speech.frameLength - offset)
                out.update(from: source + Int(offset), count: Int(count))
                offset += count
            }
            AudioManager.shared.mixer.capture(appAudio: buffer)
            next += .milliseconds(10)
            try? await clock.sleep(until: next)
        }
    }

    private static func load(_ url: URL, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.sampleRate == format.sampleRate, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try? file.read(into: buffer)
        return buffer
    }
}
#endif

/// The backup to Call agent: it always opens Hey Dan (after Face ID on a locked phone) and starts the call there. A
/// plain intent's start from the background fails the system's user-intent check, and one from the app in front passes.
struct StartConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start conversation"
    static let description = IntentDescription("Opens Hey Dan and calls a NanoClaw agent in its chat.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Agent", description: "Choose a paired agent or use the default from Settings.")
    var line: VoiceLineEntity?

    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$line)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentCall.run(agentID: line?.id, inBackground: false)
        return .result()
    }
}

/// What the Action Button runs (see the README for the shortcut it needs). iOS 27's phone start-call schema is what
/// lets iOS take a start from the background, on a locked phone too: the system vouches for the user's intent,
/// which it does not for a plain intent. The shortcut saves the agent and the call type (Audio), not Ask Each Time.
@AppIntent(schema: .phone.startCall)
struct CallLineIntent: AudioRecordingIntent, LiveActivityIntent {
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    var destination: CallDestination
    /// Voice only: a video call is placed as a voice call.
    var audioVisualMode: CallAVMode

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let mode = systemContext.currentMode == .background ? "background" : "foreground"
        CallLog.log(.intent, "intent call-agent start mode=\(mode) unlocked=\(UIApplication.shared.isProtectedDataAvailable)")
        let agentID: UUID? = if case let .line(agent) = destination { agent.id } else { nil }
        try await startPairedCall(agentID: agentID)
        return .result()
    }
}

extension AppIntent {
    @MainActor func startPairedCall(agentID: UUID?) async throws {
        do {
            try await IntentCall.run(agentID: agentID, inBackground: systemContext.currentMode == .background)
        } catch let error as IntentCall.CallNotStarted where error.message == IntentCall.backgroundRefused {
            guard systemContext.currentMode.canContinueInForeground else { throw error }
            try await continueInForeground(alwaysConfirm: false)
            try await IntentCall.run(agentID: agentID, inBackground: false)
        }
    }
}

/// Keep the intent alive until iOS has started the call or the caller can be shown the failure.
@MainActor
enum IntentCall {
    static let backgroundRefused = "iOS did not let Hey Dan start the call from the background. Use Start conversation, "
        + "or open Hey Dan and call from there."

    struct CallNotStarted: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    static let unavailableAgent = CallNotStarted(message: "This agent is no longer available to call.")

    static func redialAgent(in intent: INStartCallIntent) -> UUID? {
        let contacts = intent.contacts ?? []
        let people = contacts.isEmpty ? intent.callRecordToCallBack?.participants ?? [] : contacts
        guard people.count == 1, let handle = people.first?.personHandle?.value, let id = UUID(uuidString: handle),
              id != AgentEntity.defaultID else { return nil }
        return id
    }

    static func donate(_ target: PairedCallTarget, name: String) {
        let intent = CallLineIntent()
        intent.destination = .line(AgentEntity(id: target.agentHandle, agent: name, source: "Paired agent"))
        intent.audioVisualMode = .audio
        Task {
            do { _ = try await intent.donate() }
            catch { CallLog.log(.intent, "call donation failed \(CallLog.describe(error))", level: .error) }
        }
    }

    /// `inBackground`: run with no app on screen, so nothing but the thrown error can tell the caller what went wrong.
    static func run(agentID: UUID?, inBackground: Bool, exactAgent: Bool = false) async throws {
        let began = ContinuousClock.now
        let controller = CallController.shared
        let acknowledged = controller.acknowledgeStart()
        try await readyPairings()
        if controller.isCallActive {
            CallLog.log(.intent, "a call is on already: not started")
            return
        }
        let target = try await pairedTarget(id: agentID, exactAgent: exactAgent)
        guard let id = await controller.start(target: target, acknowledged: acknowledged) else { return }
        let deadline = ContinuousClock.now + CallController.setupBound
        while controller.isConnecting(id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let failed = controller.failure(of: id)
        CallLog.log(
            .intent, "wait done phase=\(controller.phase.logName) ms=\(CallLog.ms(since: began))", level: failed == nil ? .default : .error
        )
        if let failed { throw notStarted(failed, inBackground) }
    }

    static func readyPairings() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while Pairings.shared.state == .unreadable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if Pairings.shared.state == .unreadable {
            throw CallNotStarted(message: AppError.keyUnavailable.message)
        }
    }

    #if DEBUG
    static func testAgent(in entry: Pairings.Entry, expected: String?) throws -> HeyDanCore.Agent {
        guard entry.agents.count == 1, let agent = entry.agents.first else {
            CallLog.log(.call, "debug autocall refused agent_count")
            throw AppError.notPaired
        }
        guard let expected, !expected.isEmpty, agent.name.caseInsensitiveCompare(expected) == .orderedSame else {
            CallLog.log(.call, "debug autocall refused agent_name")
            throw AppError.notPaired
        }
        return agent
    }
    #endif

    static func pairedTarget(id: UUID?, exactAgent: Bool = false) async throws -> CallTarget {
        let entries = Pairings.shared.entries.filter { $0.features.contains("calls") }
        var preference = UserDefaults.standard.string(forKey: "defaultCallAgent").flatMap(UUID.init(uuidString:))
        #if DEBUG
        if IdentityKeychain.callTestRun != nil { preference = nil }
        #endif
        guard !Pairings.shared.entries.isEmpty else { throw CallNotStarted(message: "Open Hey Dan and pair a host to call an agent.") }
        func pick(_ id: UUID?) -> (Pairings.Entry, HeyDanCore.Agent)? {
            guard let id, id != AgentEntity.defaultID else { return nil }
            return entries.lazy.compactMap { entry in
                entry.agents.first { PairedAgentID.make(host: entry.host, agentId: $0.id) == id }.map { (entry, $0) }
            }.first
        }
        let requested = pick(id)
        if exactAgent, requested == nil { throw unavailableAgent }
        let active = Pairings.shared.active
        let automatic = active.flatMap { entry in
            entry.features.contains("calls") ? entry.agents.first.map { (entry, $0) } : nil
        }
        guard let (entry, agent) = requested ?? (preference == nil ? automatic : pick(preference)) else {
            throw CallNotStarted(message: "Choose an available paired agent in Settings or Shortcuts.")
        }
        let found: (conversation: Conversation?, service: any AppService)
        do { found = try await ChatController.shared.pairedConversation(agentId: agent.id, entry: entry) }
        catch { throw CallNotStarted(message: error.message) }
        guard let conversation = found.conversation else {
            throw CallNotStarted(message: "This agent has no conversation yet.")
        }
        guard conversation.canCall else {
            throw CallNotStarted(message: conversation.callRefusal?.message ?? "Calling is unavailable.")
        }
        guard let current = Pairings.shared.entries.first(where: { $0.host == entry.host && $0.deviceId == entry.deviceId }) else {
            throw CallNotStarted(message: "This host is no longer paired.")
        }
        #if DEBUG
        if IdentityKeychain.callTestRun != nil {
            let allowed = try testAgent(in: current, expected: ProcessInfo.processInfo.environment["HEYDAN_CALL_AGENT"])
            guard allowed == conversation.agent else { throw AppError.notPaired }
        }
        #endif
        return CallTarget(paired: PairedCallTarget(host: current.host, deviceId: current.deviceId,
            conversation: conversation), service: found.service)
    }


    private static func notStarted(_ ending: CallController.Ending, _ inBackground: Bool) -> CallNotStarted {
        if inBackground, case .callKitRefused = ending.failure { return CallNotStarted(message: backgroundRefused) }
        return CallNotStarted(message: ending.message)
    }
}

@UnionValue
enum CallDestination {
    case line(VoiceLineEntity)
}

@AppEnum(schema: .phone.audioVisualMode)
enum CallAVMode: String {
    case audio
    case video

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.audio: "Audio", .video: "Video"]
}

// Shortcuts persists the entity type name, destination case and parameter name.
typealias AgentEntity = VoiceLineEntity

@AppEntity(schema: .phone.phonePerson)
struct VoiceLineEntity {
    static let defaultQuery = AgentQuery()
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static var defaultAgent: Self { Self(defaultFor: defaultID) }

    fileprivate init(defaultFor id: UUID) {
        self.init(id: id, agent: "Default agent", source: "Hey Dan Settings")
    }

    let id: UUID
    let agent: String
    var person: IntentPerson

    let source: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(agent)", subtitle: "\(source)") }

    init(id: UUID, agent: String, source: String) {
        self.id = id
        self.agent = agent
        self.source = source
        person = IntentPerson(identifier: .applicationDefined(id.uuidString), name: .displayName(agent), handle: nil)
    }
}

struct AgentQuery: EntityStringQuery {
    func suggestedEntities() async -> [AgentEntity] {
        try? await IntentCall.readyPairings()
        return await MainActor.run {
            [AgentEntity.defaultAgent] + Pairings.shared.entries.filter { $0.features.contains("calls") }.flatMap { entry in
                    entry.agents.map { AgentEntity(entry: entry, agent: $0) }
                }
        }
    }

    func entities(for identifiers: [UUID]) async -> [AgentEntity] {
        let available = await suggestedEntities()
        return identifiers.map { id in
            available.first { $0.id == id } ?? AgentEntity(defaultFor: id)
        }
    }

    func entities(matching string: String) async -> [AgentEntity] {
        await suggestedEntities().filter { $0.agent.localizedStandardContains(string) }
    }

    func defaultResult() async -> AgentEntity? { .defaultAgent }
}

extension AgentEntity {
    init(entry: Pairings.Entry, agent: HeyDanCore.Agent) {
        self.init(id: PairedAgentID.make(host: entry.host, agentId: agent.id), agent: agent.name,
            source: entry.host.host() ?? "Paired host")
    }
}

struct HeyDanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartConversationIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start a conversation with \(.applicationName)",
                "Call \(\.$line) with \(.applicationName)",
                "Talk to \(\.$line) with \(.applicationName)",
            ],
            shortTitle: "Start conversation",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: CallLineIntent(),
            phrases: ["Call an agent with \(.applicationName)"],
            shortTitle: "Call agent",
            systemImageName: "phone"
        )
    }
}

import AppIntents
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

@main
struct HeyDanApp: App {
    init() {
        // Before anything touches LiveKit: its logger is fixed on first use. Debug builds keep the SDK's own story of
        // every call (subsystem io.livekit.sdk) next to the app's; Release keeps LiveKit's default, info and above.
        #if DEBUG
        LiveKitSDK.setLogLevel(.debug)
        #endif
        #if targetEnvironment(simulator)
        SimulatorICE.gatherOnAnyAddress()
        #endif
        CallLog.log(.call, "launch")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(CallController.shared)
                #if DEBUG
                .task { await Self.debugScript() }
                #endif
        }
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
        if env["HEYDAN_AUDIO_METER"] == "1" { AudioManager.shared.add(remoteAudioRenderer: AudioMeter.playout) }
        guard env["HEYDAN_AUTOCALL"] == "1" else { return }
        if let steps = env["HEYDAN_STEPS"], !steps.isEmpty { DebugStep.schedule(steps) }
        if let path = env["HEYDAN_FEED_WAV"], !path.isEmpty {
            // No microphone at all: the engine takes the frames AudioFeed hands it. On a phone CallKit still
            // activates the call's session and gates the engine; a manual-rendering engine just never uses the device.
            do {
                try AudioManager.shared.setManualRenderingMode(true)
                CallLog.log(.audio, "debug feed: manual rendering on")
            } catch {
                CallLog.log(.audio, "debug feed: manual rendering failed \(CallLog.describe(error))", level: .error)
            }
            let delay = env["HEYDAN_FEED_AFTER"].flatMap(Double.init) ?? 8
            Task.detached { await AudioFeed.run(path: path, after: delay) }
        }
        await CallController.shared.start()
    }
}

/// A key the caller presses mid-call. `mute` and `unmute` go through the key's own path, a CXSetMutedCallAction
/// requested from CXCallController that the app did not mark as its own: exactly what the lock screen and AirPods send.
private enum DebugStep: String {
    case mute, unmute, manual, handsfree, talk, done, send, discard

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
        case .manual: await controller.setTurnMode(.review)
        case .handsfree: await controller.setTurnMode(.auto)
        case .talk: await controller.talk()
        case .done: await controller.done()
        case .send: await controller.send()
        case .discard: await controller.discard()
        }
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
    static func run(path: String, after delay: Double) async {
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
            if clock.now - start >= .seconds(delay), let speech, let source = speech.floatChannelData?[0], offset < speech.frameLength {
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
/// plain intent's start from the background fails CallKit's user-intent check, and one from the app in front passes.
struct StartConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start conversation"
    static let description = IntentDescription("Opens Hey Dan and calls a NanoClaw agent on its voice line.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Line", description: "The agent to call. Empty calls the line picked in Hey Dan's settings.")
    var line: VoiceLineEntity?

    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$line)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentCall.run(lineID: line?.id, inBackground: false)
        return .result()
    }
}

/// What the Action Button runs (see the README for the shortcut it needs). iOS 27's phone start-call schema is what
/// lets CallKit take a start from the background, on a locked phone too: the system vouches for the user's intent,
/// which it does not for a plain intent. The shortcut saves the agent and the call type (Audio), not Ask Each Time.
@AppIntent(schema: .phone.startCall)
struct CallLineIntent: AudioRecordingIntent, LiveActivityIntent {
    static let supportedModes: IntentModes = [.background]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    var destination: CallDestination
    /// Voice only: a video call is placed as a voice call.
    var audioVisualMode: CallAVMode

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let mode = systemContext.currentMode == .background ? "background" : "foreground"
        CallLog.log(.intent, "intent call-agent start mode=\(mode) unlocked=\(UIApplication.shared.isProtectedDataAvailable)")
        let lineID: UUID? = if case let .line(line) = destination { line.id } else { nil }
        try await IntentCall.run(lineID: lineID, inBackground: true)
        return .result()
    }
}

/// Starting a call from an intent: stays until the call is up or failed, so a failure (the tailnet down, most often)
/// shows where it was asked.
@MainActor
enum IntentCall {
    static let backgroundRefused = "iOS did not let Hey Dan start the call from the background. Use Start conversation, "
        + "or open Hey Dan and call from there."

    struct CallNotStarted: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    /// `inBackground`: run with no app on screen, so nothing but the thrown error can tell the caller what went wrong.
    static func run(lineID: UUID?, inBackground: Bool) async throws {
        let began = ContinuousClock.now
        let controller = CallController.shared
        // A process launched before the first unlock after a restart could not read the lines; unlocked, it can.
        controller.readLinesIfNeeded()
        CallLog.log(.intent, "start line=\(lineID.map(CallController.short) ?? "picked") lines=\(controller.lines.entries.count)")
        if controller.lines.entries.isEmpty {
            CallLog.log(.intent, "no line: \(inBackground ? "failed" : "the app shows its settings")")
            if inBackground { throw CallNotStarted(message: CallFailure.noLine.message) }
            return
        }
        guard let id = await controller.start(lineID: lineID) else {
            if case let .ended(ending) = controller.phase, ending.cause == .failure { throw notStarted(ending, inBackground) }
            CallLog.log(.intent, "a call is on already: not started")
            return
        }
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

    /// A CallKit refusal in the background is no fault of the line: the caller needs the way that works, not a retry.
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

/// A saved voice line as Shortcuts and Siri see it: the agent's name and an id that is not the link, which stays secret.
@AppEntity(schema: .phone.phonePerson)
struct VoiceLineEntity {
    static let defaultQuery = VoiceLineQuery()

    let id: UUID
    let agent: String
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(agent)") }

    init(id: UUID, agent: String) {
        self.id = id
        self.agent = agent
        person = IntentPerson(identifier: .applicationDefined(id.uuidString), name: .displayName(agent), handle: nil)
    }
}

struct VoiceLineQuery: EntityStringQuery {
    func suggestedEntities() async -> [VoiceLineEntity] {
        await MainActor.run {
            CallController.shared.lines.entries.map { VoiceLineEntity(id: $0.id, agent: $0.name.capitalizedFirst) }
        }
    }

    func entities(for identifiers: [UUID]) async -> [VoiceLineEntity] {
        await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async -> [VoiceLineEntity] {
        await suggestedEntities().filter { $0.agent.localizedStandardContains(string) }
    }

    /// The line picked in the app, so a new shortcut starts with it filled in.
    func defaultResult() async -> VoiceLineEntity? {
        await MainActor.run {
            CallController.shared.lines.selected.map { VoiceLineEntity(id: $0.id, agent: $0.name.capitalizedFirst) }
        }
    }
}

private extension String {
    /// "your agent" heads a list as "Your agent"; a host's name stays as it wrote it.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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

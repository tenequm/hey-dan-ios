import AVFAudio
import HeyDanCore
import LiveKit
import Observation
import Speech

protocol CallSpeechPlayout: AnyObject {
    var name: String { get }
    var volume: Double { get set }
}

extension RemoteAudioTrack: CallSpeechPlayout {}

private struct PreparedCallSpeech {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let format: AVAudioFormat
    let locale: Locale

    static func prepare(locale: Locale) async throws -> Self? {
        var preset = SpeechTranscriber.Preset.progressiveTranscription
        preset.attributeOptions.formUnion([.audioTimeRange, .transcriptionConfidence])
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        let modules: [any SpeechModule] = [SpeechDetector(), transcriber]
        try Task.checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { return nil }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        return Self(analyzer: analyzer, transcriber: transcriber, format: format, locale: locale)
    }
}

@Observable @MainActor
final class CallSpeech {
    static let interruptMethod = "nanoclaw.voice-mode.interrupt"
    private static let speechTrackName = "roomio_audio" // The worker's SPEECH_TRACK.
    private(set) var caption = CallerCaption()
    private let barge = SpeechBargeIn { CallController.shared.trace(.rpc, $0) }
    @ObservationIgnored private var warm: Task<PreparedCallSpeech?, Never>?
    @ObservationIgnored private var warmLocale: Locale?
    @ObservationIgnored private var selection: Task<PreparedCallSpeech?, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: CallSpeechInput?
    @ObservationIgnored private weak var mic: LocalAudioTrack?
    @ObservationIgnored private weak var room: Room?
    @ObservationIgnored private var afterMuteMs = 0
    @ObservationIgnored private var muted = false

    func preheat() {
        guard SpeechTranscriber.isAvailable, selection == nil, warm == nil, !Pairings.shared.callEntries.isEmpty else { return }
        Task {
            guard let locale = await Self.supportedLocale(language: nil), selection == nil,
                  warm == nil, !Pairings.shared.callEntries.isEmpty else { return }
            _ = prepare(locale: locale)
        }
    }

    static func supportedLocale(language: String?,
                                equivalent: (Locale) async -> Locale? = SpeechTranscriber.supportedLocale(equivalentTo:)) async -> Locale? {
        if let language { return await equivalent(Locale(identifier: language)) }
        if let preferred = Locale.preferredLanguages.first,
           let locale = await equivalent(Locale(identifier: preferred)) { return locale }
        return await equivalent(.current)
    }

    private func prepare(locale: Locale) -> Task<PreparedCallSpeech?, Never> {
        if let warm, warmLocale == locale { return warm }
        warm?.cancel()
        warmLocale = locale
        let task = Task {
            let prepared = try? await PreparedCallSpeech.prepare(locale: locale)
            if prepared == nil, !Task.isCancelled { warm = nil }
            return prepared
        }
        warm = task
        return task
    }

    func begin(target: CallTarget) {
        guard Pairings.shared.callEntries.contains(where: { $0.host == target.paired.host && $0.deviceId == target.paired.deviceId }) else { return }
        let service = target.voicePickerService
        selection = Task {
            guard SpeechTranscriber.isAvailable else { return nil }
            let language = try? await service?.voice().details?.effective?.language
            guard !Task.isCancelled else { return nil }
            guard let locale = await Self.supportedLocale(language: language) else {
                if language != nil, !Task.isCancelled { CallController.shared.trace(.audio, "local speech unsupported call language") }
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let task = prepare(locale: locale)
            guard let prepared = await task.value, !Task.isCancelled else { return nil }
            warm = nil
            do {
                try await prepared.analyzer.prepareToAnalyze(in: prepared.format)
                return prepared
            } catch { return nil }
        }
    }

    func attach(to mic: LocalAudioTrack) {
        let input = CallSpeechInput()
        input.mute(muted)
        self.input = input
        self.mic = mic
        mic.add(audioRenderer: input)
        listening = Task {
            defer {
                if self.input === input {
                    mic.remove(audioRenderer: input)
                    input.finish()
                    self.mic = nil
                    self.input = nil
                }
            }
            guard let prepared = await selection?.value, !Task.isCancelled else {
                if !Task.isCancelled { CallController.shared.trace(.audio, "local speech unavailable") }
                return
            }
            analyzer = prepared.analyzer
            do {
                try await prepared.analyzer.start(inputSequence: input.feed(format: prepared.format))
                CallController.shared.trace(.audio, "local speech ready locale=\(prepared.locale.identifier(.bcp47))")
                for try await result in prepared.transcriber.results {
                    guard !Task.isCancelled else { return }
                    receive(result, from: input)
                }
            } catch {
                if !Task.isCancelled { CallController.shared.trace(.audio, "local speech ended") }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard self.muted != muted else { return }
        self.muted = muted
        input?.mute(muted)
        afterMuteMs = input?.milliseconds ?? 0
        caption = CallerCaption()
    }

    func update(room: Room) {
        self.room = room
        let agent = room.remoteParticipants.values.first(where: \.isAgent)
        barge.update(enabled: room.connectionState == .connected && agent?.attributes[Self.interruptMethod] == "1",
                     speaking: agent?.attributes[VoiceProtocol.agentStateAttribute] == "speaking",
                     micMs: input?.milliseconds ?? 0)
    }

    func showCaption(_ text: String, at start: Int, final: Bool) {
        if caption.text.isEmpty, !text.isEmpty { CallController.shared.trace(.audio, "local speech caption received") }
        caption.update(text, at: start, final: final)
    }

    static func muteSpeechTrack(in tracks: [some CallSpeechPlayout]) -> (() -> Void)? {
        guard let track = tracks.first(where: { $0.name == speechTrackName }) else { return nil }
        let volume = track.volume
        track.volume = 0
        return { track.volume = volume }
    }

    static func milliseconds(at time: CMTime) -> Int? {
        guard time.isNumeric else { return nil }
        return Int(exactly: (time.seconds * 1000).rounded())
    }

    private func receive(_ result: SpeechTranscriber.Result, from input: CallSpeechInput) {
        guard !muted, let start = Self.milliseconds(at: result.range.start), start >= afterMuteMs else { return }
        showCaption(String(result.text.characters), at: start, final: result.isFinal)
        guard !result.isFinal, let room, room.connectionState == .connected,
              let agent = room.remoteParticipants.values.first(where: \.isAgent),
              agent.attributes[Self.interruptMethod] == "1", agent.attributes[VoiceProtocol.agentStateAttribute] == "speaking",
              let identity = agent.identity
        else { return }
        let words = result.text.runs.compactMap { run -> CallerWord? in
            guard let range = run.audioTimeRange, let start = Self.milliseconds(at: range.start) else { return nil }
            let word = String(result.text[run.range].characters)
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return CallerWord(text: word, startMs: start, confidence: run.transcriptionConfidence)
        }
        barge.hear(words, remoteActive: agent.isSpeaking, mute: {
            let restore = Self.muteSpeechTrack(in: agent.audioTracks.filter { $0.isSubscribed && !$0.isMuted }
                .compactMap { $0.track as? RemoteAudioTrack })
            if restore == nil { CallController.shared.trace(.rpc, "interrupt skipped: no speech track") }
            return restore
        }, interrupt: { cut in
            guard room.connectionState == .connected, agent.attributes[Self.interruptMethod] == "1" else {
                self.update(room: room)
                return nil
            }
            let micMs = input.milliseconds
            guard let payload = try? cut.payload(micMs: micMs) else { return nil }
            CallController.shared.trace(.rpc, "interrupt cut sent cutAtMs=\(cut.cutAtMs) micMs=\(micMs) chars=\(cut.heard.count)")
            guard let response = try? await room.localParticipant.performRpc(destinationIdentity: identity,
                method: Self.interruptMethod, payload: payload) else { return nil }
            struct Reply: Decodable { let ok: Bool }
            return (try? JSONDecoder().decode(Reply.self, from: Data(response.utf8)))?.ok
        })
    }

    func end() {
        listening?.cancel()
        selection?.cancel()
        listening = nil
        selection = nil
        if let input { mic?.remove(audioRenderer: input); input.finish() }
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        barge.reset(reason: "call ended")
        mic = nil
        room = nil
        input = nil
        muted = false
        afterMuteMs = 0
        caption = CallerCaption()
    }
}

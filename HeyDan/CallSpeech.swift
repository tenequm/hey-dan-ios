import AVFAudio
import HeyDanCore
import LiveKit
import Observation
import Speech

private struct PreparedCallSpeech {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let format: AVAudioFormat

    static func prepare(language: String?) async throws -> Self? {
        guard SpeechTranscriber.isAvailable else { return nil }
        var locales = language.map { [Locale(identifier: $0)] } ?? []
        if let appLanguage = Locale.preferredLanguages.first { locales.append(Locale(identifier: appLanguage)) }
        locales.append(.current)
        for candidate in locales {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) else { continue }
            var preset = SpeechTranscriber.Preset.progressiveTranscription
            preset.attributeOptions.formUnion([.audioTimeRange, .transcriptionConfidence])
            let transcriber = SpeechTranscriber(locale: locale, preset: preset)
            let modules: [any SpeechModule] = [SpeechDetector(), transcriber]
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { return nil }
            try Task.checkCancellation()
            let analyzer = SpeechAnalyzer(modules: modules)
            try await analyzer.prepareToAnalyze(in: format)
            return Self(analyzer: analyzer, transcriber: transcriber, format: format)
        }
        return nil
    }
}

@Observable @MainActor
final class CallSpeech {
    static let interruptMethod = "nanoclaw.voice-mode.interrupt"
    private(set) var caption = CallerCaption()
    private let barge = SpeechBargeIn()
    @ObservationIgnored private var warm: Task<PreparedCallSpeech?, Never>?
    @ObservationIgnored private var warmLanguage: String?
    @ObservationIgnored private var selection: Task<PreparedCallSpeech?, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: CallSpeechInput?
    @ObservationIgnored private weak var mic: LocalAudioTrack?
    @ObservationIgnored private weak var room: Room?
    @ObservationIgnored private var afterMuteMs = 0
    @ObservationIgnored private var muted = false

    func preheat() {
        guard selection == nil else { return }
        _ = prepare(language: nil)
    }

    private func prepare(language: String?) -> Task<PreparedCallSpeech?, Never> {
        let key = Locale(identifier: language ?? Locale.preferredLanguages.first ?? Locale.current.identifier).identifier(.bcp47)
        if let warm, warmLanguage == key { return warm }
        warm?.cancel()
        warmLanguage = key
        let task = Task {
            let prepared = try? await PreparedCallSpeech.prepare(language: language)
            if prepared == nil, !Task.isCancelled { warm = nil }
            return prepared
        }
        warm = task
        return task
    }

    func begin(target: CallTarget) {
        preheat()
        let service = target.voicePickerService
        selection = Task {
            guard SpeechTranscriber.isAvailable else { return nil }
            let language = try? await service?.voice().details?.effective?.language
            guard !Task.isCancelled else { return nil }
            guard let prepared = await prepare(language: language).value, !Task.isCancelled else { return nil }
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
                if !Task.isCancelled { CallLog.log(.audio, "local speech unavailable") }
                return
            }
            warm = nil
            analyzer = prepared.analyzer
            do {
                try await prepared.analyzer.start(inputSequence: input.feed(format: prepared.format))
                CallLog.log(.audio, "local speech ready")
                for try await result in prepared.transcriber.results {
                    guard !Task.isCancelled else { return }
                    receive(result)
                }
            } catch {
                if !Task.isCancelled { CallLog.log(.audio, "local speech ended") }
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
        if caption.text.isEmpty, !text.isEmpty { CallLog.log(.audio, "local speech caption received") }
        caption.update(text, at: start, final: final)
    }

    private func receive(_ result: SpeechTranscriber.Result) {
        let start = Int((result.range.start.seconds * 1000).rounded())
        guard !muted, start >= afterMuteMs else { return }
        let heard = String(result.text.characters)
        showCaption(heard, at: start, final: result.isFinal)
        guard !result.isFinal, let room, room.connectionState == .connected,
              let agent = room.remoteParticipants.values.first(where: \.isAgent),
              agent.attributes[Self.interruptMethod] == "1", agent.attributes[VoiceProtocol.agentStateAttribute] == "speaking",
              let identity = agent.identity,
              let publication = agent.audioTracks.first(where: { $0.isSubscribed && !$0.isMuted }),
              let track = publication.track as? RemoteAudioTrack
        else { return }
        let words = result.text.runs.compactMap { run -> CallerWord? in
            guard let range = run.audioTimeRange, range.start.isNumeric else { return nil }
            let word = String(result.text[run.range].characters)
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return CallerWord(text: word, startMs: Int((range.start.seconds * 1000).rounded()), confidence: run.transcriptionConfidence)
        }
        barge.hear(words, remoteActive: agent.isSpeaking, mute: {
            let volume = track.volume
            track.volume = 0
            return { track.volume = volume }
        }, interrupt: { cut in
            guard room.connectionState == .connected, agent.attributes[Self.interruptMethod] == "1" else { return false }
            // LiveKit does not expose a per-utterance playout position.
            let payload: [String: Any] = ["heard": heard, "cutAtMs": cut, "playedMs": NSNull()]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let response = try? await room.localParticipant.performRpc(destinationIdentity: identity,
                      method: Self.interruptMethod, payload: String(decoding: data, as: UTF8.self)) else { return false }
            struct Reply: Decodable { let ok: Bool }
            return (try? JSONDecoder().decode(Reply.self, from: Data(response.utf8)))?.ok == true
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
        barge.reset()
        mic = nil
        room = nil
        input = nil
        muted = false
        afterMuteMs = 0
        caption = CallerCaption()
    }
}

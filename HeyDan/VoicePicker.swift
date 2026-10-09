import HeyDanCore
import SwiftUI

struct VoicePickerSheet: View {
    let line: VoiceLine
    let agentName: String
    let callID: UUID?

    var body: some View { Text("\(agentName)'s voice") }
}

@MainActor
enum VoiceSample {
    static var isIdle: Bool { true }
    static func stop() async {}

    #if DEBUG
    static var onActivationStarted: (@MainActor () -> Void)?
    static var activationBarrier: (@MainActor () async -> Void)?
    private(set) static var deactivationsAfterHandoff = 0
    #endif
}

#if DEBUG
enum ContractSmoke {
    static func build(_ line: VoiceLine) throws(TTSPatchError) {
        let choice = TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "alnilam")
        let saved = SavedTTSChoice(provider: "gemini", voice: "alnilam")
        let defaults = TTSDefaults(model: "gemini-3.8-flash-tts", voice: "Alnilam")
        let provider = TTSProvider(id: "gemini", name: "Gemini", available: true, models: [defaults.model], default: defaults)
        _ = TTSView(effective: choice, saved: saved, providers: [provider])
        let voice = CatalogVoice(id: "alnilam", name: "Alnilam")
        _ = CatalogPage(provider: provider.id, voices: [voice])
        _ = TTSPatch.choice(choice)
        _ = TTSPatch.reset
        _ = TTSPatchError.bodyTooLarge(bytes: 1025)
        _ = TTSServiceFailure(status: 403, body: Data())
        _ = TTSServiceFailure(transportError: URLError(.timedOut))
        _ = TTSServiceFailure.malformed.message
        _ = line.ttsRequest
        _ = try line.ttsPatchRequest(.reset)
        _ = line.voicesRequest(provider: provider.id, q: nil, language: nil, cursor: nil, limit: 50)
        _ = VoiceRequest(gen: 1, tts: choice).payload
        _ = CallVoiceState(active: choice)
        _ = CallVoiceState(attribute: #"{"v":1,"active":{"provider":"gemini"}}"#)
        _ = VoiceRequestOutcome.queued(gen: 1)
    }
}
#endif

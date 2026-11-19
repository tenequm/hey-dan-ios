import Foundation
import HeyDanCore
import Testing

struct VoiceSettingsTests {
    @Test func decodesTTSView() throws {
        let json = #"""
        {"effective":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"en-us-techagent-4"},
          "saved":{"provider":"gemini","model":null,"voice":"en-us-techagent-4"},
          "providers":[
           {"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"Alnilam"}},
           {"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_v4_turbo","eleven_v4"],"default":{"model":"eleven_v4_turbo","voice":"bIHbv24MWmeRgasZH58o"}}]}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.effective == TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "en-us-techagent-4"))
        #expect(view.saved == SavedTTSChoice(provider: "gemini", voice: "en-us-techagent-4"))
        #expect(!view.saved.isEmpty)
        #expect(view.providers == [
            TTSProvider(id: "gemini", name: "Gemini", available: true,
                        models: ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"],
                        default: TTSDefaults(model: "gemini-3.8-flash-tts", voice: "Alnilam")),
            TTSProvider(id: "elevenlabs", name: "ElevenLabs", available: false,
                        models: ["eleven_v4_turbo", "eleven_v4"],
                        default: TTSDefaults(model: "eleven_v4_turbo", voice: "bIHbv24MWmeRgasZH58o")),
        ])
    }

    @Test func decodesTTSViewUnsaved() throws {
        let json = #"""
        {"effective":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"Alnilam"},"saved":{"provider":null,"model":null,"voice":null},"providers":[
           {"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"Alnilam"}},
           {"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_v4_turbo","eleven_v4"],"default":{"model":"eleven_v4_turbo","voice":"bIHbv24MWmeRgasZH58o"}}]}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.effective == TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "Alnilam"))
        #expect(view.saved == SavedTTSChoice())
        #expect(view.saved.isEmpty)
        #expect(view.providers.map(\.id) == ["gemini", "elevenlabs"])
        #expect(view.providers.map(\.available) == [true, false])
    }

    @Test func decodesTTSViewDetails() throws {
        let json = #"""
        {"effective":{"provider":"elevenlabs","model":"eleven_v4_turbo","voice":"S80713fa2M70CssGEBj5"},
          "saved":{"provider":"elevenlabs","model":"eleven_v4_turbo","voice":"S80713fa2M70CssGEBj5"},
          "details":{
           "saved":{"provider":"elevenlabs","providerName":"ElevenLabs","model":"eleven_v4_turbo","modelName":"Eleven v4 Turbo",
                    "voice":"S80713fa2M70CssGEBj5","voiceName":"Dan","language":"en","gender":"male","preview":"https://example.invalid/d.mp3","status":"resolved"},
           "effective":{"provider":"elevenlabs","providerName":"ElevenLabs","model":"eleven_v4_turbo","modelName":"Eleven v4 Turbo",
                        "voice":"S80713fa2M70CssGEBj5","voiceName":null,"language":null,"gender":null,"preview":null,"status":"lookup_failed"}},
          "providers":[
           {"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"alnilam"},
            "modelNames":{"gemini-3.8-flash-tts":"Gemini 3.8 Flash TTS"},
            "defaultDetails":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-tts","modelName":"Gemini 3.8 Flash TTS",
                              "voice":"alnilam","voiceName":null,"language":null,"gender":null,"preview":null,"status":"unavailable"}}]}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        let saved = try #require(view.details?.saved)
        #expect(saved == ChoiceDetails(provider: "elevenlabs", providerName: "ElevenLabs", model: "eleven_v4_turbo",
                                       modelName: "Eleven v4 Turbo", voice: "S80713fa2M70CssGEBj5", voiceName: "Dan",
                                       language: "en", gender: "male", preview: URL(string: "https://example.invalid/d.mp3"),
                                       status: .resolved))
        #expect(VoiceLabel(saved) == .named("Dan"))
        #expect(VoiceLabel(view.details?.effective) == .lookupFailed)
        let gemini = try #require(view.providers.first)
        #expect(gemini.modelNames == ["gemini-3.8-flash-tts": "Gemini 3.8 Flash TTS"])
        #expect(VoiceLabel(gemini.defaultDetails) == .unavailable)
        #expect(gemini.defaultDetails?.voice == "alnilam")
    }

    @Test func olderServerHasNoDetails() throws {
        let json = #"""
        {"effective":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"alnilam"},"saved":{"provider":null,"model":null,"voice":null},
         "providers":[{"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"alnilam"}}]}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.details == nil)
        #expect(view.providers.first?.modelNames == nil)
        #expect(view.providers.first?.defaultDetails == nil)
        #expect(VoiceLabel(view.details?.effective) == .noDetails(providerDefault: false))
    }

    private func view(saved: SavedTTSChoice) -> TTSView {
        TTSView(effective: TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "alnilam"), saved: saved, providers: [
            TTSProvider(id: "gemini", name: "Gemini", available: true, models: ["gemini-3.8-flash-tts"],
                        default: TTSDefaults(model: "gemini-3.8-flash-tts", voice: "alnilam")),
            TTSProvider(id: "elevenlabs", name: "ElevenLabs", available: true, models: ["eleven_v4_turbo", "eleven_v4"],
                        default: TTSDefaults(model: "eleven_v4_turbo", voice: "bIHbv24MWmeRgasZH58o")),
        ])
    }

    /// nanoclaw's `voice-mode-tts.fixtures.json` (`ttsView`, `ttsViewNew`) as the server sends it.
    @Test func decodesServerTTSFixtures() throws {
        let view = try JSONDecoder().decode(TTSView.self, from: Data(#"{"effective":{"provider":"gemini","model":"gemini-3.8-flash-lite-tts","voice":"achernar"},"saved":{"provider":"gemini","model":"gemini-3.8-flash-lite-tts","voice":"achernar"},"details":{"saved":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-lite-tts","modelName":"Gemini 3.8 Flash Lite TTS","voice":"achernar","voiceName":"Achernar","language":"en-US","gender":"female","preview":null,"status":"resolved"},"effective":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-lite-tts","modelName":"Gemini 3.8 Flash Lite TTS","voice":"achernar","voiceName":"Achernar","language":"en-US","gender":"female","preview":null,"status":"resolved"}},"providers":[{"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"modelNames":{"gemini-3.8-flash-tts":"Gemini 3.8 Flash TTS","gemini-3.8-flash-lite-tts":"Gemini 3.8 Flash Lite TTS"},"default":{"model":"gemini-3.8-flash-tts","voice":"alnilam"},"defaultDetails":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-tts","modelName":"Gemini 3.8 Flash TTS","voice":"alnilam","voiceName":"Alnilam","language":"en-US","gender":"male","preview":null,"status":"resolved"}},{"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_v4_turbo","eleven_v4"],"modelNames":{"eleven_v4_turbo":"Eleven v4 Turbo","eleven_v4":"Eleven v4"},"default":{"model":"eleven_v4_turbo","voice":"bIHbv24MWmeRgasZH58o"},"defaultDetails":{"provider":"elevenlabs","providerName":"ElevenLabs","model":"eleven_v4_turbo","modelName":"Eleven v4 Turbo","voice":"bIHbv24MWmeRgasZH58o","voiceName":null,"language":null,"gender":null,"preview":null,"status":"lookup_failed"}}]}"#.utf8))
        #expect(VoiceLabel(view.details?.saved) == .named("Achernar"))
        #expect(view.providers.map(\.default.voice) == ["alnilam", "bIHbv24MWmeRgasZH58o"])
        #expect(view.providers.first?.modelNames?["gemini-3.8-flash-lite-tts"] == "Gemini 3.8 Flash Lite TTS")
        #expect(VoiceLabel(view.providers.first?.defaultDetails) == .named("Alnilam"))
        #expect(VoiceLabel(view.providers.last?.defaultDetails) == .lookupFailed)
        let fresh = try JSONDecoder().decode(TTSView.self, from: Data(#"{"effective":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"en-us-techagent-4"},"saved":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"en-us-techagent-4"},"details":{"saved":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-tts","modelName":"Gemini 3.8 Flash TTS","voice":"en-us-techagent-4","voiceName":"Tech Advisor 4","language":"en-US","gender":"male","preview":null,"status":"resolved"},"effective":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-tts","modelName":"Gemini 3.8 Flash TTS","voice":"en-us-techagent-4","voiceName":"Tech Advisor 4","language":"en-US","gender":"male","preview":null,"status":"resolved"}},"providers":[{"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"modelNames":{"gemini-3.8-flash-tts":"Gemini 3.8 Flash TTS","gemini-3.8-flash-lite-tts":"Gemini 3.8 Flash Lite TTS"},"default":{"model":"gemini-3.8-flash-tts","voice":"alnilam"},"defaultDetails":{"provider":"gemini","providerName":"Gemini","model":"gemini-3.8-flash-tts","modelName":"Gemini 3.8 Flash TTS","voice":"alnilam","voiceName":"Alnilam","language":"en-US","gender":"male","preview":null,"status":"resolved"}},{"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_v4_turbo","eleven_v4"],"modelNames":{"eleven_v4_turbo":"Eleven v4 Turbo","eleven_v4":"Eleven v4"},"default":{"model":"eleven_v4_turbo","voice":"bIHbv24MWmeRgasZH58o"},"defaultDetails":{"provider":"elevenlabs","providerName":"ElevenLabs","model":"eleven_v4_turbo","modelName":"Eleven v4 Turbo","voice":"bIHbv24MWmeRgasZH58o","voiceName":null,"language":null,"gender":null,"preview":null,"status":"lookup_failed"}}]}"#.utf8))
        #expect(fresh.details?.saved?.voiceName == "Tech Advisor 4")
        #expect(fresh.details?.saved?.status == .resolved)
    }

    @Test func unreadableDetailFieldsDecodeTheRest() throws {
        let json = #"{"voice":"a","voiceName":"Achernar","preview":"","gender":7,"status":"renamed"}"#
        let details = try JSONDecoder().decode(ChoiceDetails.self, from: Data(json.utf8))
        #expect(details == ChoiceDetails(voice: "a", voiceName: "Achernar"))
    }

    @Test func providerDefaultSaveConfirmsAgainstFilledValues() {
        let patch = TTSPatch.choice(TTSChoice(provider: "elevenlabs"))
        let filled = SavedTTSChoice(provider: "elevenlabs", model: "eleven_v4_turbo", voice: "bIHbv24MWmeRgasZH58o")
        #expect(view(saved: filled).confirms(patch))
        #expect(view(saved: SavedTTSChoice(provider: "elevenlabs")).confirms(patch))
        #expect(!view(saved: SavedTTSChoice(provider: "elevenlabs", model: "eleven_v4", voice: "bIHbv24MWmeRgasZH58o")).confirms(patch))
        #expect(!view(saved: SavedTTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "alnilam")).confirms(patch))
    }

    @Test func explicitSaveConfirmsExactly() {
        let choice = TTSChoice(provider: "elevenlabs", model: "eleven_v4", voice: "EXAVITQu4vr4xnSDxMaL")
        #expect(view(saved: SavedTTSChoice(provider: "elevenlabs", model: "eleven_v4", voice: "EXAVITQu4vr4xnSDxMaL")).confirms(.choice(choice)))
        #expect(!view(saved: SavedTTSChoice(provider: "elevenlabs", model: "eleven_v4", voice: "exavitqu4vr4xnsdxmal")).confirms(.choice(choice)))
        #expect(!view(saved: SavedTTSChoice(provider: "elevenlabs", model: "eleven_v4_turbo", voice: "bIHbv24MWmeRgasZH58o")).confirms(.choice(choice)))
    }

    /// The server does not report the line default a reset writes, so only an older server's empty row confirms one.
    @Test func resetConfirmsOnlyAsNothingSaved() {
        let lineDefault = SavedTTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "en-us-techagent-4")
        #expect(view(saved: SavedTTSChoice()).confirms(.reset))
        #expect(!view(saved: lineDefault).confirms(.reset))
    }

    /// Another client's save between a lost reset and its reload is not the reset.
    @Test func concurrentSaveDoesNotConfirmReset() {
        let otherClient = SavedTTSChoice(provider: "elevenlabs", model: "eleven_v4", voice: "EXAVITQu4vr4xnSDxMaL")
        #expect(!view(saved: otherClient).confirms(.reset))
    }

    @Test func voiceLabels() {
        #expect(VoiceLabel(ChoiceDetails(voice: "a", voiceName: "Achernar", status: .resolved)) == .named("Achernar"))
        #expect(VoiceLabel(ChoiceDetails(voice: "a", voiceName: "Achernar", status: .lookupFailed)) == .named("Achernar"))
        #expect(VoiceLabel(ChoiceDetails(voice: "a", voiceName: "Achernar", status: .unavailable)) == .unavailable)
        #expect(VoiceLabel(ChoiceDetails(voice: "a", status: .lookupFailed)) == .lookupFailed)
        #expect(VoiceLabel(ChoiceDetails(voice: "a")) == .lookupFailed)
        #expect(VoiceLabel(ChoiceDetails(voice: "a", status: .resolved)) == .unnamed)
        #expect(VoiceLabel.unnamed.title == "Name unavailable")
        #expect(VoiceLabel(nil) == .noDetails(providerDefault: false))
        #expect(VoiceLabel(nil, providerDefault: true).title == "Provider default voice")
        #expect(VoiceLabel(nil).title == "Selected voice")
        #expect(VoiceLabel.unavailable.title == "Voice no longer available")
        #expect(VoiceLabel.lookupFailed.title == "Name unavailable")
    }

    @Test func decodesCatalogGemini() throws {
        let json = #"""
        {"provider":"gemini","voices":[
           {"id":"achernar","name":"Achernar","language":"en-US","gender":"female","description":"Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."},
           {"id":"en-us-techagent-4","name":"Tech Advisor 4","language":"en-US","gender":"male","description":"Tech Support Agent / Tech Advisor. Confident and clear."}],
          "next":"eyJvIjoxMDB9"}
        """#
        let page = try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
        #expect(page.provider == "gemini")
        #expect(page.voices == [
            VoiceLineCatalogVoice(id: "achernar", name: "Achernar", language: "en-US", gender: "female",
                         description: "Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."),
            VoiceLineCatalogVoice(id: "en-us-techagent-4", name: "Tech Advisor 4", language: "en-US", gender: "male",
                         description: "Tech Support Agent / Tech Advisor. Confident and clear."),
        ])
        #expect(page.next == "eyJvIjoxMDB9")
    }

    @Test func decodesCatalogElevenLast() throws {
        let json = #"""
        {"provider":"elevenlabs","voices":[{"id":"bIHbv24MWmeRgasZH58o","name":"Will","language":"en","gender":"male","preview":"https://example.invalid/w.mp3"}]}
        """#
        let page = try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
        #expect(page.provider == "elevenlabs")
        #expect(page.voices == [VoiceLineCatalogVoice(id: "bIHbv24MWmeRgasZH58o", name: "Will", language: "en", gender: "male",
                                            preview: URL(string: "https://example.invalid/w.mp3"))])
        #expect(page.next == nil)
    }

    @Test(arguments: [#"{}"#, #"{"provider":null,"model":null,"voice":null}"#])
    func omittedAndNullSavedFieldsAreEmpty(json: String) throws {
        let saved = try JSONDecoder().decode(SavedTTSChoice.self, from: Data(json.utf8))
        #expect(saved == SavedTTSChoice())
        #expect(saved.isEmpty)
    }

    @Test(arguments: [#"{"provider":"future"}"#, #"{"provider":"future","model":null,"voice":null}"#])
    func omittedAndNullSavedFieldsPreservePresentValues(json: String) throws {
        let saved = try JSONDecoder().decode(SavedTTSChoice.self, from: Data(json.utf8))
        #expect(saved == SavedTTSChoice(provider: "future"))
        #expect(!saved.isEmpty)
        #expect(!SavedTTSChoice(model: "future-model").isEmpty)
        #expect(!SavedTTSChoice(voice: "future-voice").isEmpty)
    }

    @Test(arguments: [
        #"{"provider":"future","voices":[{"id":"future-voice","name":"Future"}]}"#,
        #"{"provider":"future","voices":[{"id":"future-voice","name":"Future","language":null,"gender":null,"description":null,"preview":null}],"next":null}"#,
    ])
    func optionalCatalogMetadataAbsentOrNull(json: String) throws {
        let page = try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
        #expect(page == CatalogPage(provider: "future", voices: [VoiceLineCatalogVoice(id: "future-voice", name: "Future")]))
    }

    @Test func unknownProviderModelAndVoiceIDsDecodeVerbatim() throws {
        let json = #"""
        {"effective":{"provider":"future-provider","model":"Future-Model","voice":"Future-Voice"},
         "saved":{"provider":"future-provider","model":"Future-Model","voice":"Future-Voice"},
         "providers":[{"id":"future-provider","name":"Future","available":true,"models":["Future-Model"],
                       "default":{"model":"Future-Model","voice":"Future-Voice"}}],"newMetadata":true}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.effective == TTSChoice(provider: "future-provider", model: "Future-Model", voice: "Future-Voice"))
        #expect(view.saved == SavedTTSChoice(provider: "future-provider", model: "Future-Model", voice: "Future-Voice"))
        #expect(view.providers == [TTSProvider(id: "future-provider", name: "Future", available: true,
                                              models: ["Future-Model"], default: TTSDefaults(model: "Future-Model", voice: "Future-Voice"))])
        #expect(try JSONDecoder().decode(TTSChoice.self, from: Data(#"{"provider":"future-provider"}"#.utf8))
                == TTSChoice(provider: "future-provider"))
    }

    @Test func missingRequiredCatalogFieldsFailDecoding() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CatalogPage.self, from: Data(#"{"provider":"gemini","voices":[{"id":"voice"}]}"#.utf8))
        }
    }

    @Test(arguments: ["provider", "model", "voice"])
    func invalidMessagesRetainKnownFieldLabels(field: String) {
        #expect(TTSServiceFailure.invalid(field: field).message == "The selected \(field) is not valid. Choose another and try again.")
    }

}

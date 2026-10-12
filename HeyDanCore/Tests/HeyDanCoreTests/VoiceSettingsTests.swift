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

    @Test func mapsPatchInvalidFixture() {
        let json = #"""
        {"error":"invalid","field":"voice"}
        """#
        #expect(TTSServiceFailure(status: 400, body: Data(json.utf8)) == .invalid(field: "voice"))
    }

    @Test func mapsPatchUnavailableFixture() {
        let json = #"""
        {"error":"provider_unavailable","provider":"elevenlabs"}
        """#
        #expect(TTSServiceFailure(status: 503, body: Data(json.utf8)) == .providerUnavailable(provider: "elevenlabs"))
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
            CatalogVoice(id: "achernar", name: "Achernar", language: "en-US", gender: "female",
                         description: "Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."),
            CatalogVoice(id: "en-us-techagent-4", name: "Tech Advisor 4", language: "en-US", gender: "male",
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
        #expect(page.voices == [CatalogVoice(id: "bIHbv24MWmeRgasZH58o", name: "Will", language: "en", gender: "male",
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
        #expect(page == CatalogPage(provider: "future", voices: [CatalogVoice(id: "future-voice", name: "Future")]))
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

    @Test func resetRequestHasExactBody() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = try line.ttsPatchRequest(.reset)
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"reset":true}"#.utf8))
        #expect(request.url?.path == "/voice/tts")
        #expect(try formQuery(request) == ["t": "fake"])
    }

    @Test(arguments: [
        TTSChoice(provider: "gemini"),
        TTSChoice(provider: "gemini", model: "future-model"),
        TTSChoice(provider: "gemini", voice: "future-voice"),
        TTSChoice(provider: "future", model: "Future-Model", voice: "Future-Voice"),
    ])
    func choiceRequestExcludesResetAndNilOptionals(choice: TTSChoice) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = try line.ttsPatchRequest(.choice(choice))
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        var expected = ["provider": choice.provider]
        expected["model"] = choice.model
        expected["voice"] = choice.voice
        #expect(object == expected)
        #expect(object["reset"] == nil)
        #expect(try JSONDecoder().decode(TTSChoice.self, from: body) == choice)
    }

    @Test func sendsExactly1024BytePatch() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: boundaryVoice(bytes: 1024)))
        let request = try line.ttsPatchRequest(patch)
        let body = try #require(request.httpBody)
        #expect(body.count == 1024)
        #expect(String(decoding: body, as: UTF8.self).count < body.count)
        #expect(try JSONDecoder().decode(TTSChoice.self, from: body) == TTSChoice(provider: "gemini", voice: boundaryVoice(bytes: 1024)))
    }

    @Test func refusesExactly1025BytePatchWithByteCount() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: boundaryVoice(bytes: 1025)))
        #expect(try JSONEncoder().encode(patch).count == 1025)
        #expect(throws: TTSPatchError.bodyTooLarge(bytes: 1025)) {
            try line.ttsPatchRequest(patch)
        }
    }

    @Test func refusesOversizedVoiceID() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: String(repeating: "a", count: 1100)))
        let bytes = try JSONEncoder().encode(patch).count
        #expect(throws: TTSPatchError.bodyTooLarge(bytes: bytes)) {
            try line.ttsPatchRequest(patch)
        }
    }

    @Test(arguments: ["a b", "a&b", "a=b", "a+b&c=d", "caf\u{E9} \u{65E5}\u{672C}", "a%2Bb#c?d"])
    func queryEscapingPreservesSearch(q: String) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = line.voicesRequest(provider: "gemini", q: q, language: nil, cursor: nil, limit: 25)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/voice/voices")
        #expect(try formQuery(request) == ["t": "fake", "provider": "gemini", "q": q, "limit": "25"])
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedQuery?.contains("+") == false)
        if q.contains("+") { #expect(components.percentEncodedQuery?.contains("%2B") == true) }
    }

    @Test func queryEscapingPreservesAllFiltersAndProvider() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = line.voicesRequest(provider: "future+provider", q: "a+b&c=d", language: "en+US", gender: "fe+male&x=y",
                                         cursor: "next+/=&", limit: 1)
        #expect(try formQuery(request) == ["t": "fake", "provider": "future+provider", "q": "a+b&c=d",
                                          "language": "en+US", "gender": "fe+male&x=y", "cursor": "next+/=&", "limit": "1"])
    }

    @Test func httpVoiceRequestsPreserveEncodedToken() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake%2B%26%3D"))
        for request in [line.ttsRequest, try line.ttsPatchRequest(.reset),
                        line.voicesRequest(provider: "gemini", q: nil, language: nil, cursor: nil, limit: 10)] {
            #expect(try formQuery(request)["t"] == "fake+&=")
        }
    }

    @Test func queryNilFiltersAreAbsentAndEmptyFiltersRemainEmpty() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let absent = line.voicesRequest(provider: "gemini", q: nil, language: nil, gender: nil, cursor: nil, limit: 100)
        #expect(try formQuery(absent) == ["t": "fake", "provider": "gemini", "limit": "100"])
        let empty = line.voicesRequest(provider: "gemini", q: "", language: "", gender: "", cursor: "", limit: 100)
        #expect(try formQuery(empty) == ["t": "fake", "provider": "gemini", "q": "", "language": "", "gender": "", "cursor": "",
                                        "limit": "100"])
    }

    @Test(arguments: [511, 512, 513, 600])
    func queryFiltersClampTo512UTF16Units(count: Int) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let input = String(repeating: "a", count: count)
        let expected = String(repeating: "a", count: min(count, 512))
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: input, language: input, gender: input, cursor: input, limit: 10))
        for name in ["q", "language", "gender", "cursor"] { #expect(query[name] == expected) }
    }

    @Test func queryFiltersClampCombiningScalarsByUTF16Length() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let input = String(repeating: "e\u{301}", count: 600)
        let expected = String(repeating: "e\u{301}", count: 256)
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: input, language: input, gender: input, cursor: input, limit: 10))
        for name in ["q", "language", "gender", "cursor"] {
            #expect(query[name] == expected)
            #expect(query[name]?.utf16.count == 512)
        }
    }

    @Test(arguments: [510, 511, 512])
    func queryFiltersNeverSplitSupplementaryScalar(prefixLength: Int) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let prefix = String(repeating: "a", count: prefixLength)
        let input = prefix + "\u{1F600}z"
        let expected = prefixLength == 510 ? prefix + "\u{1F600}" : prefix
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: input, language: input, gender: input, cursor: input, limit: 10))
        for name in ["q", "language", "gender", "cursor"] {
            #expect(query[name] == expected)
            #expect(try #require(query[name]).utf16.count <= 512)
        }
    }

    @Test(arguments: [(Int.min, "1"), (-1, "1"), (0, "1"), (1, "1"), (50, "50"), (100, "100"), (101, "100"), (Int.max, "100")])
    func queryLimitClampsToOneThrough100(limit: Int, expected: String) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: nil, language: nil, cursor: nil, limit: limit))
        #expect(query["limit"] == expected)
    }

    @Test(arguments: ["invalid", "tts_invalid"])
    func mapsInvalidJSONErrors(error: String) {
        let json = "{\"error\":\"\(error)\",\"field\":\"model\"}"
        #expect(TTSServiceFailure(status: 400, body: Data(json.utf8)) == .invalid(field: "model"))
    }

    @Test func mapsBadRequest400AndUpstream502() {
        #expect(TTSServiceFailure(status: 400, body: Data(#"{"error":"bad_request"}"#.utf8)) == .badRequest)
        #expect(TTSServiceFailure(status: 502, body: Data(#"{"error":"upstream"}"#.utf8)) == .upstream)
    }

    @Test(arguments: [400, 403, 404, 405, 500, 502, 503])
    func knownJSONErrorsTakePrecedenceOverStatus(status: Int) {
        let cases: [(String, TTSServiceFailure)] = [
            (#"{"error":"tts_invalid","field":"provider"}"#, .invalid(field: "provider")),
            (#"{"error":"invalid","field":"voice"}"#, .invalid(field: "voice")),
            (#"{"error":"provider_unavailable","provider":"future"}"#, .providerUnavailable(provider: "future")),
            (#"{"error":"bad_request"}"#, .badRequest),
            (#"{"error":"upstream"}"#, .upstream),
        ]
        for (json, expected) in cases {
            #expect(TTSServiceFailure(status: status, body: Data(json.utf8)) == expected)
        }
    }

    @Test(arguments: ["", ",\"field\":null,\"provider\":null", ",\"field\":42,\"provider\":{}"])
    func missingNullOrMalformedErrorMetadataKeepsKnownError(metadata: String) {
        let cases: [(String, TTSServiceFailure)] = [
            ("invalid", .invalid(field: "tts")), ("tts_invalid", .invalid(field: "tts")),
            ("provider_unavailable", .providerUnavailable(provider: "voice")),
            ("bad_request", .badRequest), ("upstream", .upstream),
        ]
        for (error, expected) in cases {
            let json = "{\"error\":\"\(error)\"\(metadata)}"
            #expect(TTSServiceFailure(status: 403, body: Data(json.utf8)) == expected)
        }
    }

    @Test func mapsPlainText503VoiceNotRunning() {
        #expect(TTSServiceFailure(status: 503, body: Data(" \nVoice is not running\r\n".utf8)) == .providerUnavailable(provider: "voice"))
        #expect(TTSServiceFailure(status: 503, body: Data("Other refusal".utf8)) == .refused(status: 503, body: "Other refusal"))
    }

    @Test(arguments: [405, 500])
    func mapsPlainText405And500ToRefused(status: Int) {
        #expect(TTSServiceFailure(status: status, body: Data(" \nRequest refused\t".utf8)) == .refused(status: status, body: "Request refused"))
    }

    @Test func mapsForbidden403AndMissingRoute404() {
        #expect(TTSServiceFailure(status: 403, body: Data("Unknown call link".utf8)) == .forbidden)
        #expect(TTSServiceFailure(status: 404, body: Data("Not found".utf8)) == .noRoute)
        #expect(TTSServiceFailure.forbidden.message == "Access lost. Check this line's call link in Settings.")
    }

    @Test(arguments: [#"{"error":"future"}"#, #"{"error":42}"#, #"{"field":"voice"}"#, "{", ""])
    func unknownOrMalformedErrorJSONFallsBackToStatus(json: String) {
        let body = Data(json.utf8)
        #expect(TTSServiceFailure(status: 403, body: body) == .forbidden)
        #expect(TTSServiceFailure(status: 404, body: body) == .noRoute)
        #expect(TTSServiceFailure(status: 500, body: body) == .refused(status: 500, body: json))
    }

    @Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                      .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed])
    func transportTimeoutOfflineAndConnectionErrorsAreUnreachable(code: URLError.Code) {
        #expect(TTSServiceFailure(transportError: URLError(code)) == .unreachable)
    }

    @Test func otherTransportErrorsRetainDetailWithoutDisplayingIt() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private transport detail"])
        #expect(TTSServiceFailure(transportError: error) == .transport("private transport detail"))
        let cancelled = URLError(.cancelled)
        #expect(TTSServiceFailure(transportError: cancelled) == .transport(cancelled.localizedDescription))
    }

    @Test func messagesNeverExposeURLHostOrToken() throws {
        let detail = "https://private.invalid/path?credential=synthetic-token"
        let failures: [TTSServiceFailure] = [
            .invalid(field: detail), .providerUnavailable(provider: detail), .badRequest, .upstream,
            .forbidden, .noRoute, .unreachable, .transport(detail), .malformed, .refused(status: 500, body: detail),
            TTSServiceFailure(status: 403, body: Data(detail.utf8)),
            TTSServiceFailure(transportError: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])),
        ]
        for failure in failures {
            #expect(!failure.message.isEmpty)
            #expect(!failure.message.contains("https://"))
            #expect(!failure.message.contains("private.invalid"))
            #expect(!failure.message.contains("synthetic-token"))
        }
        let body = try JSONEncoder().encode(["error": "invalid", "field": detail])
        let invalid = TTSServiceFailure(status: 400, body: body)
        #expect(invalid == .invalid(field: detail))
        #expect(invalid.message == "The selected voice setting is not valid. Choose another and try again.")
    }

    @Test(arguments: ["provider", "model", "voice"])
    func invalidMessagesRetainKnownFieldLabels(field: String) {
        #expect(TTSServiceFailure.invalid(field: field).message == "The selected \(field) is not valid. Choose another and try again.")
    }

    private func formQuery(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try #require(components.percentEncodedQuery)
        var result: [String: String] = [:]
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            try #require(pair.count == 2)
            let name = try #require(String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            let value = try #require(String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            #expect(result[name] == nil)
            result[name] = value
        }
        return result
    }

    private func boundaryVoice(bytes: Int) -> String {
        let overhead = Data(#"{"provider":"gemini","voice":""}"#.utf8).count
        return "\u{E9}" + String(repeating: "a", count: bytes - overhead - 2)
    }
}

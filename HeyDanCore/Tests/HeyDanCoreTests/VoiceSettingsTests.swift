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
           {"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_turbo_v2_5","eleven_flash_v2_5","eleven_multilingual_v2"],"default":{"model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"}}]}
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
                        models: ["eleven_turbo_v2_5", "eleven_flash_v2_5", "eleven_multilingual_v2"],
                        default: TTSDefaults(model: "eleven_turbo_v2_5", voice: "bIHbv24MWmeRgasZH58o")),
        ])
    }

    @Test func resetRequestHasExactBody() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = try line.ttsPatchRequest(.reset)
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"reset":true}"#.utf8))
        #expect(request.url?.path == "/voice/tts")
    }

    @Test func refusesOversizedVoiceID() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: String(repeating: "a", count: 1100)))
        let bytes = try JSONEncoder().encode(patch).count
        #expect(throws: TTSPatchError.bodyTooLarge(bytes: bytes)) {
            try line.ttsPatchRequest(patch)
        }
    }
}

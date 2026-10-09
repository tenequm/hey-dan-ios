import Foundation
import HeyDanCore
import Testing

struct CallVoiceTests {
    @Test func decodesVoiceAttribute() throws {
        let json = #"{"v":1,"active":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"alnilam"},"pending":{"provider":"elevenlabs","model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"},"gen":7}"#
        let expected = CallVoiceState(
            active: TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "alnilam"),
            pending: TTSChoice(provider: "elevenlabs", model: "eleven_turbo_v2_5", voice: "bIHbv24MWmeRgasZH58o"),
            gen: 7
        )
        #expect(try JSONDecoder().decode(CallVoiceState.self, from: Data(json.utf8)) == expected)
        #expect(CallVoiceState(attribute: json) == expected)
        #expect(expected.v == 1)
    }

    @Test func protocol4HasNoVoiceAttribute() {
        #expect(VoiceProtocol.Names(version: 4)?.voiceAttribute == nil)
    }

    @Test func protocol6NamesVoiceAttribute() {
        #expect(VoiceProtocol.Names(version: 6)?.voiceAttribute == "nanoclaw.voice-mode.voice")
    }
}

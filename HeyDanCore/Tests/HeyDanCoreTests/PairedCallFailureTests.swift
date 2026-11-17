import Foundation
import HeyDanCore
import Testing

struct PairedCallFailureTests {
    @Test func serverMessagesAreVerbatimAndNotLogged() {
        let message = "This agent cannot take a call."
        let failure = CallFailure.server(status: 403, code: "no_line", message: message)
        #expect(failure.message == message)
        #expect(failure.logName == "server-403")
        #expect(TTSServiceFailure.server(status: 503, code: "voice_offline", message: message).message == message)
        #expect(!CallFailure.pairedTransport.message.contains("Tailscale"))
        #expect(!TTSServiceFailure.pairedTransport.message.contains("Tailscale"))
    }

    @Test func resetPatchPreservesWireShape() throws {
        let data = try JSONEncoder().encode(VoicePatchRequest(reset: true))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        #expect(body == ["reset": true])
    }
}

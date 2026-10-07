import Foundation
import HeyDanCore
import Testing

struct VoiceLineTests {
    @Test func parsesTheCallLink() throws {
        let line = try #require(VoiceLine(callLink: "  https://voice.example.com/voice?t=abc123\n"))
        #expect(line.host == "voice.example.com")
        #expect(line.token == "abc123")
        #expect(line.callLink == "https://voice.example.com/voice?t=abc123")
        #expect(line.tokenRequest.url?.absoluteString == "https://voice.example.com/voice/livekit/token?t=abc123")
        #expect(line.tokenRequest.httpMethod == "POST")
    }

    @Test(arguments: [
        "http://voice.example.com/voice?t=abc",
        "https://voice.example.com/voice",
        "https://voice.example.com/voice?t=",
        "https://voice.example.com/other?t=abc",
        "https://voice.example.com/prefix/voice?t=abc",
        "voice.example.com/voice?t=abc",
        "",
    ])
    func rejectsWhatIsNotACallLink(_ link: String) {
        #expect(VoiceLine(callLink: link) == nil)
    }

    @Test func keepsAPortAndRoundTrips() throws {
        let line = try #require(VoiceLine(callLink: "https://voice.local:8443/voice/?t=x"))
        #expect(line.tokenRequest.url?.absoluteString == "https://voice.local:8443/voice/livekit/token?t=x")
        #expect(line.callLink == "https://voice.local:8443/voice?t=x")
        #expect(VoiceLine(callLink: line.callLink) == line)
    }

    @Test func endRequestCarriesTheCallAndReason() throws {
        let line = try #require(VoiceLine(callLink: "https://h.example/voice?t=x"))
        let request = line.endRequest(callId: "c1", reason: .noAgent)
        #expect(request.url?.absoluteString == "https://h.example/voice/livekit/end?t=x")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["callId": "c1", "reason": "no-agent"])
        let plain = try JSONSerialization.jsonObject(with: try #require(line.endRequest(callId: "c1").httpBody)) as? [String: String]
        #expect(plain == ["callId": "c1"])
    }
}

struct CallGrantTests {
    @Test func decodesTheHostAnswer() throws {
        let body = Data(#"{"url":"wss://voice.example.com","token":"jwt","callId":"id1","agent":"Dan","silenceMs":2500,"limit":{"ms":1800000,"kind":"duration"}}"#.utf8)
        let grant = try CallGrant(status: 200, body: body)
        #expect(grant.url == "wss://voice.example.com")
        #expect(grant.callId == "id1")
        #expect(grant.agent == "Dan")
    }

    @Test func refusalKeepsTheHostsWords() {
        #expect(throws: CallFailure.refused(status: 429, body: "Daily minutes used")) {
            try CallGrant(status: 429, body: Data(" Daily minutes used\n".utf8))
        }
        #expect(throws: CallFailure.refused(status: 500, body: "")) { try CallGrant(status: 500, body: Data()) }
    }

    @Test(arguments: [
        (403, "Unknown call link", "This call link is not valid."),
        (429, "Daily minutes used", "Daily minutes used"),
        (429, "", "This line has reached its hourly call limit. Try again later."),
        (409, "", "This call attempt is no longer active. Try again."),
        (502, "", "Could not open the call room. Try again."),
        (503, "", "The voice line is offline right now."),
        (500, "boom", "Could not start the call (HTTP 500)."),
    ])
    func refusalWording(status: Int, body: String, message: String) {
        #expect(CallFailure.refused(status: status, body: body).message == message)
    }

    @Test func garbageIsMalformed() {
        #expect(throws: CallFailure.malformedGrant) { try CallGrant(status: 200, body: Data("<html>".utf8)) }
    }

    @Test func logNamesCarryNoWording() {
        #expect(CallFailure.refused(status: 429, body: "Daily minutes used").logName == "refused-429")
        #expect(CallFailure.transport("https://h/voice?t=secret").logName == "transport")
        #expect(CallFailure.unreachable.logName == "unreachable")
    }

    @Test func aTimeoutPointsAtTailscale() {
        #expect(CallFailure(transportError: URLError(.timedOut)) == .unreachable)
        #expect(CallFailure(transportError: URLError(.cannotConnectToHost)) == .unreachable)
        #expect(CallFailure.unreachable.message.contains("Tailscale"))
        guard case .transport = CallFailure(transportError: URLError(.cancelled)) else {
            Issue.record("a cancelled load is not the tailnet")
            return
        }
    }
}

struct VoiceProtocolTests {
    @Test func speakingWinsOverThinking() {
        #expect(VoiceProtocol.activity(["lk.agent.state": "speaking", "nanoclaw.voice.thinking": "1"]) == .speaking)
        #expect(VoiceProtocol.activity(["lk.agent.state": "listening", "nanoclaw.voice.thinking": "1"]) == .thinking)
        #expect(VoiceProtocol.activity(["lk.agent.state": "thinking"]) == .thinking)
        #expect(VoiceProtocol.activity(["lk.agent.state": "idle"]) == .listening)
        #expect(VoiceProtocol.activity(["lk.agent.state": "initializing"]) == nil)
        #expect(VoiceProtocol.activity([:]) == nil)
    }

    @Test func updatingOnlyOnOne() {
        #expect(VoiceProtocol.isUpdating(["nanoclaw.voice.updating": "1"]))
        #expect(!VoiceProtocol.isUpdating(["nanoclaw.voice.updating": ""]))
        #expect(!VoiceProtocol.isUpdating([:]))
    }

    @Test func readsTheEndReason() {
        #expect(VoiceProtocol.endReasonText(roomMetadata: #"{"chat":null,"end":"newer_call"}"#) == "A newer call on this line took over.")
        #expect(VoiceProtocol.endReasonText(roomMetadata: #"{"chat":"Dan DM"}"#) == nil)
        #expect(VoiceProtocol.endReasonText(roomMetadata: #"{"end":"something_new"}"#) == nil)
        #expect(VoiceProtocol.endReasonText(roomMetadata: nil) == nil)
    }
}

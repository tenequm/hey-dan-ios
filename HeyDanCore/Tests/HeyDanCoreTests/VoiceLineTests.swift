import Foundation
import HeyDanCore
import Testing

struct VoiceLineTests {
    @Test func parsesTheCallLink() throws {
        let line = try #require(VoiceLine(callLink: "  https://voice.example.com/voice?t=abc123\n"))
        #expect(line.host == "voice.example.com")
        #expect(line.token == "abc123")
        #expect(line.callLink == "https://voice.example.com/voice?t=abc123")
        #expect(line.tokenRequest.url?.absoluteString == "https://voice.example.com/voice/livekit/token?t=abc123&v=6")
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
        #expect(line.tokenRequest.url?.absoluteString == "https://voice.local:8443/voice/livekit/token?t=x&v=6")
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

    @Test func aHostNamingNoProtocolSpeaks4() throws {
        let grant = try CallGrant(status: 200, body: Data(#"{"url":"wss://h","token":"jwt","callId":"id1","agent":"Dan"}"#.utf8))
        #expect(grant.protocolVersion == 4)
        #expect(grant.names == VoiceProtocol.Names(version: 4))
    }

    @Test func aProtocol6HostSaysSo() throws {
        let body = Data(#"{"url":"wss://h","token":"jwt","callId":"id1","agent":"Dan","silenceMs":2500,"protocol":6}"#.utf8)
        let grant = try CallGrant(status: 200, body: body)
        #expect(grant.protocolVersion == 6)
        #expect(grant.names?.turnTopic == "nanoclaw.voice-mode.turn")
    }

    @Test(arguments: [5, 7, 0])
    func anUnknownProtocolHasNoNamesButKeepsItsCall(version: Int) throws {
        let grant = try CallGrant(status: 200, body: Data(#"{"url":"wss://h","token":"jwt","callId":"id9","protocol":\#(version)}"#.utf8))
        #expect(grant.protocolVersion == version)
        #expect(grant.names == nil)
        #expect(grant.callId == "id9")
    }

    @Test func anUnsupportedProtocolAsksForAnUpdate() {
        #expect(CallFailure.unsupportedProtocol(5).message.contains("Update the app"))
    }

    @Test func aProtocolThatIsNoNumberIsMalformed() {
        #expect(throws: CallFailure.malformedGrant) {
            try CallGrant(status: 200, body: Data(#"{"url":"wss://h","token":"jwt","callId":"id1","protocol":"6"}"#.utf8))
        }
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
        (
            409, "The voice service is updating. Reload the page or update your client to protocol 6.",
            "This voice line needs a newer Hey Dan. Update the app, then call again."
        ),
        (409, "Unknown protocol", "This call attempt is no longer active. Try again."),
        (426, "", "This voice line needs a newer Hey Dan. Update the app, then call again."),
        (
            426, "The voice service is updating. Reload the page or update your client to protocol 6.",
            "This voice line needs a newer Hey Dan. Update the app, then call again."
        ),
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
    @Test func speakingWinsOverThinking() throws {
        let names = try #require(VoiceProtocol.Names(version: 4))
        #expect(names.activity(["lk.agent.state": "speaking", "nanoclaw.voice.thinking": "1"]) == .speaking)
        #expect(names.activity(["lk.agent.state": "listening", "nanoclaw.voice.thinking": "1"]) == .thinking)
        #expect(names.activity(["lk.agent.state": "thinking"]) == .thinking)
        #expect(names.activity(["lk.agent.state": "idle"]) == .listening)
        #expect(names.activity(["lk.agent.state": "initializing"]) == nil)
        #expect(names.activity([:]) == nil)
    }

    @Test func thinkingIsReadInTheHostsNamespace() throws {
        let v6 = try #require(VoiceProtocol.Names(version: 6))
        #expect(v6.activity(["lk.agent.state": "listening", "nanoclaw.voice-mode.thinking": "1"]) == .thinking)
        #expect(v6.activity(["lk.agent.state": "listening", "nanoclaw.voice.thinking": "1"]) == .listening)
    }

    @Test func updatingOnlyOnOne() throws {
        let v4 = try #require(VoiceProtocol.Names(version: 4)), v6 = try #require(VoiceProtocol.Names(version: 6))
        #expect(v4.isUpdating(["nanoclaw.voice.updating": "1"]))
        #expect(!v4.isUpdating(["nanoclaw.voice.updating": ""]))
        #expect(!v4.isUpdating([:]))
        #expect(v6.isUpdating(["nanoclaw.voice-mode.updating": "1"]))
        #expect(!v6.isUpdating(["nanoclaw.voice.updating": "1"]))
    }

    @Test func onlyProtocols4And6HaveNames() {
        #expect([3, 4, 5, 6, 7].compactMap { VoiceProtocol.Names(version: $0)?.version } == [4, 6])
    }

    @Test func onlyProtocol6NamesItsProtocolAttribute() throws {
        #expect(try #require(VoiceProtocol.Names(version: 4)).protocolAttribute == nil)
        #expect(try #require(VoiceProtocol.Names(version: 6)).protocolAttribute == "nanoclaw.voice-mode.protocol")
    }

    @Test func aProtocol4CallSpotsAProtocol5Worker() throws {
        let v4 = try #require(VoiceProtocol.Names(version: 4)), v6 = try #require(VoiceProtocol.Names(version: 6))
        let protocol5 = ["lk.agent.state": "listening", "nanoclaw.voice-mode.commands": "3"]
        #expect(v4.isProtocol5Worker(protocol5))
        #expect(!v4.isProtocol5Worker(["lk.agent.state": "listening", "nanoclaw.voice.commands": "3"]))
        #expect(!v4.isProtocol5Worker([:]))
        #expect(!v6.isProtocol5Worker(protocol5))
    }

    @Test func namesFollowTheHostsProtocol() throws {
        let v4 = try #require(VoiceProtocol.Names(version: 4)), v6 = try #require(VoiceProtocol.Names(version: 6))
        func all(_ n: VoiceProtocol.Names) -> [String] {
            [
                n.thinkingAttribute, n.updatingAttribute, n.commandsAttribute, n.commandWordsAttribute, n.captionCommandAttribute,
                n.captionWordsAttribute, n.reviewAttribute, n.settingsMethod,
            ] + n.streamTopics
        }
        #expect(all(v4) == [
            "nanoclaw.voice.thinking", "nanoclaw.voice.updating", "nanoclaw.voice.commands", "nanoclaw.voice.command-words",
            "nanoclaw.voice.command", "nanoclaw.voice.words", "nanoclaw.voice.review", "nanoclaw.voice.settings",
            "lk.transcription", "nanoclaw.voice.turn", "nanoclaw.voice.reply", "nanoclaw.voice.review",
        ])
        #expect(all(v6) == [
            "nanoclaw.voice-mode.thinking", "nanoclaw.voice-mode.updating", "nanoclaw.voice-mode.commands",
            "nanoclaw.voice-mode.command-words", "nanoclaw.voice-mode.command", "nanoclaw.voice-mode.words",
            "nanoclaw.voice-mode.review", "nanoclaw.voice-mode.settings",
            "lk.transcription", "nanoclaw.voice-mode.turn", "nanoclaw.voice-mode.reply", "nanoclaw.voice-mode.review",
        ])
    }

    @Test func readsTheEndReason() {
        #expect(VoiceProtocol.endReasonText(roomMetadata: #"{"chat":null,"end":"newer_call"}"#) == "A newer call on this line took over.")
        #expect(VoiceProtocol.endReasonText(roomMetadata: #"{"chat":"Dan DM"}"#) == nil)
        #expect(VoiceProtocol.endReasonText(roomMetadata: #"{"end":"something_new"}"#) == nil)
        #expect(VoiceProtocol.endReasonText(roomMetadata: nil) == nil)
    }
}

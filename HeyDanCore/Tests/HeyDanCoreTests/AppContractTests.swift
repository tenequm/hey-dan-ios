import Foundation
import CryptoKit
import Testing
@testable import HeyDanCore

private func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
private func ensure(_ condition: Bool, _ label: String) throws {
    if !condition { throw CheckFailure(label: label) }
}
private struct CheckFailure: Error { let label: String }

@Test func allWireFixturesDecode() throws {
    let f = try coreFixtures()
    _ = try fixtureDecode(HelloResponse.self, f["hello"]!)
    _ = try fixtureDecode(PairRequest.self, f["pairRequest"]!)
    _ = try fixtureDecode(PairResponse.self, f["pairResponse"]!)
    let conversations = try fixtureDecode(ConversationsResponse.self, f["conversations"]!)
    try ensure(conversations.conversations.map(\.id) == ["conv_taylor01"], "conversation list contains only Taylor")
    let refused = try fixtureDecode(Conversation.self, f["conversationCallRefused"]!)
    try ensure(refused.id == "conv_sam01" && !refused.canCall && refused.callRefusal?.error == "no_line", "separate call refusal")
    _ = try fixtureDecode(HistoryPage.self, f["historyPage"]!)
    let messages = f["messages"] as! [String: Any]
    for (name, value) in messages {
        if name == "send" { for v in (value as! [String: Any]).values { _ = try fixtureDecode(Message.self, v) } }
        else if name == "editSequence" { for v in value as! [Any] { _ = try fixtureDecode(Message.self, v) } }
        else { _ = try fixtureDecode(Message.self, value) }
    }
    for v in (f["questions"] as! [String: Any]).values { _ = try fixtureDecode(Question.self, v) }
    for v in (f["statuses"] as! [String: Any]).values { _ = try fixtureDecode(Status.self, v) }
    for group in ["errors", "callErrors"] {
        for v in (f[group] as! [String: [String: Any]]).values { _ = try fixtureDecode(ErrorBody.self, v["body"]!) }
    }
    let errors = f["errors"] as! [String: [String: Any]]
    for (name, status, code) in [("badProof", 400, "bad_proof"), ("answerNotDelivered", 502, "answer_not_delivered")] {
        let fixture = errors[name]!
        try ensure(fixture["status"] as? Int == status, "error HTTP status")
        try ensure(try fixtureDecode(ErrorBody.self, fixture["body"]!).error == code, "error code decoded")
    }
    _ = try fixtureDecode(ErrorBody.self, (f["answerConflict"] as! [String: Any])["body"]!)
    _ = try fixtureDecode(SendRequest.self, f["sendRequest"]!)
    _ = try fixtureDecode(SendResponse.self, f["sendResponse"]!)
    _ = try fixtureDecode(ReadRequest.self, f["readRequest"]!)
    _ = try fixtureDecode(ReadResponse.self, f["readResponse"]!)
    _ = try fixtureDecode(AnswerRequest.self, f["answerRequest"]!)
    _ = try fixtureDecode(AnswerResponse.self, f["answerResponse"]!)
    _ = try fixtureDecode(FileInitRequest.self, f["fileInitRequest"]!)
    _ = try fixtureDecode(FileInitResponse.self, f["fileInitResponse"]!)
    _ = try fixtureDecode(FileTicketRenewResponse.self, f["fileTicketRenewResponse"]!)
    _ = try fixtureDecode(CallRequest.self, f["callRequest"]!)
    _ = try fixtureDecode(CallGrant.self, f["callGrant"]!)
    _ = try fixtureDecode(CallEndRequest.self, f["callEndRequest"]!)
    _ = try fixtureDecode(CallCancelRequest.self, f["callCancelRequest"]!)
    try ensure(try fixtureDecode(Delivery.self, "unknown") == .outcomeUnknown, "known uncertain delivery")
    try ensure(try fixtureDecode(Delivery.self, "failed") == .failed, "known failed delivery")
    _ = try fixtureDecode(PushTokenRequest.self, f["pushTokenRequest"]!)
    let push = try fixtureDecode(PushPayload.self, (f["pushPayload"] as! [String: Any])["body"]!)
    try ensure(push.hd.h == "https://app.example.com", "push host decoded")
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(push)) as! [String: Any]
    try ensure((roundTrip["aps"] as! [String: Any])["thread-id"] != nil, "push coding keys")
    try ensure((roundTrip["hd"] as! [String: Any])["h"] as? String == push.hd.h, "push host encoded")
    let future = try fixtureDecode(Message.self, messages["future"]!)
    if case .unknown = future.role {} else { throw CheckFailure(label: "unknown role") }
    if case .unknown = future.voice {} else { throw CheckFailure(label: "unknown voice") }
    try ensure(try fixtureDecode(Kind.self, "future") == .unknown("future"), "unknown kind")
    try ensure(try fixtureDecode(State.self, "future") == .unknown("future"), "unknown state")
    try ensure(try fixtureDecode(Delivery.self, "future") == .unknown("future"), "unknown delivery")
    _ = try fixtureDecode(ThreadEntity.self, ["kind": "future", "extension": 1])
    // Metadata and deliberately future fixture fields must also survive generic JSON decoding.
    for value in f.values { _ = try fixtureDecode(JSONValue.self, value) }
}

@Test func signingAndCrossLanguageSignature() throws {
    let f = try coreFixtures(), signing = f["signing"] as! [String: Any]
    let vectors = signing["vectors"] as! [[String: Any]]
    let keyData = f["testKey"] as! [String: Any]
    let key = try P256.Signing.PrivateKey(pemRepresentation: keyData["privateKeyPkcs8Pem"] as! String)
    var v = vectors.first { $0["name"] as? String == "post-json" }!
    let signature = try key.signature(for: Data((v["canonical"] as! String).utf8)).derRepresentation
    let nonceText = v["nonce"] as! String
    let nonce = Data(base64Encoded: nonceText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "==")!
    v["signature"] = SigningText.base64url(signature)
    v["authorization"] = try Authorization(protocol: v["protocol"] as! Int, deviceId: v["deviceId"] as! String,
        ts: (v["ts"] as! NSNumber).int64Value, nonce: nonce, bodyHash: v["bodyHash"] as! String, signature: signature).header
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let local = root.appendingPathComponent(".local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let output = local.appendingPathComponent("swift-signature.json")
    try bytes(v).write(to: output, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    let pair = f["pairRequest"] as! [String: Any]
    try ensure(SigningText.pairProof(code: pair["code"] as! String, publicKey: pair["publicKey"] as! String) == f["pairProofText"] as! String, "pair text")
}

@Test func targetBuilder() throws {
    for path in [[""], ["."], [".."], ["a;b"], ["a/b"], ["a\\b"]] {
        do { _ = try RequestTarget.build(path: path); throw CheckFailure(label: "accepted invalid path") }
        catch ContractError.invalidTarget {}
    }
    try ensure(try RequestTarget.build(path: ["~_-.AZ09"], query: [("q", "a+b&c=100%")]) == "/app/~_-.AZ09?q=a%2Bb%26c%3D100%25", "reserved escaping")
}

@Test func sseFramingEdges() throws {
    var parser = SSEParser()
    let input = Data("\u{feff}: ping\r\nevent: future\r\nid: 9\r\ndata: first\r\ndata: кіт\r\n\r\nevent: status\ndata: {}\n\n".utf8)
    var events: [AppEvent] = []
    for b in input { events += try parser.feed(Data([b])) }
    try ensure(events.count == 2 && events[0].kind == .unknown("future"), "CRLF and unknown event")
    try ensure(String(data: events[0].data, encoding: .utf8) == "first\nкіт", "multiline UTF8")
    try ensure(events[1].id == nil, "id does not leak into status")
    try ensure(try events[0].cursor(after: 3) == 9, "unknown advances cursor")
    var incomplete = SSEParser()
    try ensure(try incomplete.feed(Data("data: {}\n".utf8)).isEmpty, "no event before blank line")

}

@Test func richCardWireFixture() throws {
    let messages = try #require(coreFixtures()["messages"] as? [String: Any])
    let wire = try #require(messages["richCard"] as? [String: Any])
    let message = try fixtureDecode(Message.self, wire)
    let card = try #require(message.card)
    #expect(message.role == .agent)
    #expect(!message.text.isEmpty)
    #expect(card.actions.count == 2)
    #expect(card.actions.allSatisfy { $0.webURL != nil })
    #expect(card.parts.count == 5)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? NSDictionary
    #expect(encoded == wire["card"] as? NSDictionary)
    #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)) == message)
}

@Test func cardDecoderPreservesKnownPartsAndLegacyMessages() throws {
    let messages = try #require(coreFixtures()["messages"] as? [String: Any])
    var wire = try #require(messages["agentMarkdown"] as? [String: Any])
    wire.removeValue(forKey: "card")
    #expect(try fixtureDecode(Message.self, wire).card == nil)
    wire["card"] = NSNull()
    #expect(try fixtureDecode(Message.self, wire).card == nil)

    let parts: [Any] = [
        ["type": "new-part"], ["type": "table", "rows": false],
        ["type": "chart", "title": "Future", "chart": ["type": "radar"]],
        ["type": "divider"], ["type": "text", "content": "Still here", "style": "bold"]
    ]
    wire["card"] = ["parts": parts, "actions": []] as [String: Any]
    let message = try fixtureDecode(Message.self, wire)
    #expect(message.card?.parts == [.divider, .text(content: "Still here", style: "bold")])
    #expect(message.text == wire["text"] as? String)

    for card: Any in [["title": "No actions", "parts": [["type": "divider"]]], ["parts": ["type": "divider"], "actions": []],
                      ["title": 7, "parts": [], "actions": []], "not a card"] {
        wire["card"] = card
        #expect(try fixtureDecode(Message.self, wire).text == wire["text"] as? String)
    }
    wire["card"] = ["title": "No actions", "parts": [["type": "divider"]]] as [String: Any]
    #expect(try fixtureDecode(Message.self, wire).card == Card(title: "No actions", description: nil, parts: [.divider], actions: []))
}

@Test func unreadableItemKeepsTheRestOfItsHistoryPage() throws {
    let messages = try #require(coreFixtures()["messages"] as? [String: Any])
    let good = try #require(messages["agentMarkdown"] as? [String: Any])
    var bad = good
    bad["id"] = "msg_bad"
    bad["files"] = "not files"
    let page = try fixtureDecode(HistoryPage.self, ["items": [bad, good], "hasMoreBefore": false, "hasMoreAfter": false])
    #expect(page.items.count == 2)
    guard case .unknown = page.items[0] else { Issue.record("an unreadable message should decode as unknown"); return }
    guard case .message = page.items[1] else { Issue.record("the readable message should survive"); return }
}

@Test func cardChartShapesRoundTrip() throws {
    let pie = try fixtureDecode(CardChart.self, ["type": "pie", "segments": [["label": "Photos", "value": 2.5]]])
    #expect(pie == .pie([.init(label: "Photos", value: 2.5)]))
    for type in [CardChart.Plot.bar, .line, .area] {
        let wire: [String: Any] = ["type": type.rawValue, "categories": ["A", "B"],
                                    "series": [["name": "Size", "values": [0.5, 2]]]]
        let chart = try fixtureDecode(CardChart.self, wire)
        #expect(chart == .plot(type, categories: ["A", "B"], series: [.init(name: "Size", values: [0.5, 2])]))
        #expect(try JSONDecoder().decode(CardChart.self, from: JSONEncoder().encode(chart)) == chart)
    }
}

@Test func agentsAndUnreadWireFixtures() throws {
    let f = try coreFixtures()
    let hello = try fixtureDecode(HelloResponse.self, #require(f["hello"]))
    #expect(hello.features.contains("agents") && hello.features.contains("unread"))
    let list = try fixtureDecode(AgentsResponse.self, #require(f["agentsResponse"]))
    #expect(list.agents.contains { $0.chat != nil && $0.shown })
    let request = try fixtureDecode(AgentVisibilityRequest.self, #require(f["setAgentRequest"]))
    let response = try fixtureDecode(AgentResponse.self, #require(f["setAgentResponse"]))
    #expect(response.agent.shown == request.shown)
    let unread = try fixtureDecode(ReadResponse.self, #require(f["unreadResponse"]))
    #expect(unread.conversation.unread > 0 && unread.badge.unreadTotal >= unread.conversation.unread)
    let errors = try #require(f["errors"] as? [String: [String: Any]])
    let conflict = try #require(errors["nothingUnread"])
    #expect(conflict["status"] as? Int == 409)
    #expect(try fixtureDecode(ErrorBody.self, #require(conflict["body"])).error == "nothing_unread")
}

@Test func voiceAttachmentWireStatesAndUploadDuration() throws {
    let fixtures = try coreFixtures()
    let hello = try fixtureDecode(HelloResponse.self, #require(fixtures["hello"]))
    #expect(!hello.features.contains("voice-messages"))
    var enabled = hello
    enabled.features.append("voice-messages")
    #expect(try JSONDecoder().decode(HelloResponse.self, from: JSONEncoder().encode(enabled)).features.contains("voice-messages"))

    let voice = try #require(fixtures["voiceMessages"] as? [String: Any])
    let mint = try fixtureDecode(FileInitRequest.self, #require(voice["fileInitRequest"]))
    let attachment = Outbox.Attachment(localFileName: "draft", name: mint.name, mimeType: mint.mimeType,
        size: mint.size, sha256: mint.sha256, durationMs: mint.durationMs)
    let restored = try JSONDecoder().decode(Outbox.Attachment.self, from: JSONEncoder().encode(attachment))
    #expect(restored.request.durationMs == 1250)
    let pending = try fixtureDecode(FileAttachment.self, #require(voice["pendingFile"]))
    #expect(pending.kind == .audio && pending.durationMs == mint.durationMs)
    #expect(pending.transcript == .init(state: .pending))
    let done = try fixtureDecode(FileAttachment.Transcript.self, #require(voice["done"]))
    #expect(done.state == .done && done.text?.isEmpty == false)
    let failed = try fixtureDecode(FileAttachment.Transcript.self, #require(voice["failed"]))
    #expect(failed == .init(state: .failed))
    let legacy = try fixtureDecode(FileInitRequest.self, #require(fixtures["fileInitRequest"]))
    #expect(legacy.durationMs == nil)
}

@Test func unknownTranscriptStateKeepsTheVoiceMessage() throws {
    let fixtures = try coreFixtures()
    let send = try #require(fixtures["sendResponse"] as? [String: Any])
    var message = try #require(send["message"] as? [String: Any])
    let voice = try #require(fixtures["voiceMessages"] as? [String: Any])
    var file = try #require(voice["pendingFile"] as? [String: Any])
    file["transcript"] = ["state": "unavailable"]
    message["text"] = ""
    message["files"] = [file]
    let entity = try fixtureDecode(ThreadEntity.self, message)
    guard case .message(let decoded) = entity else {
        Issue.record("Voice attachment made its message unreadable")
        return
    }
    let attachment = try #require(decoded.files.first)
    #expect(attachment.transcript?.state == .unknown("unavailable"))
    let encoded = try JSONEncoder().encode(attachment.transcript?.state)
    #expect(try JSONDecoder().decode(String.self, from: encoded) == "unavailable")
}

@Test func agentSettingsWireFixtures() throws {
    let fixtures = try coreFixtures()
    let hello = try fixtureDecode(HelloResponse.self, #require(fixtures["hello"]))
    #expect(hello.features.contains("agent-status") && hello.features.contains("agent-settings"))
    let status = try fixtureDecode(AgentStatusResponse.self, #require(fixtures["agentStatusResponse"])).status
    #expect(status.agent.model.id == nil)
    #expect(status.agent.chipLabel == "Sonnet 5.5 - High")
    #expect(status.agent.effort == nil && status.agent.effectiveEffort == "high")
    #expect(status.session.contextTokens == nil)
    let request = try fixtureDecode(AgentSettingsRequest.self, #require(fixtures["agentSettingsRequest"]))
    let saved = try fixtureDecode(AgentSettingsResponse.self, #require(fixtures["agentSettingsResponse"])).agent
    #expect(request.model == .value("opus"))
    #expect(saved.model.id == "claude-opus-5")
    #expect(saved.chipLabel == "Opus 5 - High")
    let failures = try #require(fixtures["agentSettingsErrors"] as? [String: [String: Any]])
    for (name, code) in [("invalidModel", "invalid_value"), ("invalidEffort", "invalid_value"),
                         ("invalidSettings", "invalid_value"), ("forbidden", "forbidden"), ("notFound", "not_found")] {
        let failure = try #require(failures[name])
        #expect(try fixtureDecode(ErrorBody.self, #require(failure["body"])).error == code)
    }
    #expect(request.effort == .value(try #require(saved.effort)))
    let patch = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentSettingsRequest(model: nil, effort: .value("low")))) as? [String: String]
    #expect(patch == ["effort": "low"])
    let reset = try fixtureDecode(AgentSettingsRequest.self, #require(fixtures["agentSettingsResetRequest"]))
    #expect(reset.model == .inherited && reset.effort == .inherited)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reset)) as? [String: NSNull]
    #expect(encoded?.keys.sorted() == ["effort", "model"])
    let partial = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentSettingsRequest(model: .inherited, effort: nil))) as? [String: NSNull]
    #expect(partial?.keys.sorted() == ["model"])
    #expect(AgentStatus.effortName("xhigh") == "Extra high")
}

@Test func contextUsageFormatting() {
    func usage(_ used: Int?, _ window: Int?) -> AgentStatus.Session {
        .init(contextTokens: used, contextWindow: window, turns: nil, outputTokens: nil, queueDepth: nil)
    }
    #expect(usage(nil, 165000).usageDescription() == nil)
    #expect(usage(84000, 165000).usageDescription() == "84k of 165k used")
    #expect(usage(84000, 165000).usageDescription(includingPercent: true) == "84k of 165k tokens used (51%)")
    #expect(usage(0, 1000000).usageDescription(includingPercent: true) == "0 of 1M tokens used (0%)")
    #expect(usage(432, 0).usageDescription() == "432 tokens used")
    #expect(usage(99000, 165000).usageDescription(spoken: true) == "99 thousand of 165 thousand tokens, 60 percent")
    #expect(usage(80000, 100000).usageDescription(spoken: true) == "80 thousand of 100 thousand tokens, 80 percent, nearly full")
}

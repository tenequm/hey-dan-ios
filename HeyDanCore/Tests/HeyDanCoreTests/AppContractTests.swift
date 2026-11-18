import Foundation
import CryptoKit
import Testing
@testable import HeyDanCore

private let fixturePath = ProcessInfo.processInfo.environment["APP_CONTRACT_FIXTURES"] ?? Bundle.module.url(forResource: "app-contract.fixtures", withExtension: "json")!.path
private func fixtures() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath))) as! [String: Any]
}
private func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: bytes(value)) }
private func ensure(_ condition: Bool, _ label: String) throws {
    if !condition { throw CheckFailure(label: label) }
}
private struct CheckFailure: Error { let label: String }

@Test func allWireFixturesDecode() throws {
    let f = try fixtures()
    _ = try decode(HelloResponse.self, f["hello"]!)
    _ = try decode(PairRequest.self, f["pairRequest"]!)
    _ = try decode(PairResponse.self, f["pairResponse"]!)
    let conversations = try decode(ConversationsResponse.self, f["conversations"]!)
    try ensure(conversations.conversations.map(\.id) == ["conv_taylor01"], "conversation list contains only Taylor")
    let refused = try decode(Conversation.self, f["conversationCallRefused"]!)
    try ensure(refused.id == "conv_sam01" && !refused.canCall && refused.callRefusal?.error == "no_line", "separate call refusal")
    _ = try decode(HistoryPage.self, f["historyPage"]!)
    let messages = f["messages"] as! [String: Any]
    for (name, value) in messages {
        if name == "send" { for v in (value as! [String: Any]).values { _ = try decode(Message.self, v) } }
        else if name == "editSequence" { for v in value as! [Any] { _ = try decode(Message.self, v) } }
        else { _ = try decode(Message.self, value) }
    }
    for v in (f["questions"] as! [String: Any]).values { _ = try decode(Question.self, v) }
    for v in (f["statuses"] as! [String: Any]).values { _ = try decode(Status.self, v) }
    for group in ["errors", "callErrors"] {
        for v in (f[group] as! [String: [String: Any]]).values { _ = try decode(ErrorBody.self, v["body"]!) }
    }
    let errors = f["errors"] as! [String: [String: Any]]
    for (name, status, code) in [("badProof", 400, "bad_proof"), ("answerNotDelivered", 502, "answer_not_delivered")] {
        let fixture = errors[name]!
        try ensure(fixture["status"] as? Int == status, "error HTTP status")
        try ensure(try decode(ErrorBody.self, fixture["body"]!).error == code, "error code decoded")
    }
    _ = try decode(ErrorBody.self, (f["answerConflict"] as! [String: Any])["body"]!)
    _ = try decode(SendRequest.self, f["sendRequest"]!)
    _ = try decode(SendResponse.self, f["sendResponse"]!)
    _ = try decode(ReadRequest.self, f["readRequest"]!)
    _ = try decode(ReadResponse.self, f["readResponse"]!)
    _ = try decode(AnswerRequest.self, f["answerRequest"]!)
    _ = try decode(AnswerResponse.self, f["answerResponse"]!)
    _ = try decode(FileInitRequest.self, f["fileInitRequest"]!)
    _ = try decode(FileInitResponse.self, f["fileInitResponse"]!)
    _ = try decode(FileTicketRenewResponse.self, f["fileTicketRenewResponse"]!)
    _ = try decode(TicketClaims.self, (f["fileUpload"] as! [String: Any])["ticketClaims"]!)
    _ = try decode(CallRequest.self, f["callRequest"]!)
    _ = try decode(CallGrant.self, f["callGrant"]!)
    _ = try decode(CallEndRequest.self, f["callEndRequest"]!)
    _ = try decode(CallCancelRequest.self, f["callCancelRequest"]!)
    try ensure(try decode(Delivery.self, "unknown") == .outcomeUnknown, "known uncertain delivery")
    try ensure(try decode(Delivery.self, "failed") == .failed, "known failed delivery")
    for code in ["upload_key_conflict", "attempt_conflict"] {
        let groups = [f["errors"], f["callErrors"]].compactMap { $0 as? [String: [String: Any]] }
        let bodies = try groups.flatMap { $0.values }.map { try decode(ErrorBody.self, $0["body"]!) }
        try ensure(bodies.contains { $0.error == code }, "conflict error decoded")
    }
    _ = try decode(PushTokenRequest.self, f["pushTokenRequest"]!)
    let push = try decode(PushPayload.self, (f["pushPayload"] as! [String: Any])["body"]!)
    try ensure(push.hd.h == "https://app.example.com", "push host decoded")
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(push)) as! [String: Any]
    try ensure((roundTrip["aps"] as! [String: Any])["thread-id"] != nil, "push coding keys")
    try ensure((roundTrip["hd"] as! [String: Any])["h"] as? String == push.hd.h, "push host encoded")
    let future = try decode(Message.self, messages["future"]!)
    if case .unknown = future.role {} else { throw CheckFailure(label: "unknown role") }
    if case .unknown = future.voice {} else { throw CheckFailure(label: "unknown voice") }
    try ensure(try decode(Kind.self, "future") == .unknown("future"), "unknown kind")
    try ensure(try decode(State.self, "future") == .unknown("future"), "unknown state")
    try ensure(try decode(Delivery.self, "future") == .unknown("future"), "unknown delivery")
    _ = try decode(ThreadEntity.self, ["kind": "future", "extension": 1])
    // Metadata and deliberately future fixture fields must also survive generic JSON decoding.
    for value in f.values { _ = try decode(JSONValue.self, value) }
}

@Test func signingAndCrossLanguageSignature() throws {
    let f = try fixtures(), signing = f["signing"] as! [String: Any]
    let vectors = signing["vectors"] as! [[String: Any]]
    for v in vectors {
        let text = SigningText.canonical(protocol: v["protocol"] as! Int, method: v["method"] as! String,
            target: v["target"] as! String, ts: (v["ts"] as! NSNumber).int64Value, nonce: v["nonce"] as! String,
            bodyHash: SigningText.bodyHash(Data((v["body"] as! String).utf8)), deviceId: v["deviceId"] as! String)
        try ensure(Data(text.utf8) == Data((v["canonical"] as! String).utf8), "canonical bytes")
    }
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
    let f = try fixtures(), vectors = (f["signing"] as! [String: Any])["vectors"] as! [[String: Any]]
    let v = vectors.first { $0["name"] as? String == "get-encoded-query" }!
    let target = try RequestTarget.build(path: ["conversations", "conv_taylor01", "voices"], query: [("provider", "gemini"), ("q", "кіт cat"), ("limit", "20")])
    try ensure(target == v["target"] as! String, "encoded query target")
    for path in [[""], ["."], [".."], ["a;b"], ["a/b"], ["a\\b"]] {
        do { _ = try RequestTarget.build(path: path); throw CheckFailure(label: "accepted invalid path") }
        catch ContractError.invalidTarget {}
    }
    try ensure(try RequestTarget.build(path: ["~_-.AZ09"], query: [("q", "a+b&c=100%")]) == "/app/~_-.AZ09?q=a%2Bb%26c%3D100%25", "reserved escaping")
}

private struct Reducer {
    var cursor: Int64 = 0
    var messages: [String: Message] = [:]
    var questions: [String: Question] = [:]
    var conversations: [String: Conversation] = [:]
    var statuses: [String: Status] = [:]
    var badge: Badge?
    mutating func upsert(_ message: Message) {
        if message.seq > (messages[message.id]?.seq ?? -1) { messages[message.id] = message }
    }
    mutating func apply(_ event: AppEvent) throws {
        switch event.kind {
        case .message: upsert(try event.decode(Message.self))
        case .question:
            let q = try event.decode(Question.self)
            if q.seq > (questions[q.id]?.seq ?? -1) { questions[q.id] = q }
        case .conversation:
            let c = try event.decode(Conversation.self)
            if c.seq > (conversations[c.id]?.seq ?? -1) { conversations[c.id] = c }
        case .status:
            let s = try event.decode(Status.self)
            if s.rev > (statuses[s.conversationId]?.rev ?? -1) { statuses[s.conversationId] = s }
        case .badge:
            let b = try event.decode(Badge.self)
            if b.rev > (badge?.rev ?? -1) { badge = b }
        default: break
        }
        cursor = try event.cursor(after: cursor)
    }
    var threadOrder: [String] {
        (messages.values.map { ($0.id, $0.order) } + questions.values.map { ($0.id, $0.order) }).sorted { $0.1 < $1.1 }.map(\.0)
    }
}

@Test func chunkedStreamAndReducer() throws {
    let f = try fixtures(), stream = f["stream"] as! [String: Any], expected = stream["expect"] as! [String: Any]
    let raw = Data((stream["raw"] as! String).utf8)
    for size in [1, 7, 4096] {
        var parser = SSEParser(), events: [AppEvent] = []
        for start in stride(from: 0, to: raw.count, by: size) { events += try parser.feed(raw.subdata(in: start..<min(start + size, raw.count))) }
        try ensure(events.map { $0.kind.rawValue } == expected["kindsInOrder"] as! [String], "event kind order")
        var reducer = Reducer()
        for event in events {
            let previous = reducer.cursor
            try reducer.apply(event)
            if event.kind == .status || event.kind == .badge { try ensure(reducer.cursor == previous, "status does not move cursor") }
            if event.kind == .synchronized { try ensure(reducer.cursor == (expected["cursorAtSynchronized"] as! NSNumber).int64Value, "synchronized cursor") }
        }
        try ensure(reducer.cursor == (expected["cursorAfter"] as! NSNumber).int64Value, "final cursor")
        try ensure(reducer.threadOrder == expected["finalThreadOrder"] as! [String], "stable thread order")
        let rendered = reducer.threadOrder.filter { id in
            guard let m = reducer.messages[id] else { return true }
            if case .unknown = m.role { return false }
            if case .unknown = m.voice { return false }
            return true
        }
        try ensure(rendered == expected["renderedThreadOrder"] as! [String], "rendered thread order")
        let finalStatus = expected["finalStatus"] as! [String: Any]
        let status = reducer.statuses["conv_taylor01"]!
        try ensure(status.rev == (finalStatus["rev"] as! NSNumber).int64Value && status.state.rawValue == finalStatus["state"] as! String, "final status")
        let finalBadge = expected["finalBadge"] as! [String: Any]
        try ensure(reducer.badge?.rev == (finalBadge["rev"] as! NSNumber).int64Value && reducer.badge?.unreadTotal == finalBadge["unreadTotal"] as? Int, "final badge")
        var staleStatus = status
        staleStatus.rev -= 1
        staleStatus.at += 10000
        staleStatus.state = .working
        try reducer.apply(AppEvent(kind: .status, data: JSONEncoder().encode(staleStatus)))
        let currentBadge = reducer.badge!
        var staleBadge = currentBadge
        staleBadge.rev -= 1
        staleBadge.unreadTotal += 10
        try reducer.apply(AppEvent(kind: .badge, data: JSONEncoder().encode(staleBadge)))
        try ensure(reducer.statuses[status.conversationId] == status, "status uses rev rather than time")
        try ensure(reducer.badge == currentBadge, "stale badge ignored")
        for (id, fields) in expected["finalEntities"] as! [String: [String: Any]] {
            if let m = reducer.messages[id] {
                try ensure(m.seq == (fields["seq"] as! NSNumber).int64Value, "message seq")
                if let delivery = fields["delivery"] as? String { try ensure(m.delivery?.rawValue == delivery, "delivery") }
                if let text = fields["text"] as? String { try ensure(m.text == text, "edited text") }
                if let count = fields["reactions"] as? Int { try ensure(m.reactions.count == count, "reactions") }
            } else if let q = reducer.questions[id] {
                try ensure(q.seq == (fields["seq"] as! NSNumber).int64Value && q.state.rawValue == fields["state"] as! String, "question state")
            } else { throw CheckFailure(label: "missing entity") }
        }
        let cursor = reducer.cursor
        var rest = try decode(SendResponse.self, f["sendResponse"]!).message
        rest.seq = cursor + 1000
        reducer.upsert(rest)
        try ensure(reducer.cursor == cursor, "REST must not advance cursor")
        let old = try decode(SendResponse.self, f["sendResponse"]!).message
        reducer.upsert(old)
        try ensure(reducer.messages[rest.id]?.seq == rest.seq, "stale copy ignored")
    }
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
    var bounded = SSEParser(maximumEventBytes: 3)
    do { _ = try bounded.feed(Data("abcd".utf8)); throw CheckFailure(label: "unbounded event") }
    catch ContractError.eventTooLarge {}
}

@Test func voicePickerFixturesAndNullableSavedChoices() throws {
    let path = ProcessInfo.processInfo.environment["VOICE_TTS_FIXTURES"] ?? Bundle.module.url(forResource: "voice-mode-tts.fixtures", withExtension: "json")!.path
    let f = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    for name in ["ttsView", "ttsViewNew"] {
        let view = try decode(VoiceView.self, f[name]!)
        try ensure(view.providers.contains { $0.defaultDetails?.voiceName == nil }, "nullable fixture voice name")
        var nullable = f[name] as! [String: Any]
        nullable["saved"] = ["provider": NSNull(), "model": NSNull(), "voice": NSNull()]
        let decoded = try decode(VoiceView.self, nullable)
        try ensure(decoded.saved.provider == nil && decoded.saved.model == nil && decoded.saved.voice == nil, "nullable saved choice")
        try ensure(decoded.effective == view.effective, "effective remains resolved")
    }
    for name in ["catalogGemini", "catalogElevenLast"] { _ = try decode(VoiceCatalog.self, f[name]!) }
    try ensure(try RequestTarget.build(path: ["calls", "attempts", "attempt_1", "cancel"]) == "/app/calls/attempts/attempt_1/cancel", "cancel route")
}

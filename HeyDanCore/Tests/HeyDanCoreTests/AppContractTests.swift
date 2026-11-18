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
    var bounded = SSEParser(maximumEventBytes: 3)
    do { _ = try bounded.feed(Data("abcd".utf8)); throw CheckFailure(label: "unbounded event") }
    catch ContractError.eventTooLarge {}
}

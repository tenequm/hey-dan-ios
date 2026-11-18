import CryptoKit
import Foundation
import HeyDanCore
import XCTest
import Synchronization
@testable import HeyDan

@MainActor final class CallTargetTests: XCTestCase {
    func testPairedSignedRequestsAndGrantDecoding() async throws {
        let seen = Mutex<[URLRequest]>([])
        let attempt = UUID().uuidString
        CallHTTP.handler.withLock { $0 = { request in
            seen.withLock { $0.append(request) }
            if request.url!.path == "/app/calls" {
                return Data("{\"protocol\":6,\"url\":\"wss://example.invalid\",\"token\":\"fixture\",\"callId\":\"call_fixture\",\"attemptId\":\"\(attempt)\",\"agent\":\"Taylor\",\"chat\":\"Taylor (app)\",\"silenceMs\":1400,\"limit\":{\"ms\":90000,\"kind\":\"duration\"}}".utf8)
            }
            return Data()
        } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallHTTP.self]
        let key = P256.Signing.PrivateKey()
        let service = SignedClient(host: URL(string: "https://example.invalid")!, deviceId: "dev_test",
            configuration: configuration, signer: { data, _ in try key.signature(for: data).derRepresentation })
        let conversation = Conversation(kind: .conversation, id: "conv_taylor01", seq: 1,
            agent: Agent(id: "ag_taylor", name: "Taylor"), unread: 0, readOrder: 0, canCall: true, createdAt: 0)
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.invalid")!,
            deviceId: "dev_test", conversation: conversation), service: service, attemptId: attempt)
        let http = URLSession(configuration: .ephemeral)
        defer { http.invalidateAndCancel() }
        let grant = try await target.grant(over: http)
        XCTAssertEqual(grant.callId, "call_fixture")
        XCTAssertEqual(grant.agent, "Taylor")
        try await target.end(callId: grant.callId, reason: .noAgent, over: http)
        try await target.cancel(over: http)
        let requests = seen.withLock { $0 }
        XCTAssertEqual(requests.map { $0.url!.path }, ["/app/calls", "/app/calls/call_fixture/end", "/app/calls/attempts/\(attempt)/cancel"])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("HeyDan-Sig ") == true)
        }
    }

    func testSavedLineRequestsRemainUnchanged() async throws {
        let line = try XCTUnwrap(VoiceLine(callLink: "https://example.invalid/voice?t=fixture"))
        let seen = Mutex<[URLRequest]>([])
        CallHTTP.handler.withLock { $0 = { request in
            seen.withLock { $0.append(request) }
            return request.url!.path.hasSuffix("token")
                ? Data(#"{"protocol":6,"url":"wss://example.invalid","token":"fixture","callId":"call_fixture"}"#.utf8)
                : Data()
        } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallHTTP.self]
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let target = CallTarget(line: line)
        let grant = try await target.grant(over: http)
        try await target.end(callId: grant.callId, reason: .noAgent, over: http)
        let requests = seen.withLock { $0 }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, line.tokenRequest.url)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].url, line.endRequest(callId: grant.callId).url)
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertFalse(target.usesRelay)
    }

    func testCancelWhileGrantIsPendingUsesTheSameAttempt() async throws {
        let service = CallServiceSpy()
        service.delaysGrant = true
        let conversation = Conversation(kind: .conversation, id: "conv_taylor01", seq: 1,
            agent: Agent(id: "ag_taylor", name: "Taylor"), unread: 0, readOrder: 0, canCall: true, createdAt: 0)
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.invalid")!,
            deviceId: "dev_test", conversation: conversation), service: service)
        let http = URLSession(configuration: .ephemeral)
        defer { http.invalidateAndCancel() }
        let pending = Task { try await target.grant(over: http) }
        let deadline = ContinuousClock.now + .seconds(2)
        while service.pendingGrant == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try XCTUnwrap(service.pendingGrant)
        try await target.cancel(over: http)
        XCTAssertEqual(service.cancels.first?.0, target.attemptId)
        continuation.resume()
        service.pendingGrant = nil
        let grant = try await pending.value
        try await target.end(callId: grant.callId, reason: nil, over: http)
        XCTAssertEqual(service.ends.first?.0, grant.callId)
    }

    func testPairedAttemptPersistsAcrossRetriesAndCleanup() async throws {
        let service = CallServiceSpy()
        let conversation = Conversation(kind: .conversation, id: "conv_taylor01", seq: 1,
            agent: Agent(id: "ag_taylor", name: "Taylor"), unread: 0, readOrder: 0, canCall: true, createdAt: 0)
        let identity = PairedCallTarget(host: URL(string: "https://example.com")!, deviceId: "dev_test", conversation: conversation)
        let target = CallTarget(paired: identity, service: service)
        let http = URLSession(configuration: .ephemeral)
        defer { http.invalidateAndCancel() }
        let grant = try await target.grant(over: http)
        _ = try await target.grant(over: http)
        XCTAssertEqual(service.starts.count, 2)
        XCTAssertEqual(service.starts[0], service.starts[1])
        XCTAssertEqual(service.starts[0].conversationId, conversation.id)
        XCTAssertEqual(service.starts[0].voiceProtocol, 6)
        XCTAssertNil(service.starts[0].jev)
        XCTAssertEqual(grant.names.version, 6)
        try await target.end(callId: grant.callId, reason: nil, over: http)
        try await target.cancel(over: http)
        XCTAssertEqual(service.ends.first?.0, "call_test")
        XCTAssertEqual(service.ends.first?.1.reason, "hangup")
        XCTAssertEqual(service.cancels.first?.0, service.starts[0].attemptId)
        XCTAssertEqual(service.cancels.first?.1.reason, "hangup")
        XCTAssertNotEqual(CallTarget(paired: identity, service: service).attemptId, target.attemptId)
    }
}

@MainActor private final class CallServiceSpy: AppService {
    var delaysGrant = false
    var pendingGrant: CheckedContinuation<Void, Never>?
    var starts: [CallRequest] = []
    var ends: [(String, CallEndRequest)] = []
    var cancels: [(String, CallCancelRequest)] = []
    func hello() async throws(AppError) -> HelloResponse { throw .transport(.unavailable) }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse { throw .transport(.unavailable) }
    func conversations() async throws(AppError) -> ConversationsResponse { throw .transport(.unavailable) }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage { throw .transport(.unavailable) }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse { throw .transport(.unavailable) }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse { throw .transport(.unavailable) }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse { throw .transport(.unavailable) }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> { throw .transport(.unavailable) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse { throw .transport(.unavailable) }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse { throw .transport(.unavailable) }
    func upload(fileId: String, ticket: String, bytes: Data, progress: (@Sendable (Double) -> Void)?) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func download(fileId: String) async throws(AppError) -> Data { throw .transport(.unavailable) }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant {
        starts.append(request)
        if delaysGrant { await withCheckedContinuation { pendingGrant = $0 } }
        return CallGrant(protocol: 6, url: "wss://example.com", token: "test", callId: "call_test",
            attemptId: request.attemptId, agent: "Taylor", chat: "Taylor (app)", silenceMs: 1400,
            limit: CallLimit(ms: 3600000, kind: .duration))
    }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) { ends.append((callId, request)) }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) { cancels.append((attemptId, request)) }
    func voice(conversationId: String) async throws(AppError) -> VoiceView { throw .transport(.unavailable) }
    func updateVoice(conversationId: String, request: VoicePatchRequest) async throws(AppError) -> VoiceView { throw .transport(.unavailable) }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> VoiceCatalog { throw .transport(.unavailable) }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func unpair() async throws(AppError) -> Void { throw .transport(.unavailable) }
}

private final class CallHTTP: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) -> Data)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.handler.withLock { $0 }!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

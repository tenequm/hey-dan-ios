import CryptoKit
import Foundation
import HeyDanCore
import XCTest
import Synchronization
@testable import HeyDan

private final class FixtureBundle {}

@MainActor final class CallTargetTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: FixtureBundle.self).url(forResource: "app-contract.fixtures", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(object[name]))
    }

    private let conversation = Conversation(kind: .conversation, id: "conv_taylor01", seq: 1,
        agent: Agent(id: "ag_taylor", name: "Taylor"), unread: 0, readOrder: 0, canCall: true, createdAt: 0)

    func testAgentRefreshReplacesSnapshotAndIgnoresAnOldDevice() async throws {
        let account = "test-agents-" + UUID().uuidString
        defer { try? IdentityKeychain.remove(account: account) }
        let pairings = Pairings(account: account, publishes: false)
        while pairings.state == .unreadable { await Task.yield() }
        let host = URL(string: "https://example.com")!
        let old = Agent(id: "former", name: "Former")
        try pairings.add(PairResponse(deviceId: "current", userName: "Tester", agents: [old], protocol: 1, serverTime: 0),
                         host: host, features: ["calls"])
        pairings.refreshAgents([conversation, conversation], host: host, deviceId: "current")
        pairings.refreshAgents([], host: host, deviceId: "replaced")
        let restored = Pairings(account: account, publishes: false)
        while restored.state == .unreadable { await Task.yield() }
        XCTAssertEqual(restored.active?.agents, [conversation.agent])
        restored.refreshAgents([], host: host, deviceId: "current")
        XCTAssertEqual(restored.active?.agents, [])
    }

    func testInactiveHostDiscoversAgentsWithoutSwitching() async throws {
        let account = "test-inactive-" + UUID().uuidString
        defer { try? IdentityKeychain.remove(account: account) }
        let pairings = Pairings(account: account, publishes: false)
        pairings.loadIfNeeded()
        let inactive = URL(string: "https://old.example.com")!
        let active = URL(string: "https://active.example.com")!
        for host in [inactive, active] {
            try pairings.add(FixtureAppService.pairing, host: host, features: [])
        }
        await pairings.refreshInactiveAgents { _ in FixtureAppService() }
        XCTAssertEqual(pairings.active?.host, active)
        XCTAssertEqual(pairings.entries.first { $0.host == inactive }?.features.contains("agents"), true)
        XCTAssertEqual(pairings.active?.features, [])
    }

    /// The signed start, end and cancel as the contract fixtures write them, and the fixture grant decoded.
    func testPairedRequestsMatchTheContract() async throws {
        let grantBody = try fixture("callGrant")
        let expectedStart = try JSONDecoder().decode(CallRequest.self, from: fixture("callRequest"))
        let seen = Mutex<[URLRequest]>([])
        Stub.handler.withLock { $0 = { request in
            seen.withLock { $0.append(request) }
            return (200, request.url!.path == "/app/calls" ? grantBody : Data())
        } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let key = P256.Signing.PrivateKey()
        let service = SignedClient(host: URL(string: "https://example.invalid")!, deviceId: "dev_test",
            configuration: configuration, signer: { data, _ in try key.signature(for: data).derRepresentation })
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.invalid")!,
            deviceId: "dev_test", conversation: conversation), service: service, attemptId: expectedStart.attemptId)
        let grant = try await target.grant()
        XCTAssertEqual(grant.callId, "call_5tGh2")
        XCTAssertEqual(grant.agent, "Taylor")
        XCTAssertEqual(grant.names.version, 6)
        try await target.end(callId: grant.callId, reason: nil)
        try await target.cancel()
        let requests = seen.withLock { $0 }
        XCTAssertEqual(requests.map { $0.url!.path }, ["/app/calls", "/app/calls/call_5tGh2/end", "/app/calls/attempts/\(expectedStart.attemptId)/cancel"])
        let bodies = requests.map(\.bodyBytes)
        XCTAssertEqual(try JSONDecoder().decode(CallRequest.self, from: bodies[0]), expectedStart)
        XCTAssertEqual(try JSONDecoder().decode(CallEndRequest.self, from: bodies[1]),
            try JSONDecoder().decode(CallEndRequest.self, from: fixture("callEndRequest")))
        XCTAssertEqual(try JSONDecoder().decode(CallCancelRequest.self, from: bodies[2]),
            try JSONDecoder().decode(CallCancelRequest.self, from: fixture("callCancelRequest")))
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("HeyDan-Sig v=1,p=1,d=dev_test,") == true)
        }
    }

    func testCancelWhileGrantIsPendingUsesTheSameAttempt() async throws {
        let service = CallServiceSpy()
        service.delaysGrant = true
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.invalid")!,
            deviceId: "dev_test", conversation: conversation), service: service)
        let pending = Task { try await target.grant() }
        let deadline = ContinuousClock.now + .seconds(2)
        while service.pendingGrant == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try XCTUnwrap(service.pendingGrant)
        try await target.cancel()
        XCTAssertEqual(service.cancels.first?.0, target.attemptId)
        continuation.resume()
        service.pendingGrant = nil
        let grant = try await pending.value
        try await target.end(callId: grant.callId, reason: nil)
        XCTAssertEqual(service.ends.first?.0, grant.callId)
    }

    /// A grant for another attempt is a call this app cannot match: it ends that call and cancels its own attempt.
    func testMismatchedAttemptEndsTheCallAndCancels() async throws {
        let service = CallServiceSpy()
        service.grantAttempt = "another-attempt"
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.com")!, deviceId: "dev_test",
            conversation: conversation), service: service)
        do {
            _ = try await target.grant()
            XCTFail("a mismatched attempt must not be joined")
        } catch { XCTAssertEqual(error, .malformedGrant) }
        XCTAssertEqual(service.starts.first?.voiceProtocol, VoiceProtocol.requestedVersion)
        XCTAssertNil(service.starts.first?.jev)
        XCTAssertEqual(service.ends.first?.0, "call_test")
        XCTAssertEqual(service.ends.first?.1.reason, "updating")
        XCTAssertEqual(service.cancels.first?.0, target.attemptId)
        XCTAssertNotEqual(CallTarget(paired: target.paired, service: service).attemptId, target.attemptId)
    }

    func testPairedFailuresKeepTheirMeaning() {
        let refusal = ErrorBody(error: "no_line", message: "Calls are not set up for this agent.")
        XCTAssertEqual(AppError.server(status: 403, body: refusal).callFailure,
            .server(status: 403, code: "no_line", message: refusal.message))
        XCTAssertEqual(AppError.transport(.invalidResponse).callFailure, .malformedGrant)
        XCTAssertEqual(AppError.transport(.offline).callFailure, .pairedTransport)
        XCTAssertEqual(AppError.keyUnavailable.callFailure.message, AppError.keyUnavailable.message)
        XCTAssertEqual(AppError.notPaired.voiceFailure.message, AppError.notPaired.message)
        XCTAssertEqual(AppError.transport(.invalidResponse).voiceFailure, .malformed)
        XCTAssertEqual(AppError.transport(.timeout).voiceFailure, .pairedTransport)
    }

    func testPairedVoicePickerAdaptsRequests() async throws {
        let service = CallServiceSpy()
        let picker = PairedVoicePickerService(target: PairedCallTarget(host: URL(string: "https://example.com")!,
            deviceId: "dev_test", conversation: conversation), service: service)
        _ = try? await picker.updateVoice(.reset)
        XCTAssertEqual(service.patches.first.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) }, #"{"reset":true}"#)
        let long = String(repeating: "a", count: 511) + "\u{1F600}" + "b"
        _ = try? await picker.voices(VoiceCatalogQuery(provider: "gemini", q: long, language: nil, gender: nil, cursor: nil, limit: 500))
        _ = try? await picker.voices(VoiceCatalogQuery(provider: "gemini", q: nil, language: nil, gender: nil, cursor: nil, limit: 0))
        XCTAssertEqual(service.catalogQueries.first?.q, String(repeating: "a", count: 511))
        XCTAssertEqual(service.catalogQueries.map(\.limit), [100, 1])
        do {
            _ = try await picker.voice()
            XCTFail("the spy refuses")
        } catch { XCTAssertEqual(error, .pairedTransport) }
    }
}

@MainActor private final class CallServiceSpy: AppService {
    var delaysGrant = false
    var grantAttempt: String?
    var patches: [TTSPatch] = []
    var catalogQueries: [VoiceCatalogQuery] = []
    var pendingGrant: CheckedContinuation<Void, Never>?
    var starts: [CallRequest] = []
    var ends: [(String, CallEndRequest)] = []
    var cancels: [(String, CallCancelRequest)] = []
    func hello() async throws(AppError) -> HelloResponse { throw .transport(.unavailable) }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse { throw .transport(.unavailable) }
    func conversations() async throws(AppError) -> ConversationsResponse { throw .transport(.unavailable) }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage { throw .transport(.unavailable) }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse { throw .transport(.unavailable) }
    func agents() async throws(AppError) -> AgentsResponse {
        throw .transport(.unavailable)
    }
    func setAgent(id: String, request: AgentVisibilityRequest) async throws(AppError) -> AgentResponse {
        throw .transport(.unavailable)
    }
    func markUnread(conversationId: String) async throws(AppError) -> ReadResponse {
        throw .transport(.unavailable)
    }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse { throw .transport(.unavailable) }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse { throw .transport(.unavailable) }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> { throw .transport(.unavailable) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse { throw .transport(.unavailable) }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse { throw .transport(.unavailable) }
    func upload(fileId: String, ticket: String, bytes: Data) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func download(fileId: String) async throws(AppError) -> Data { throw .transport(.unavailable) }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant {
        starts.append(request)
        if delaysGrant { await withCheckedContinuation { pendingGrant = $0 } }
        return CallGrant(protocol: 6, url: "wss://example.com", token: "test", callId: "call_test",
            attemptId: grantAttempt ?? request.attemptId, agent: "Taylor")
    }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) { ends.append((callId, request)) }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) { cancels.append((attemptId, request)) }
    func voice(conversationId: String) async throws(AppError) -> TTSView { throw .transport(.unavailable) }
    func updateVoice(conversationId: String, request: TTSPatch) async throws(AppError) -> TTSView {
        patches.append(request)
        throw .transport(.unavailable)
    }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> CatalogPage {
        catalogQueries.append(query)
        throw .transport(.unavailable)
    }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func unpair() async throws(AppError) -> Void { throw .transport(.unavailable) }
}

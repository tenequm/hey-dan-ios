import Foundation
import HeyDanCore
import XCTest
@testable import HeyDan

@MainActor final class CallTargetTests: XCTestCase {
    func testPairedAttemptPersistsAcrossRetriesAndCleanup() async throws {
        let service = CallServiceSpy()
        let conversation = Conversation(kind: .conversation, id: "conv_stan01", seq: 1,
            agent: Agent(id: "ag_stan", name: "Stan"), unread: 0, readOrder: 0, canCall: true, createdAt: 0)
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
    func upload(fileId: String, ticket: String, bytes: Data) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func download(fileId: String) async throws(AppError) -> Data { throw .transport(.unavailable) }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant {
        starts.append(request)
        return CallGrant(protocol: 6, url: "wss://example.com", token: "test", callId: "call_test",
            attemptId: request.attemptId, agent: "Stan", chat: "Stan (app)", silenceMs: 1400,
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

import Foundation
import HeyDanCore

/// H2 owns transport errors and server-authored error bodies.
enum AppError: Error, Sendable {
    case server(status: Int, body: ErrorBody)
    case transport(TransportFailure)
    enum TransportFailure: Sendable { case unavailable, offline, timeout, tls, cancelled, invalidResponse }
}

/// H2 owns one host-scoped service; each method maps to one contract route.
protocol AppService: Sendable {
    func hello() async throws(AppError) -> HelloResponse
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse
    func conversations() async throws(AppError) -> ConversationsResponse
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error>
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse
    func upload(fileId: String, ticket: String, bytes: Data) async throws(AppError) -> Void
    func download(fileId: String) async throws(AppError) -> Data
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) -> Void
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) -> Void
    func voice(conversationId: String) async throws(AppError) -> VoiceView
    func updateVoice(conversationId: String, request: VoicePatchRequest) async throws(AppError) -> VoiceView
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> VoiceCatalog
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void
    func unpair() async throws(AppError) -> Void
}

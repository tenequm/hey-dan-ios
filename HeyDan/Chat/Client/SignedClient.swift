import Foundation
import HeyDanCore

/// H2 replaces unavailable bodies with signed, host-scoped transport.
struct SignedClient: AppService {
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
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant { throw .transport(.unavailable) }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func voice(conversationId: String) async throws(AppError) -> VoiceView { throw .transport(.unavailable) }
    func updateVoice(conversationId: String, request: VoicePatchRequest) async throws(AppError) -> VoiceView { throw .transport(.unavailable) }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> VoiceCatalog { throw .transport(.unavailable) }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func unpair() async throws(AppError) -> Void { throw .transport(.unavailable) }
}

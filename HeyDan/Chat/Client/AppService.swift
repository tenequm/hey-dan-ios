import Foundation
import HeyDanCore

enum AppError: Error, Sendable {
    case server(status: Int, body: ErrorBody)
    case transport(TransportFailure)
    case keyUnavailable, notPaired
    enum TransportFailure: String, Sendable { case unavailable, offline, timeout, tls, cancelled, invalidResponse }
}

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
    func upload(fileId: String, ticket: String, bytes: Data, progress: (@Sendable (Double) -> Void)?) async throws(AppError) -> Void
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

extension AppError {
    static func map(_ error: any Error) -> AppError {
        if let error = error as? AppError { return error }
        if error is CancellationError { return .transport(.cancelled) }
        guard let error = error as? URLError else { return .transport(.invalidResponse) }
        switch error.code {
        case .cancelled: return .transport(.cancelled)
        case .timedOut: return .transport(.timeout)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive: return .transport(.offline)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired: return .transport(.tls)
        case .badServerResponse, .cannotDecodeRawData, .cannotDecodeContentData,
             .cannotParseResponse, .badURL, .unsupportedURL: return .transport(.invalidResponse)
        default: return .transport(.unavailable)
        }
    }
    var logName: String {
        switch self {
        case .server(let status, _): "http_\(status)"
        case .transport(let failure): failure.rawValue
        case .keyUnavailable: "key_unavailable"
        case .notPaired: "not_paired"
        }
    }
    var message: String {
        switch self {
        case .server(_, let body): body.message
        case .keyUnavailable: "Unlock your device and try again."
        case .notPaired: "Pair this device to continue."
        case .transport(.offline): "You are offline. Check your connection and try again."
        case .transport(.timeout): "The request timed out. Try again."
        case .transport(.tls): "A secure connection could not be established."
        case .transport(.cancelled): "The request was cancelled."
        case .transport(.invalidResponse): "The host sent an invalid response."
        case .transport(.unavailable): "The host could not be reached. Try again."
        }
    }
}

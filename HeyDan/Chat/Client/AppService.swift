import Foundation
import HeyDanCore

enum AppError: Error, Sendable {
    case server(status: Int, body: ErrorBody)
    case transport(TransportFailure)
    case keyUnavailable, notPaired
    case pairing(PairingFailure)
    /// Refused on this phone before any request: a message or file over the contract's limits.
    case limit(String)
    /// Unpairing waits for the host's call to end: its hangup is signed with the key unpairing deletes.
    case callActive
    enum TransportFailure: String, Sendable { case unavailable, offline, timeout, tls, cancelled, invalidResponse }
}

protocol AppService: Sendable {
    func hello() async throws(AppError) -> HelloResponse
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse
    func conversations() async throws(AppError) -> ConversationsResponse
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse
    func agentStatus(conversationId: String) async throws(AppError) -> AgentStatusResponse
    func updateSettings(agentId: String, request: AgentSettingsRequest) async throws(AppError) -> AgentSettingsResponse
    func agents() async throws(AppError) -> AgentsResponse
    func setAgent(id: String, request: AgentVisibilityRequest) async throws(AppError) -> AgentResponse
    func markUnread(conversationId: String) async throws(AppError) -> ReadResponse
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
    func voice(conversationId: String) async throws(AppError) -> TTSView
    func updateVoice(conversationId: String, request: TTSPatch) async throws(AppError) -> TTSView
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> CatalogPage
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void
    func unpair() async throws(AppError) -> Void
}

extension AppError {
    static func map(_ error: any Error) -> AppError {
        if let error = error as? AppError { return error }
        if let error = error as? PairingFailure { return .pairing(error) }
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
        case .server(let status, let body): "http_\(status)_\(body.error)"
        case .transport(let failure): failure.rawValue
        case .keyUnavailable: "key_unavailable"
        case .notPaired: "not_paired"
        case .pairing: "pairing_failed"
        case .limit: "local_limit"
        case .callActive: "call_active"
        }
    }
    var message: String {
        switch self {
        case .pairing(let failure): failure.localizedDescription
        case .limit(let message): message
        case .callActive: "End the current call first."
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

extension AppError {
    /// A paired call's failure: the host's refusal in its own words, a response that does not decode as a bad grant,
    /// a locked key or a lost pairing in this app's words, and only a real transport failure as one.
    var callFailure: CallFailure {
        switch self {
        case let .server(status, body): .server(status: status, code: body.error, message: body.message)
        case .transport(.invalidResponse): .malformedGrant
        case .transport: .pairedTransport
        case .keyUnavailable, .notPaired, .pairing, .limit, .callActive: .local(code: logName, message: message)
        }
    }

    var voiceFailure: TTSServiceFailure {
        switch self {
        case let .server(status, body): .server(status: status, code: body.error, message: body.message)
        case .transport(.invalidResponse): .malformed
        case .transport: .pairedTransport
        case .keyUnavailable, .notPaired, .pairing, .limit, .callActive: .local(code: logName, message: message)
        }
    }
}

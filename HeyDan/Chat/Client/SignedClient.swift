import Foundation
import HeyDanCore
import Security
import Synchronization

final class SignedClient: AppService {
    let host: URL
    let deviceId: String?
    private let api: URLSession
    private let streamSession: URLSession
    private let uploadSession: URLSession
    private let clockOffset = Mutex<TimeInterval>(0)
    private let signer: @Sendable (Data, URL) throws -> Data
    #if DEBUG
    private static let launched = Date()
    #endif

    init(host: URL = URL(string: "https://app.opx.one")!, deviceId: String? = nil,
         configuration: URLSessionConfiguration = .ephemeral,
         signer: @escaping @Sendable (Data, URL) throws -> Data = { try DeviceKey().sign($0, host: $1) }) {
        #if DEBUG
        _ = Self.launched
        #endif
        self.host = host
        self.deviceId = deviceId
        self.signer = signer
        configuration.timeoutIntervalForRequest = 20
        api = URLSession(configuration: configuration, delegate: TransferDelegate(), delegateQueue: nil)
        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = 60
        streamSession = URLSession(configuration: stream, delegate: TransferDelegate(), delegateQueue: nil)
        let upload = configuration.copy() as! URLSessionConfiguration
        upload.timeoutIntervalForRequest = 60
        upload.timeoutIntervalForResource = 3600
        uploadSession = URLSession(configuration: upload, delegate: TransferDelegate(), delegateQueue: nil)
    }

    deinit {
        api.invalidateAndCancel()
        streamSession.invalidateAndCancel()
        uploadSession.invalidateAndCancel()
    }

    #if DEBUG
    func checkRevocationRequest() throws -> URLRequest { try makeRequest("GET", ["conversations"]) }
    #endif

    private func makeRequest(_ method: String, _ path: [String], query: [(String, String)] = [],
                             body: Data = Data(), signed: Bool = true) throws -> URLRequest {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["HEYDAN_OFFLINE_FOR"].flatMap(Double.init),
           Date().timeIntervalSince(Self.launched) < seconds { throw AppError.transport(.offline) }
        #endif
        let target = try RequestTarget.build(path: path, query: query)
        guard let url = URL(string: host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + target)
        else { throw AppError.transport(.invalidResponse) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if signed {
            guard let deviceId else { throw AppError.notPaired }
            let host = self.host
            let signBytes = signer
            let requestSigner = RequestSigner(offset: clockOffset.withLock { $0 }, nonce: {
                var nonce = Data(count: 16)
                let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
                guard status == errSecSuccess else { throw AppError.keyUnavailable }
                return nonce
            }, signer: { try signBytes($0, host) })
            let signedRequest = try requestSigner.sign(method: method, path: path, query: query,
                body: body, deviceId: deviceId)
            request.setValue(signedRequest.authorization.header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw AppError.transport(.invalidResponse) }
        guard (200..<300).contains(response.statusCode) else {
            guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
                throw AppError.transport([502, 503, 504].contains(response.statusCode) ? .unavailable : .invalidResponse)
            }
            throw AppError.server(status: response.statusCode, body: body)
        }
    }

    private func adjustClock(_ error: any Error, attempt: Int) -> Bool {
        guard attempt == 0, case AppError.server(401, let body) = error,
              body.error == "stale_timestamp", let time = body.serverTime else { return false }
        clockOffset.withLock { $0 = Double(time) / 1000 - Date().timeIntervalSince1970 }
        return true
    }

    private func routeTemplate(_ path: [String]) -> String {
        var template = path
        if path.count > 1, ["conversations", "questions", "files", "calls"].contains(path[0]) {
            if path[0] == "calls", path[1] == "attempts", path.count > 2 { template[2] = ":id" }
            else { template[1] = ":id" }
        }
        return "/app/" + template.joined(separator: "/")
    }

    private func data(_ method: String, _ path: [String], query: [(String, String)] = [],
                      body: Data = Data(), signed: Bool = true) async throws(AppError) -> Data {
        for attempt in 0...1 {
            let start = Date()
            var outcome = "cancelled"
            defer { CallLog.log(.net, "\(method) \(routeTemplate(path)) \(outcome) \(Int(Date().timeIntervalSince(start) * 1000))ms") }
            do {
                let request = try makeRequest(method, path, query: query, body: body, signed: signed)
                let (data, response) = try await api.data(for: request)
                outcome = "http_\((response as? HTTPURLResponse)?.statusCode ?? 0)"
                try validate(data, response)
                return data
            } catch {
                outcome = AppError.map(error).logName
                if signed && adjustClock(error, attempt: attempt) { continue }
                throw AppError.map(error)
            }
        }
        throw .transport(.invalidResponse)
    }
    private func json<T: Decodable>(_ method: String, _ path: [String], query: [(String, String)] = [],
                                    body: Data = Data(), signed: Bool = true) async throws(AppError) -> T {
        do { return try JSONDecoder().decode(T.self, from: await data(method, path, query: query, body: body, signed: signed)) }
        catch { throw AppError.map(error) }
    }
    private func encode<T: Encodable>(_ value: T) throws(AppError) -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw .transport(.invalidResponse) }
    }

    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> {
        for attempt in 0...1 {
            let start = Date()
            var outcome = "cancelled"
            defer { CallLog.log(.net, "GET /app/events \(outcome) \(Int(Date().timeIntervalSince(start) * 1000))ms") }
            do {
                var request = try makeRequest("GET", ["events"], query: [("after", String(query.after))])
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await streamSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw AppError.transport(.invalidResponse) }
                if !(200..<300).contains(http.statusCode) {
                    var body = Data()
                    for try await byte in bytes {
                        guard body.count < 1_048_576 else { throw AppError.transport(.invalidResponse) }
                        body.append(byte)
                    }
                    try validate(body, response)
                }
                outcome = "http_\(http.statusCode)"
                let lastByte = Mutex(ContinuousClock.now)
                let pair = AsyncThrowingStream<AppEvent, any Error>.makeStream()
                let reader = Task {
                    do {
                        var parser = SSEParser()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            lastByte.withLock { $0 = .now }
                            for event in try parser.feed(Data([byte])) { pair.continuation.yield(event) }
                        }
                        pair.continuation.finish()
                    } catch { pair.continuation.finish(throwing: AppError.map(error)) }
                }
                let watchdog = Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        if lastByte.withLock({ $0.duration(to: .now) }) >= .seconds(45) {
                            pair.continuation.finish(throwing: AppError.transport(.timeout))
                            reader.cancel()
                            return
                        }
                    }
                }
                pair.continuation.onTermination = { _ in reader.cancel(); watchdog.cancel() }
                return pair.stream
            } catch {
                outcome = AppError.map(error).logName
                if adjustClock(error, attempt: attempt) { continue }
                throw AppError.map(error)
            }
        }
        throw .transport(.invalidResponse)
    }

    func upload(fileId: String, ticket: String, bytes: Data,
                progress: (@Sendable (Double) -> Void)? = nil) async throws(AppError) {
        let start = Date()
        var outcome = "cancelled"
        defer { CallLog.log(.net, "PUT /app/files/:id \(outcome) \(Int(Date().timeIntervalSince(start) * 1000))ms") }
        do {
            var request = try makeRequest("PUT", ["files", fileId], signed: false)
            request.setValue("HeyDan-Ticket " + ticket, forHTTPHeaderField: "Authorization")
            request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            progress?(0)
            let (data, response) = try await uploadSession.upload(for: request, from: bytes,
                delegate: TransferDelegate(progress: progress))
            try validate(data, response)
            outcome = "http_\((response as? HTTPURLResponse)?.statusCode ?? 0)"
            progress?(1)
        } catch { outcome = AppError.map(error).logName; throw AppError.map(error) }
    }
    func hello() async throws(AppError) -> HelloResponse {
        return try await json("GET", ["hello"], signed: false)
    }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse {
        return try await json("POST", ["pair"], body: encode(request), signed: false)
    }
    func conversations() async throws(AppError) -> ConversationsResponse {
        return try await json("GET", ["conversations"])
    }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage {
        return try await json("GET", ["conversations", conversationId, "messages"], query: [("before", query.before.map(String.init)), ("after", query.after.map(String.init)), ("limit", query.limit.map(String.init))].compactMap { k, v in v.map { (k, $0) } })
    }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse {
        return try await json("POST", ["conversations", conversationId, "messages"], body: encode(request))
    }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse {
        return try await json("POST", ["conversations", conversationId, "read"], body: encode(request))
    }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse {
        return try await json("POST", ["questions", questionId, "answer"], body: encode(request))
    }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse {
        return try await json("POST", ["files"], body: encode(request))
    }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse {
        return try await json("POST", ["files", fileId, "ticket"])
    }
    func download(fileId: String) async throws(AppError) -> Data {
        return try await data("GET", ["files", fileId])
    }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant {
        return try await json("POST", ["calls"], body: encode(request))
    }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) -> Void {
        _ = try await data("POST", ["calls", callId, "end"], body: encode(request))
    }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) -> Void {
        _ = try await data("POST", ["calls", "attempts", attemptId, "cancel"], body: encode(request))
    }
    func voice(conversationId: String) async throws(AppError) -> VoiceView {
        return try await json("GET", ["conversations", conversationId, "voice"])
    }
    func updateVoice(conversationId: String, request: VoicePatchRequest) async throws(AppError) -> VoiceView {
        return try await json("PATCH", ["conversations", conversationId, "voice"], body: encode(request))
    }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> VoiceCatalog {
        return try await json("GET", ["conversations", conversationId, "voices"], query: [("provider", Optional(query.provider)), ("q", query.q), ("language", query.language), ("gender", query.gender), ("cursor", query.cursor), ("limit", query.limit.map(String.init))].compactMap { k, v in v.map { (k, $0) } })
    }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void {
        _ = try await data("PUT", ["devices", "me", "push-token"], body: encode(request))
    }
    func unpair() async throws(AppError) -> Void {
        _ = try await data("DELETE", ["devices", "me"])
    }
}

private final class TransferDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: (@Sendable (Double) -> Void)?
    init(progress: (@Sendable (Double) -> Void)? = nil) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

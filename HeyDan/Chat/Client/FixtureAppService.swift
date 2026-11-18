#if DEBUG
import CoreGraphics
import Foundation
import HeyDanCore

actor FixtureAppService: AppService {
    static let pairing = PairResponse(deviceId: "dev_fixture", userName: "Taylor tester",
        agents: [Agent(id: "ag_taylor", name: "Taylor")], protocol: 1, serverTime: 0)
    init() {
        if ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CALL_REFUSAL"] == "1" {
            conversation.canCall = false
            conversation.callRefusal = ErrorBody(error: "voice_offline", message: "Voice is offline.")
        }
    }
    private var fileMetadata: [String: FileAttachment] = [:]
    private var uploaded: [String: Data] = [:]
    private var sequence: Int64 = 10
    private var listeners: [UUID: AsyncThrowingStream<AppEvent, any Error>.Continuation] = [:]
    private var conversation = Conversation(kind: .conversation, id: "conv_taylor01", seq: 1,
        agent: Agent(id: "ag_taylor", name: "Taylor"), unread: 2, readOrder: 0, canCall: true, createdAt: 0)
    private var question = Question(kind: .question, id: "q_0123", conversationId: "conv_taylor01",
        order: 4, seq: 4, title: "Choose an option", text: "Which option do you prefer?",
        options: [QuestionOption(label: "Continue", selectedLabel: "Continued", value: "continue", style: "primary")],
        state: .open, createdAt: 0)
    private var messages: [Message] = [
        Message(kind: .message, id: "msg_2101", conversationId: "conv_taylor01", order: 2, seq: 2,
            role: .agent, text: "## Hello\n\nThis is **Taylor**.\n\n- One\n- Two\n\n```swift\nprint(42)\n```",
            files: [], reactions: [], createdAt: 0),
        Message(kind: .message, id: "msg_2102", conversationId: "conv_taylor01", order: 3, seq: 3,
            role: .agent, text: "Attachments", files: [
                FileAttachment(id: "file_img01", name: "Image.png", mimeType: "image/png", size: 68,
                    kind: .image, width: 1, height: 1),
                FileAttachment(id: "file_doc01", name: "Document.pdf", mimeType: "application/pdf", size: 0, kind: .file)
            ], reactions: [], createdAt: 0)
    ]
    private var status: Status { Status(kind: .status, conversationId: conversation.id, rev: 1, state: .working, label: "Working", at: 0) }
    private var badge: Badge { Badge(kind: .badge, rev: conversation.seq, unreadTotal: conversation.unread) }
    private func event<T: Encodable>(_ kind: Kind, _ value: T, id: Int64? = nil) throws(AppError) -> AppEvent {
        do { return AppEvent(kind: kind, id: id, data: try JSONEncoder().encode(value)) }
        catch { throw .transport(.invalidResponse) }
    }
    private func publish(_ event: AppEvent) {
        for listener in listeners.values { listener.yield(event) }
    }
    func hello() async throws(AppError) -> HelloResponse {
        HelloResponse(protocol: 1, minProtocol: 1, voiceProtocol: 6,
            features: ["files", "calls", "push", "voice-picker"], serverTime: 0)
    }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse { Self.pairing }
    func conversations() async throws(AppError) -> ConversationsResponse {
        ConversationsResponse(conversations: [conversation], statuses: [status], badge: badge, seq: sequence)
    }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage {
        var items = messages.filter { (query.before == nil || $0.order < query.before!) && (query.after == nil || $0.order > query.after!) }.map(ThreadEntity.message)
        if (query.before == nil || question.order < query.before!) && (query.after == nil || question.order > query.after!) { items.append(.question(question)) }
        return HistoryPage(items: items, hasMoreBefore: false, hasMoreAfter: false)
    }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse {
        if let existing = messages.first(where: { $0.clientId == request.clientId }) { return SendResponse(message: existing) }
        sequence += 1
        let stored = Message(kind: .message, id: "msg_" + request.clientId, conversationId: conversationId,
            order: sequence, seq: sequence, role: .user, text: request.text, files: request.fileIds.compactMap { fileMetadata[$0] }, reactions: [],
            clientId: request.clientId, delivery: .stored, createdAt: 0)
        messages.append(stored)
        try publish(event(.message, stored, id: sequence))
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            try? self.complete(stored)
        }
        return SendResponse(message: stored)
    }
    private func complete(_ stored: Message) throws(AppError) {
        sequence += 1
        var reached = stored
        reached.seq = sequence
        reached.delivery = .reached
        if let index = messages.firstIndex(where: { $0.id == reached.id }) { messages[index] = reached }
        try publish(event(.message, reached, id: sequence))
        sequence += 1
        let reply = Message(kind: .message, id: "msg_reply_" + stored.id, conversationId: stored.conversationId,
            order: sequence, seq: sequence, role: .agent, text: "Received.", files: [], reactions: [], createdAt: 0)
        messages.append(reply)
        try publish(event(.message, reply, id: sequence))
    }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse {
        sequence += 1
        conversation.seq = sequence
        conversation.readOrder = max(conversation.readOrder, request.order)
        conversation.unread = 0
        try publish(event(.conversation, conversation, id: sequence))
        try publish(event(.badge, badge))
        return ReadResponse(conversation: conversation, badge: badge)
    }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse {
        sequence += 1
        question.seq = sequence
        question.state = .answered
        question.answer = QuestionAnswer(value: request.value, label: "Continued", at: 0)
        try publish(event(.question, question, id: sequence))
        return AnswerResponse(question: question)
    }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> {
        let pair = AsyncThrowingStream<AppEvent, any Error>.makeStream()
        let id = UUID()
        var snapshot = [try event(.conversation, conversation, id: conversation.seq),
                        try event(.question, question, id: question.seq)]
        for message in messages { snapshot.append(try event(.message, message, id: message.seq)) }
        for item in snapshot.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) where (item.id ?? 0) > query.after {
            pair.continuation.yield(item)
        }
        pair.continuation.yield(try event(.status, status))
        pair.continuation.yield(try event(.badge, badge))
        pair.continuation.yield(try event(.synchronized, Synchronized(seq: sequence)))
        listeners[id] = pair.continuation
        pair.continuation.onTermination = { _ in Task { await self.removeListener(id) } }
        return pair.stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse {
        let id = "file_" + request.uploadKey
        fileMetadata[id] = FileAttachment(id: id, name: request.name, mimeType: request.mimeType,
            size: request.size, kind: request.mimeType.hasPrefix("image/") ? .image : .file)
        return FileInitResponse(fileId: id, ticket: "fixture", expiresAt: Int64.max,
            uploadPath: "/app/files/" + id, uploaded: uploaded[id] != nil)
    }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse {
        FileTicketRenewResponse(fileId: fileId, ticket: "fixture", expiresAt: Int64.max,
            uploadPath: "/app/files/" + fileId, uploaded: false)
    }
    func upload(fileId: String, ticket: String, bytes: Data) async throws(AppError) { uploaded[fileId] = bytes }
    func download(fileId: String) async throws(AppError) -> Data {
        if let bytes = uploaded[fileId] { return bytes }
        if fileId == "file_doc01" {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw .transport(.invalidResponse) }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
        return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant { throw .server(status: 503, body: ErrorBody(error: "voice_offline", message: "Calls are unavailable in this preview.")) }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) {}
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) {}
    func voice(conversationId: String) async throws(AppError) -> TTSView { throw .server(status: 503, body: ErrorBody(error: "voice_offline", message: "Voice settings are unavailable in this preview.")) }
    func updateVoice(conversationId: String, request: TTSPatch) async throws(AppError) -> TTSView { try await voice(conversationId: conversationId) }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> CatalogPage { CatalogPage(provider: query.provider, voices: []) }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) {}
    func unpair() async throws(AppError) {}
}
#endif

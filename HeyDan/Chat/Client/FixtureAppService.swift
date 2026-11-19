#if DEBUG
import UIKit
import Foundation
import HeyDanCore

actor FixtureAppService: AppService {
    static let host = FixtureContent.capturing ? FixtureContent.host : URL(string: "https://app.example.com")!
    static let secondAgent = Agent(id: "ag_second", name: "Alex")
    static let hasSecondAgent = ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_LIVE_CALL"] == "1" && !FixtureContent.capturing
    static let pairing = PairResponse(deviceId: "dev_fixture", userName: FixtureContent.capturing ? "iPhone 17 Pro" : "Taylor tester",
        agents: FixtureContent.capturing ? FixtureContent.agents : [Agent(id: "ag_taylor", name: "Taylor")] + (hasSecondAgent ? [secondAgent] : []),
        protocol: 1, serverTime: 0)
    let previewOutbox: [Outbox.Entry]
    private let scenario: String?

    init(scenario: String? = ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_THREAD"]) {
        self.scenario = scenario
        let preview = ThreadPreviewValues.self
        if scenario == "message-menus" {
            previewOutbox = [Outbox.State.queued, .failed].map { state in
                Outbox.Entry(host: Self.host, conversationId: "conv_taylor01",
                    request: SendRequest(clientId: state == .queued ? "queued" : "failed", text: "Example", fileIds: []), state: state)
            }
        } else if scenario == "outbox" {
            previewOutbox = [Outbox.State.queued, .waiting, .held].map { state in
                Outbox.Entry(host: Self.host, conversationId: "conv_taylor01",
                    request: SendRequest(clientId: UUID().uuidString, text: "Please check the report.", fileIds: []),
                    state: state)
            }
        } else { previewOutbox = [] }
        switch scenario {
        case "message-menus":
            messages = [Message(kind: .message, id: "msg_5", conversationId: "conv_taylor01", order: 6, seq: 6,
                role: .user, text: "Example", files: [], reactions: [], delivery: .reached, createdAt: 0)]
        case "outbox":
            messages = [Delivery.stored, .routed].enumerated().map { offset, delivery in
                let order = Int64(5 + offset)
                return Message(kind: .message, id: "msg_\(order)", conversationId: "conv_taylor01",
                    order: order, seq: order, role: .user, text: "Here is the update.", files: [],
                    reactions: [], delivery: delivery, createdAt: 0)
            }
        case "messages":
            messages = [preview.editSequence2, preview.voiceCaller0, preview.voiceSpoken0, preview.host0]
            question = preview.questionexpired
        case "delivery":
            messages = [preview.userWithFile0, preview.userUnknown0, preview.userFailed0]
            question = preview.questionanswered
        default: break
        }
        sequence = max(sequence, question.seq, messages.map(\.seq).max() ?? 0)
        if scenario == "table" || ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CARD"] == "table",
           let index = messages.firstIndex(where: { $0.id == "msg_card" }) {
            messages[index].text = "Last 6 runs. The backup failed on 11-17."
            messages[index].card = Card(title: "Last 6 runs", description: "Nightly backup job on home server.", parts: [
                .table(headers: ["Night", "Status", "Size", "Time", "Files"], rows: [
                    ["11-18", "Green", "1.2 TB", "48 min", "812k"],
                    ["11-17", "Failed", "-", "-", "-"],
                    ["11-16", "Green", "1.2 TB", "49 min", "810k"],
                    ["11-15", "Green", "1.2 TB", "47 min", "809k"]
                ], align: nil, caption: nil),
                .chart(title: "Duration, minutes", chart: .plot(.bar, categories: ["13", "14", "15", "16", "17", "18"],
                    series: [.init(name: "Minutes", values: [39, 34, 45, 56, 0, 48])])),
                .text(content: "11-17 failed: the storage key had expired.", style: "muted")
            ], actions: [])
        }
        if FixtureContent.capturing, let card = messages.first(where: { $0.id == "msg_card" }) {
            conversation = FixtureContent.conversation
            messages = FixtureContent.messages(scenario, card: card)
            question = FixtureContent.question
        }
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
        order: 5, seq: 5, title: "Choose an option", text: "Which option do you prefer?",
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
            ], reactions: [], createdAt: 0),
        Message(kind: .message, id: "msg_card", conversationId: "conv_taylor01", order: 4, seq: 4,
            role: .agent, text: "Backup report: Green, 1.2 TB, 48 min.",
            card: Card(title: "Backup report", description: "Last night's run, after the storage key rotation.",
                parts: [.fields([
                    .init(label: "Status", value: "Green"), .init(label: "Size", value: "1.2 TB"),
                    .init(label: "Duration", value: "48 min"), .init(label: "Snapshot", value: "02:00"),
                    .init(label: "Files", value: "812k"), .init(label: "Next run", value: "01:30")
                ])], actions: [.init(label: "Open report", url: "https://example.org/report", style: "primary")]),
            files: [], reactions: [], createdAt: 0)
    ]
    private var status: Status {
        if scenario == "messages" { return ThreadPreviewValues.statuswaiting }
        return Status(kind: .status, conversationId: conversation.id, rev: 1, state: .working, label: "Working", at: 0)
    }
    private var includesQuestion: Bool { !FixtureContent.capturing || scenario == "question" || scenario == "full" }
    private var badge: Badge { Badge(kind: .badge, rev: conversation.seq, unreadTotal: conversation.hidden == true ? 0 : conversation.unread) }
    private func event<T: Encodable>(_ kind: Kind, _ value: T, id: Int64? = nil) throws(AppError) -> AppEvent {
        do { return AppEvent(kind: kind, id: id, data: try JSONEncoder().encode(value)) }
        catch { throw .transport(.invalidResponse) }
    }
    private func publish(_ event: AppEvent) {
        for listener in listeners.values { listener.yield(event) }
    }
    func hello() async throws(AppError) -> HelloResponse {
        HelloResponse(protocol: 1, minProtocol: 1, voiceProtocol: 6,
            features: scenario == "text-only" ? [] : ["files", "calls", "push", "voice-picker", "agents", "unread", "voice-messages"], serverTime: 0)
    }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse { Self.pairing }
    private var candidate: AgentCandidate {
        AgentCandidate(id: conversation.agent.id, name: conversation.agent.name, chat: "Team", shown: conversation.hidden != true)
    }
    func agents() async throws(AppError) -> AgentsResponse { AgentsResponse(agents: [candidate]) }
    func setAgent(id: String, request: AgentVisibilityRequest) async throws(AppError) -> AgentResponse {
        guard id == candidate.id else { throw .server(status: 404, body: ErrorBody(error: "not_found", message: "Agent unavailable.")) }
        if request.shown != candidate.shown {
            sequence += 1
            conversation.seq = sequence
            conversation.hidden = !request.shown
            try publish(event(.conversation, conversation, id: sequence))
            if request.shown { try publish(event(.status, status)) }
            try publish(event(.badge, badge))
        }
        return AgentResponse(agent: candidate)
    }
    func conversations() async throws(AppError) -> ConversationsResponse {
        var conversations = candidate.shown ? [conversation] : []
        if Self.hasSecondAgent {
            conversations.append(Conversation(kind: .conversation, id: "conv_second", seq: 1,
                agent: Self.secondAgent, unread: 0, readOrder: 0, canCall: true, createdAt: 0))
        }
        return ConversationsResponse(conversations: conversations, statuses: candidate.shown ? [status] : [], badge: badge, seq: sequence)
    }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage {
        var items = messages.filter { (query.before == nil || $0.order < query.before!) && (query.after == nil || $0.order > query.after!) }.map(ThreadEntity.message)
        if includesQuestion && (query.before == nil || question.order < query.before!) && (query.after == nil || question.order > query.after!) { items.append(.question(question)) }
        if scenario == "history", query.before != nil { try? await Task.sleep(for: .seconds(15)) }
        return HistoryPage(items: items, hasMoreBefore: scenario == "history" && query.before == nil, hasMoreAfter: false)
    }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse {
        if let existing = messages.first(where: { $0.clientId == request.clientId }) { return SendResponse(message: existing) }
        sequence += 1
        let stored = Message(kind: .message, id: "msg_" + request.clientId, conversationId: conversationId,
            order: sequence, seq: sequence, role: .user, text: request.text, files: request.fileIds.compactMap { fileMetadata[$0] }, reactions: [],
            clientId: request.clientId, delivery: .stored, createdAt: 0)
        messages.append(stored)
        try publish(event(.message, stored, id: sequence))
        let voice = stored.files.contains { $0.kind == .audio }
        if voice { try publishPreview(stored, text: "Voice message") }
        Task {
            try? await Task.sleep(for: voice ? .seconds(3) : .milliseconds(150))
            try? self.complete(stored)
        }
        return SendResponse(message: stored)
    }
    private func publishPreview(_ message: Message, text: String) throws(AppError) {
        sequence += 1
        conversation.seq = sequence
        conversation.lastMessage = LastMessage(id: message.id, role: message.role, preview: text, at: message.createdAt)
        try publish(event(.conversation, conversation, id: sequence))
    }

    private func complete(_ stored: Message) throws(AppError) {
        sequence += 1
        var reached = stored
        reached.seq = sequence
        reached.delivery = .reached
        if let index = reached.files.firstIndex(where: { $0.kind == .audio }) {
            reached.files[index].transcript = .init(state: .done, text: "Recorded fixture message.")
        }
        if let index = messages.firstIndex(where: { $0.id == reached.id }) { messages[index] = reached }
        try publish(event(.message, reached, id: sequence))
        if let preview = reached.files.first(where: { $0.kind == .audio })?.transcript?.text, conversation.lastMessage?.id == reached.id {
            try publishPreview(reached, text: preview)
        }
        sequence += 1
        let reply = Message(kind: .message, id: "msg_reply_" + stored.id, conversationId: stored.conversationId,
            order: sequence, seq: sequence, role: .agent, text: "Received.", files: [], reactions: [], createdAt: 0)
        messages.append(reply)
        try publish(event(.message, reply, id: sequence))
    }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse {
        conversation.readOrder = max(conversation.readOrder, request.order)
        conversation.unread = 0
        return try publishReadState()
    }
    func markUnread(conversationId: String) async throws(AppError) -> ReadResponse {
        let newest = messages.filter { $0.role == .agent }.map(\.order).max()
        guard let order = [newest, includesQuestion ? question.order : nil].compactMap({ $0 }).max() else {
            throw .server(status: 409, body: ErrorBody(error: "nothing_unread", message: "There is nothing to mark unread."))
        }
        conversation.readOrder = order - 1
        conversation.unread = 1
        return try publishReadState()
    }
    private func publishReadState() throws(AppError) -> ReadResponse {
        sequence += 1
        conversation.seq = sequence
        try publish(event(.conversation, conversation, id: sequence))
        try publish(event(.badge, badge))
        return ReadResponse(conversation: conversation, badge: badge)
    }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse {
        sequence += 1
        if scenario == "answer-error" {
            throw .server(status: 502, body: ErrorBody(error: "answer_not_delivered",
                message: "The answer did not reach the agent. Try again."))
        }
        question.seq = sequence
        question.state = .answered
        question.answer = QuestionAnswer(value: request.value, label: "Continued", at: 0)
        try publish(event(.question, question, id: sequence))
        return AnswerResponse(question: question)
    }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> {
        let pair = AsyncThrowingStream<AppEvent, any Error>.makeStream()
        let id = UUID()
        var snapshot = [try event(.conversation, conversation, id: conversation.seq)]
        if candidate.shown && includesQuestion { snapshot.append(try event(.question, question, id: question.seq)) }
        for message in messages where candidate.shown { snapshot.append(try event(.message, message, id: message.seq)) }
        for item in snapshot.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) where (item.id ?? 0) > query.after {
            pair.continuation.yield(item)
        }
        if candidate.shown { pair.continuation.yield(try event(.status, status)) }
        pair.continuation.yield(try event(.badge, badge))
        pair.continuation.yield(try event(.synchronized, Synchronized(seq: sequence)))
        listeners[id] = pair.continuation
        pair.continuation.onTermination = { _ in Task { await self.removeListener(id) } }
        return pair.stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse {
        let id = "file_" + request.uploadKey
        let audio = request.mimeType == "audio/mp4" || request.mimeType == "audio/x-m4a"
        fileMetadata[id] = FileAttachment(id: id, name: request.name, mimeType: request.mimeType,
            size: request.size, kind: audio ? .audio : (request.mimeType.hasPrefix("image/") ? .image : .file),
            durationMs: request.durationMs, transcript: audio ? .init(state: .pending) : nil)
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
        if FixtureContent.capturing, fileId == "file_img01",
           let path = ProcessInfo.processInfo.environment["HEYDAN_CAPTURE_PHOTO"],
           let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) { return bytes }
        if FixtureContent.capturing, fileId == "file_backup" {
            return Data(String(repeating: "backup-job: snapshot completed.\n", count: 1536).utf8)
        }
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
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant {
        var reason = "Calls are unavailable in this preview."
        if scenario == "control-admission" {
            let background = await MainActor.run { UIApplication.shared.applicationState == .background }
            reason = background ? "CallKit admitted the background call." : "CallKit admitted the foreground call."
        }
        throw .server(status: 503, body: ErrorBody(error: "voice_offline", message: reason))
    }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) {}
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) {}
    func voice(conversationId: String) async throws(AppError) -> TTSView {
        if FixtureContent.capturing { return FixtureContent.voice }
        throw .server(status: 503, body: ErrorBody(error: "voice_offline", message: "Voice settings are unavailable in this preview."))
    }
    func updateVoice(conversationId: String, request: TTSPatch) async throws(AppError) -> TTSView { try await voice(conversationId: conversationId) }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> CatalogPage { CatalogPage(provider: query.provider, voices: FixtureContent.capturing ? FixtureContent.voices : []) }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) {}
    func unpair() async throws(AppError) {}
}
#endif

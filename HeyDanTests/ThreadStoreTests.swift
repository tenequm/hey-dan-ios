import Foundation
import HeyDanCore
import Testing
@testable import HeyDan

struct ThreadStoreTests {
    private let host = URL(string: "https://app.example.com")!

    private func conversation(seq: Int64, unread: Int = 2) -> Conversation {
        Conversation(kind: .conversation, id: "conv_taylor01", seq: seq,
            agent: Agent(id: "ag_taylor", name: "Taylor"), unread: unread,
            readOrder: 0, canCall: false, createdAt: 0)
    }

    @Test func cursorAndEntitiesSurviveIncrementalSaves() async throws {
        let store = SwiftDataThreadStore(inMemory: true)
        try await store.save(ThreadSnapshot(cursor: 10, conversations: [conversation(seq: 10)]), host: host, deviceId: "device")
        try await store.save(ThreadSnapshot(cursor: 12), host: host, deviceId: "device")
        try await store.save(ThreadSnapshot(cursor: 8, conversations: [conversation(seq: 8, unread: 0)]), host: host, deviceId: "device")
        let snapshot = try await store.load(host: host, deviceId: "device")
        #expect(snapshot.cursor == 12)
        #expect(snapshot.conversations == [conversation(seq: 10)])
        #expect(try await store.load(host: host, deviceId: "other").conversations.isEmpty)
        try await store.save(ThreadSnapshot(cursor: 30, conversations: [conversation(seq: 30)]), host: host, deviceId: "other")
        try await store.clear(host: host, deviceId: "other")
        #expect(try await store.load(host: host, deviceId: "other").conversations.isEmpty)
        #expect(try await store.load(host: host, deviceId: "device").cursor == 12)
    }

    @Test func schemaWipePreservesOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = OutboxFile(root: root)
        let entry = Outbox.Entry(host: host, conversationId: "conv_taylor01",
            request: SendRequest(clientId: UUID().uuidString, text: "test", fileIds: []))
        try await outbox.save([entry], host: host, deviceId: "device")
        try await populate(root: root)
        let reopened = try await SwiftDataThreadStore(root: root, schemaVersion: 1).load(host: host, deviceId: "device")
        #expect(reopened.cursor == 10)
        #expect(reopened.conversations == [conversation(seq: 10)])
        let store = SwiftDataThreadStore(root: root, schemaVersion: 2)
        let snapshot = try await store.load(host: host, deviceId: "device")
        #expect(snapshot.cursor == 0)
        #expect(snapshot.conversations.isEmpty)
        #expect(try await outbox.load(host: host, deviceId: "device") == [entry])
    }

    @MainActor @Test func offlineEnqueueReconnectAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryThreadStore()
        let files = OutboxFile(root: root)
        let service = FixtureAppService()
        let chat = ChatController(service: service, store: store, files: files, monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        await chat.loadHistory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        try Data("attachment".utf8).write(to: source)
        await chat.send(text: "test", attachments: [StagedAttachment(fileURL: source, name: "test.txt", mimeType: "text/plain")])
        #expect(chat.outbox.entries.count == 1)
        #expect(chat.outbox.entries.first?.state == .queued)
        #expect(try await files.load(host: host, deviceId: "dev_fixture").count == 1)
        let clientId = try #require(chat.outbox.entries.first?.request.clientId)
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.isEmpty }
        let messages = chat.thread.compactMap { entity -> Message? in
            if case .message(let message) = entity, message.clientId == clientId { return message }; return nil
        }
        #expect(messages.count == 1)
        #expect(chat.uploadProgress.values.contains(1))
        chat.setActive(false)
        let cursor = chat.reducer.cursor
        let restored = ChatController(service: service, store: store, files: files, monitorsNetwork: false)
        restored.setActive(false)
        restored.selectPairing(FixtureAppService.pairing, host: host)
        await restored.loadTask?.value
        #expect(restored.reducer.cursor == cursor)
        #expect(restored.conversations.first?.unread == 2)
        #expect(restored.outbox.entries.isEmpty)
        restored.openConversation("conv_taylor01")
        restored.setActive(true)
        try await waitUntil { restored.connectionState == .connected }
        #expect(restored.thread.filter { if case .message(let m) = $0 { return m.clientId == clientId }; return false }.count == 1)
        restored.setActive(false)
    }

    @MainActor @Test func readAndAnswerKeepServerState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatController(service: FixtureAppService(), store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        await chat.loadHistory()
        await chat.answer(questionId: "q_0123", value: "continue")
        #expect(chat.thread.contains { if case .question(let q) = $0 { return q.state == .answered }; return false })
        await chat.markRead(order: 2)
        await chat.markRead(order: 4)
        await chat.readTask?.value
        #expect(chat.conversations.first?.readOrder == 4)
        #expect(chat.badge?.unreadTotal == 0)
        #expect(chat.reducer.cursor == 10)
    }

    @MainActor @Test func failingSendPreservesOrderAndResumesCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.fail("send", with: [.transport(.timeout)])
        let store = MemoryThreadStore()
        try await store.save(ThreadSnapshot(cursor: 7), host: host, deviceId: "dev_fixture")
        let chat = ChatController(service: service, store: store, files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.openConversation("conv_taylor01")
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        #expect(chat.openConversationId == "conv_taylor01")
        #expect(await chat.send(text: "first"))
        #expect(await chat.send(text: "second"))
        let ids = chat.outbox.entries.map { $0.request.clientId }
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.isEmpty }
        #expect(await service.sentIDs == [ids[0], ids[0], ids[1]])
        #expect(await service.cursors.first == 7)
        chat.setActive(false)
    }

    @MainActor @Test func failedBootstrapDoesNotOpenStreamAndPauseErrorsStop() async throws {
        for failure in [AppError.keyUnavailable, .server(status: 426, body: ErrorBody(error: "protocol", message: "Upgrade"))] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let service = ScriptedAppService()
            await service.fail("conversations", with: [failure])
            let chat = ChatController(service: service, store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
            chat.selectPairing(FixtureAppService.pairing, host: host)
            await chat.loadTask?.value
            try await waitUntil { chat.paused }
            #expect(await service.cursors.isEmpty)
            #expect(!chat.hasCursor)
            #expect(chat.pairing != nil)
            chat.setActive(false)
        }
    }

    @MainActor @Test func lostFileResponsesReuseIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "file.txt")
        try Data("file".utf8).write(to: source)
        let service = ScriptedAppService()
        await service.fail("initializeFileAfter", with: [.transport(.timeout)])
        await service.fail("uploadAfter", with: [.transport(.timeout)])
        let chat = ChatController(service: service, store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        chat.openConversation("conv_taylor01")
        #expect(await chat.send(text: "file", attachments: [StagedAttachment(fileURL: source, name: "file.txt", mimeType: "text/plain")]))
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.isEmpty }
        #expect(await service.mintKeys.count == 2)
        #expect(await Set(service.mintKeys).count == 1)
        #expect(await service.sentIDs.count == 1)
        chat.setActive(false)
    }

    @MainActor @Test func closeFlushesReadAndOversizedDraftIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatController(service: ScriptedAppService(), store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        #expect(await !chat.send(text: String(repeating: "a", count: Outbox.maximumTextBytes + 1)))
        #expect(chat.outbox.entries.isEmpty)
        await chat.markRead(order: 4)
        chat.closeConversation()
        await chat.readFlushTask?.value
        #expect(chat.conversations.first?.readOrder == 4)
    }

    @Test func failedTransactionRollsBackEntitiesAndCursor() async throws {
        let store = SwiftDataThreadStore(inMemory: true, beforeCommit: { snapshot in
            if snapshot.cursor == 99 { throw AppError.transport(.unavailable) }
        })
        try await store.save(ThreadSnapshot(cursor: 10, conversations: [conversation(seq: 10)]), host: host, deviceId: "device")
        await #expect(throws: (any Error).self) {
            try await store.save(ThreadSnapshot(cursor: 99, conversations: [conversation(seq: 99)]), host: host, deviceId: "device")
        }
        let snapshot = try await store.load(host: host, deviceId: "device")
        #expect(snapshot.cursor == 10)
        #expect(snapshot.conversations == [conversation(seq: 10)])
    }

    @MainActor @Test func answerErrorsAndExplicitRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let chat = ChatController(service: service, store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        chat.openConversation("conv_taylor01")
        await chat.loadHistory()
        await service.fail("answer", with: [.server(status: 502, body: ErrorBody(error: "answer_not_delivered", message: "Try again"))])
        await chat.answer(questionId: "q_0123", value: "continue")
        #expect(chat.thread.contains { if case .question(let q) = $0 { return q.state == .open }; return false })
        var q = try #require(chat.thread.compactMap { if case .question(let q) = $0 { return q }; return nil }.first)
        q.seq += 1; q.state = .answered
        await service.fail("answer", with: [.server(status: 409, body: ErrorBody(error: "not_open", message: "Answered", question: q))])
        await chat.answer(questionId: q.id, value: "continue")
        #expect(chat.thread.contains { if case .question(let q) = $0 { return q.state == .answered }; return false })
        let old = Outbox.Entry(host: host, conversationId: "conv_taylor01", request: SendRequest(clientId: "old", text: "retry", fileIds: []), state: .outcomeUnknown)
        chat.outbox.enqueue(old)
        try await chat.saveOutbox()
        await chat.retry(clientId: "old")
        #expect(chat.outbox.entries.count == 1)
        #expect(chat.outbox.entries.first?.request.clientId != "old")
        await chat.discard(clientId: try #require(chat.outbox.entries.first?.request.clientId))
        #expect(chat.outbox.entries.isEmpty)
    }

    @MainActor @Test func malformedEventAdvancesAndCancelledReplayResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([AppEvent(kind: .message, id: 11, data: Data("{}".utf8)),
            AppEvent(kind: .synchronized, id: nil, data: try JSONEncoder().encode(Synchronized(seq: 12)))])
        let store = MemoryThreadStore()
        let chat = ChatController(service: service, store: store, files: OutboxFile(root: root), monitorsNetwork: false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        try await waitUntil { chat.connectionState == .connected }
        #expect(chat.reducer.cursor == 12)
        chat.setActive(false)
        chat.setActive(true)
        try await waitUntil { chat.connectionState == .connected }
        #expect(await service.cursors == [10, 12])
        chat.setActive(false)
        let snapshot = await store.load(host: host, deviceId: "dev_fixture")
        #expect(snapshot.cursor == 12)
    }

    @MainActor @Test func revocationClearsCacheAndOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.fail("hello", with: [.server(status: 401, body: ErrorBody(error: "device_revoked", message: "Revoked"))])
        let store = MemoryThreadStore(), files = OutboxFile(root: root)
        let chat = ChatController(service: service, store: store, files: files, monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        #expect(await chat.send(text: "pending"))
        chat.setActive(true)
        try await waitUntil { chat.pairing == nil }
        await chat.streamTask?.value
        #expect(await store.load(host: host, deviceId: "dev_fixture").conversations.isEmpty)
        #expect(try await files.load(host: host, deviceId: "dev_fixture").isEmpty)
        chat.setActive(false)
    }

    @MainActor @Test func historyFloorExcludesOldEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let chat = ChatController(service: service, store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        chat.openConversation("conv_taylor01")
        await chat.loadHistory()
        let old = Message(kind: .message, id: "old", conversationId: "conv_taylor01", order: 1, seq: 100,
            role: .agent, text: "edit", files: [], reactions: [], createdAt: 0)
        chat.reducer.upsert(.message(old))
        #expect(!chat.thread.contains(.message(old)))
        await service.pages([HistoryPage(items: [.message(old)], hasMoreBefore: false, hasMoreAfter: false)])
        await chat.loadHistory()
        #expect(await service.beforeOrders.last! == 2)
        #expect(chat.thread.contains(.message(old)))
    }

    @Test func corruptOutboxIsQuarantinedAndDownloadsKeepNames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OutboxFile(root: root)
        let directory = await files.directory(host: host, deviceId: "device")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appending(path: "entries.json"))
        #expect(try await files.load(host: host, deviceId: "device").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("entries-invalid-") })
        let cached = try await files.cache(Data("file".utf8), fileId: "file", name: "../Report.pdf", host: host, deviceId: "device")
        #expect(cached.lastPathComponent == "Report.pdf")
        #expect(cached.deletingLastPathComponent().lastPathComponent == StoreLocation.digest("file"))
    }

    @MainActor @Test func lostSendResponseRetriesSameIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([])
        await service.fail("sendAfter", with: [.transport(.timeout)])
        let chat = ChatController(service: service, store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.setActive(false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        chat.openConversation("conv_taylor01")
        #expect(await chat.send(text: "lost response"))
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.isEmpty }
        #expect(await service.sentIDs.count == 2)
        #expect(await Set(service.sentIDs).count == 1)
        chat.setActive(false)
    }

    @MainActor @Test func cancelBeforeSynchronizedResumesCommittedCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([AppEvent(kind: .unknown("future"), id: 11, data: Data("{}".utf8))])
        let chat = ChatController(service: service, store: MemoryThreadStore(), files: OutboxFile(root: root), monitorsNetwork: false)
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        try await waitUntil { chat.reducer.cursor == 11 }
        #expect(chat.connectionState == .connecting)
        chat.setActive(false)
        await service.events([AppEvent(kind: .synchronized, id: nil, data: try JSONEncoder().encode(Synchronized(seq: 12)))])
        chat.setActive(true)
        try await waitUntil { chat.connectionState == .connected }
        #expect(await service.cursors == [10, 11])
        chat.setActive(false)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    private func populate(root: URL) async throws {
        let store = SwiftDataThreadStore(root: root, schemaVersion: 1)
        try await store.save(ThreadSnapshot(cursor: 10, conversations: [conversation(seq: 10)]), host: host, deviceId: "device")
    }
}

private actor ScriptedAppService: AppService {
    let base = FixtureAppService()
    var failures: [String: [AppError]] = [:]
    var sentIDs: [String] = []
    var cursors: [Int64] = []
    var mintKeys: [String] = []
    var scriptedEvents: [AppEvent]?
    var scriptedPages: [HistoryPage] = []
    var beforeOrders: [Int64?] = []
    func events(_ events: [AppEvent]) { scriptedEvents = events }
    func pages(_ pages: [HistoryPage]) { scriptedPages = pages }
    func fail(_ method: String, with errors: [AppError]) { failures[method] = errors }
    func check(_ method: String) throws(AppError) {
        if var queue = failures[method], !queue.isEmpty {
            let error = queue.removeFirst()
            failures[method] = queue
            throw error
        }
    }
    func hello() async throws(AppError) -> HelloResponse { try check("hello"); return try await base.hello() }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse { try check("pair"); return try await base.pair(request) }
    func conversations() async throws(AppError) -> ConversationsResponse { try check("conversations"); return try await base.conversations() }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage { beforeOrders.append(query.before)
        try check("history")
        if !scriptedPages.isEmpty { return scriptedPages.removeFirst() }
        return try await base.history(conversationId: conversationId, query: query) }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse { sentIDs.append(request.clientId); try check("send"); let result = try await base.send(conversationId: conversationId, request: request); try check("sendAfter"); return result }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse { try check("markRead"); return try await base.markRead(conversationId: conversationId, request: request) }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse { try check("answer"); return try await base.answer(questionId: questionId, request: request) }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> { cursors.append(query.after); try check("events")
        if let scriptedEvents {
            return AsyncThrowingStream { continuation in
                for event in scriptedEvents { continuation.yield(event) }
            }
        }
        return try await base.events(query: query) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse { mintKeys.append(request.uploadKey); try check("initializeFile"); let result = try await base.initializeFile(request); try check("initializeFileAfter"); return result }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse { try check("renewFileTicket"); return try await base.renewFileTicket(fileId: fileId) }
    func upload(fileId: String, ticket: String, bytes: Data, progress: (@Sendable (Double) -> Void)?) async throws(AppError) -> Void { try check("upload"); try await base.upload(fileId: fileId, ticket: ticket, bytes: bytes, progress: progress); try check("uploadAfter") }
    func download(fileId: String) async throws(AppError) -> Data { try check("download"); return try await base.download(fileId: fileId) }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant { try check("startCall"); return try await base.startCall(request) }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) -> Void { try check("endCall"); return try await base.endCall(callId: callId, request: request) }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) -> Void { try check("cancelCall"); return try await base.cancelCall(attemptId: attemptId, request: request) }
    func voice(conversationId: String) async throws(AppError) -> VoiceView { try check("voice"); return try await base.voice(conversationId: conversationId) }
    func updateVoice(conversationId: String, request: VoicePatchRequest) async throws(AppError) -> VoiceView { try check("updateVoice"); return try await base.updateVoice(conversationId: conversationId, request: request) }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> VoiceCatalog { try check("voices"); return try await base.voices(conversationId: conversationId, query: query) }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void { try check("registerPushToken"); return try await base.registerPushToken(request) }
    func unpair() async throws(AppError) -> Void { try check("unpair"); return try await base.unpair() }
}

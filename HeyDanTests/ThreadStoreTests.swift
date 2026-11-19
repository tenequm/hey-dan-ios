import Foundation
import HeyDanCore
import Testing
@testable import HeyDan

struct ThreadStoreTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private let host = URL(string: "https://app.example.com")!

    @MainActor private func paired(_ service: any AppService, store: any ThreadStore = SwiftDataThreadStore(inMemory: true),
                                   files: OutboxFile, active: Bool = false) async -> ChatController {
        let chat = ChatController(service: service, store: store, files: files, monitorsNetwork: false)
        if !active { chat.setActive(false) }
        chat.selectPairing(FixtureAppService.pairing, host: host)
        await chat.loadTask?.value
        return chat
    }

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

    @Test func historyFloorsPersistBeforeBootstrap() async throws {
        let store = SwiftDataThreadStore(inMemory: true)
        var snapshot = ThreadSnapshot()
        snapshot.historyFloors = ["conv_taylor01": 12]
        try await store.save(snapshot, host: host, deviceId: "device")
        let loaded = try await store.load(host: host, deviceId: "device")
        #expect(!loaded.hasCursor)
        #expect(loaded.historyFloors == snapshot.historyFloors)
        try await store.save(ThreadSnapshot(cursor: 30), host: host, deviceId: "device")
        let bootstrapped = try await store.load(host: host, deviceId: "device")
        #expect(bootstrapped.cursor == 30)
        #expect(bootstrapped.historyFloors == snapshot.historyFloors)
    }

    @Test func schemaWipePreservesOutbox() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = OutboxFile(root: root)
        let entry = Outbox.Entry(host: host, conversationId: "conv_taylor01",
            request: SendRequest(clientId: UUID().uuidString, text: "test", fileIds: []))
        try await outbox.save([entry], host: host, deviceId: "device")
        try await SwiftDataThreadStore(root: root, schemaVersion: 1).save(ThreadSnapshot(cursor: 10, conversations: [conversation(seq: 10)]), host: host, deviceId: "device")
        let reopened = try await SwiftDataThreadStore(root: root, schemaVersion: 1).load(host: host, deviceId: "device")
        #expect(reopened.cursor == 10)
        #expect(reopened.conversations == [conversation(seq: 10)])
        let store = SwiftDataThreadStore(root: root, schemaVersion: 2)
        let snapshot = try await store.load(host: host, deviceId: "device")
        #expect(snapshot.cursor == 0)
        #expect(snapshot.conversations.isEmpty)
        #expect(try await outbox.load(host: host, deviceId: "device") == [entry])
    }

    @MainActor @Test func unknownCachedItemRefetchesHistoryAtTheSameSequence() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FixtureAppService()
        let store = SwiftDataThreadStore(inMemory: true)
        let unknown = ThreadEntity.unknown(.object(["kind": .string("message"), "id": .string("msg_2101"),
            "seq": .integer(2), "order": .integer(2), "conversationId": .string("conv_taylor01")]))
        var snapshot = ThreadSnapshot(cursor: 10, entities: [unknown])
        snapshot.historyFloors = ["conv_taylor01": 1, "other": 3]
        try await store.save(snapshot, host: host, deviceId: "dev_fixture")
        let chat = await paired(service, store: store, files: OutboxFile(root: root))
        #expect(chat.historyFloors == ["other": 3])
        #expect(chat.reducer.entities.isEmpty)
        chat.openConversation("conv_taylor01")
        await chat.loadHistory(newest: true)
        guard case .message(let message) = chat.reducer.entities["msg_2101"] else {
            Issue.record("Expected the refetched message")
            return
        }
        #expect(message.seq == 2)
        var reducer = ThreadReducer()
        reducer.upsert(unknown)
        #expect(reducer.upsert(.message(message)) == ["msg_2101"])
        #expect(reducer.upsert(unknown).isEmpty)
    }

    @MainActor @Test func offlineEnqueueReconnectAndRestore() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataThreadStore(inMemory: true)
        let files = OutboxFile(root: root)
        let service = FixtureAppService()
        let chat = await paired(service, store: store, files: files)
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
        chat.setActive(false)
        let cursor = chat.reducer.cursor
        let restored = await paired(service, store: store, files: files)
        #expect(restored.reducer.cursor == cursor)
        #expect(restored.conversations.first?.unread == 2)
        #expect(restored.outbox.entries.isEmpty)
        restored.openConversation("conv_taylor01")
        restored.setActive(true)
        try await waitUntil { restored.connectionState == .connected }
        #expect(restored.thread.filter { if case .message(let m) = $0 { return m.clientId == clientId }; return false }.count == 1)
        restored.setActive(false)
    }

    @MainActor @Test func hidingAnAgentUpdatesAnOpenStreamAndItsOfflineCache() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hostService = FixtureAppService()
        let store = SwiftDataThreadStore(inMemory: true)
        let files = OutboxFile(root: root)
        let chat = await paired(hostService, store: store, files: files, active: true)
        defer { chat.setActive(false) }
        try await waitUntil { chat.connectionState == .connected }
        let conversation = try #require(chat.conversations.first)
        #expect(chat.openConversation(conversation.id))
        #expect(chat.openConversation(conversation.id))
        _ = try await hostService.setAgent(id: conversation.agent.id, request: .init(shown: false))
        try await waitUntil { chat.conversations.isEmpty && chat.openConversationId == nil && chat.badge?.unreadTotal == 0 }
        let offline = await paired(hostService, store: store, files: files)
        #expect(offline.conversations.isEmpty)
        #expect(!offline.openConversation(conversation.id))
        #expect(offline.openConversationId == nil)
        _ = try await hostService.setAgent(id: conversation.agent.id, request: .init(shown: true))
        try await waitUntil { chat.conversations.first?.id == conversation.id && chat.badge?.unreadTotal == conversation.unread }
    }

    @MainActor @Test func staleListKeepsShownThreadAndHistoryAcrossReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let store = SwiftDataThreadStore(inMemory: true)
        let files = OutboxFile(root: root)
        let chat = await paired(service, store: store, files: files, active: true)
        defer { chat.setActive(false) }
        try await waitUntil { chat.connectionState == .connected }
        let row = try #require(chat.conversations.first)
        _ = try await service.setAgent(id: row.agent.id, request: .init(shown: false))
        try await waitUntil { chat.conversations.isEmpty }
        await service.hold("conversations")
        let refresh = Task { await chat.refresh() }
        try await service.waitUntilHeld()
        _ = try await service.setAgent(id: row.agent.id, request: .init(shown: true))
        try await waitUntil { !chat.conversations.isEmpty }
        chat.openConversation(row.id)
        try await waitUntil { !chat.thread.isEmpty }
        let expected = chat.thread
        await service.release()
        await refresh.value
        #expect(chat.openConversationId == row.id)
        #expect(chat.thread == expected)
        let offline = await paired(service, store: store, files: files)
        #expect(offline.conversations == chat.conversations)
        #expect(offline.reducer.thread(conversationId: row.id) == expected)
    }

    @MainActor @Test func swipesUpdateWhilePendingAndRestoreAfterFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let chat = await paired(service, files: OutboxFile(root: root))
        await chat.refresh()
        let row = try #require(chat.conversations.first)
        chat.openConversation(row.id)
        try await waitUntil { !chat.thread.isEmpty }
        chat.closeConversation()
        let historyCalls = await service.beforeOrders.count
        for method in ["markRead", "setAgent"] {
            await service.hold(method)
            await service.fail(method, with: [.transport(.offline)])
            let swipe = Task {
                if method == "markRead" { try await chat.toggleRead(row) }
                else { try await chat.hide(row) }
            }
            try await service.waitUntilHeld()
            if method == "markRead" { #expect(chat.conversations.first?.unread == 0) }
            else { #expect(chat.conversations.isEmpty) }
            await service.release()
            await #expect(throws: AppError.self) { try await swipe.value }
            #expect(chat.conversations == [row])
        }
        #expect(await service.beforeOrders.count == historyCalls)
        try await chat.toggleRead(row)
        let read = try #require(chat.conversations.first)
        #expect(read.unread == 0)
        await service.hold("markUnread")
        await service.fail("markUnread", with: [.transport(.offline)])
        let unread = Task { try await chat.toggleRead(read) }
        try await service.waitUntilHeld()
        #expect(chat.conversations.first?.unread == 1)
        await service.release()
        await #expect(throws: AppError.self) { try await unread.value }
        #expect(chat.conversations == [read])

        try await chat.hide(read)
        #expect(chat.conversations.isEmpty)
        _ = try await service.setAgent(id: read.agent.id, request: .init(shown: true))
        await chat.refresh()
        #expect(chat.conversations.first?.id == read.id)
    }

    @MainActor @Test func readAndAnswerKeepServerState() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = await paired(FixtureAppService(), files: OutboxFile(root: root))
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        await chat.loadHistory()
        await chat.answer(questionId: "q_0123", value: "continue")
        #expect(chat.thread.contains { if case .question(let q) = $0 { return q.state == .answered }; return false })
        await chat.markRead(order: 2)
        await chat.markRead(order: 4)
        await chat.readTask?.value
        // The debounce hands the read to its own task, which closing the thread cannot cancel.
        chat.closeConversation()
        await chat.readFlushTask?.value
        #expect(chat.conversations.first?.readOrder == 4)
        #expect(chat.badge?.unreadTotal == 0)
        #expect(chat.reducer.cursor == 10)
    }

    @MainActor @Test func failingSendPreservesOrderAndResumesCursor() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.fail("send", with: [.transport(.timeout)])
        let store = SwiftDataThreadStore(inMemory: true)
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
            let chat = await paired(service, files: OutboxFile(root: root), active: true)
            try await waitUntil { chat.paused }
            #expect(await service.cursors.isEmpty)
            #expect(!chat.hasCursor)
            #expect(chat.pairing != nil)
            chat.error = .transport(.timeout)
            chat.protectedDataAvailable()
            if case .keyUnavailable = failure {
                try await waitUntil { chat.connectionState == .connected }
            } else {
                #expect(chat.paused)
            }
            chat.setActive(false)
        }
    }

    @MainActor @Test func restoredHostReplacesTheCachedTimeline() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let store = SwiftDataThreadStore(inMemory: true)
        var old = ThreadSnapshot(cursor: 80, conversations: [conversation(seq: 80)])
        old.historyFloors = ["conv_taylor01": 78]
        try await store.save(old, host: host, deviceId: "dev_fixture")
        let chat = await paired(service, store: store, files: OutboxFile(root: root), active: true)
        try await waitUntil { chat.connectionState == .connected }
        chat.setActive(false)
        #expect(await service.cursors == [10])
        let saved = try await store.load(host: host, deviceId: "dev_fixture")
        #expect(saved.cursor == 10)
        #expect(saved.conversations.first?.seq == 1)
        #expect(saved.historyFloors.isEmpty)
    }

    @MainActor @Test func refreshingRetriesFailedLocalLoad() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OutboxFile(root: root)
        let directory = await files.directory(host: host, deviceId: "dev_fixture").appending(path: "entries.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chat = await paired(FixtureAppService(), files: files)
        #expect(!chat.ready)
        try FileManager.default.removeItem(at: directory)
        await chat.refresh()
        #expect(chat.ready)
        #expect(chat.hasCursor)
        for id in ["conversation1", "conversation2"] {
            chat.outbox.enqueue(Outbox.Entry(host: host, conversationId: id,
                request: SendRequest(clientId: "duplicate", text: "", fileIds: [])))
        }
        #expect(chat.outboxStates == ["duplicate": .queued])
    }

    @MainActor @Test func lostFileResponsesReuseIdentities() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "file.txt")
        try Data("file".utf8).write(to: source)
        let service = ScriptedAppService()
        await service.fail("initializeFileAfter", with: [.transport(.timeout)])
        await service.fail("uploadAfter", with: [.transport(.timeout)])
        let chat = await paired(service, files: OutboxFile(root: root))
        chat.openConversation("conv_taylor01")
        #expect(await chat.send(text: "file", attachments: [StagedAttachment(fileURL: source, name: "file.txt", mimeType: "text/plain")]))
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.isEmpty }
        #expect(await service.mintKeys.count == 2)
        #expect(await Set(service.mintKeys).count == 1)
        #expect(await service.sentIDs.count == 1)
        chat.setActive(false)
    }

    @Test func picksRespectFileSizeAndTrayCapacity() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: Int(Outbox.maximumFileBytes)).write(to: root)
        let accepted = try await AttachmentStaging.document(root)
        defer { AttachmentStaging.remove(accepted) }
        let file = try FileHandle(forWritingTo: root)
        try file.truncate(atOffset: UInt64(Outbox.maximumFileBytes + 1))
        try file.close()
        for photo in [false, true] {
            do {
                _ = try await photo ? AttachmentStaging.photo(root) : AttachmentStaging.document(root)
                Issue.record("Accepted an oversized pick")
            } catch AppError.limit(let message) {
                #expect(message == Outbox.fileLimitMessage)
            }
        }
        try AttachmentStaging.checkCapacity(Outbox.maximumFiles - 1)
        #expect(throws: AppError.self) { try AttachmentStaging.checkCapacity(Outbox.maximumFiles) }
    }

    @MainActor @Test func closeFlushesReadAndOversizedDraftIsRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = await paired(ScriptedAppService(), files: OutboxFile(root: root))
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        #expect(await !chat.send(text: String(repeating: "a", count: Outbox.maximumTextBytes + 1)))
        #expect(chat.outbox.entries.isEmpty)
        #expect(chat.sendFailure != nil)
        #expect(chat.error == nil)
        #expect(await chat.send(text: "fits"))
        #expect(chat.sendFailure == nil)
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

    @MainActor @Test(arguments: [Outbox.State.failed, .outcomeUnknown])
    func discardingFailedDeliveryRemovesEntryAndCopy(state: Outbox.State) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OutboxFile(root: root)
        let chat = await paired(ScriptedAppService(), files: files)
        let device = FixtureAppService.pairing.deviceId
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "draft.txt")
        try Data("draft".utf8).write(to: source)
        let attachments = try await files.stage([StagedAttachment(fileURL: source, name: "draft.txt", mimeType: "text/plain")],
                                                host: host, deviceId: device)
        let copy = await files.directory(host: host, deviceId: device).appending(path: try #require(attachments.first).localFileName)
        let entry = Outbox.Entry(host: host, conversationId: "conv_taylor01",
                                 request: SendRequest(clientId: "discard", text: "", fileIds: []), state: state, attachments: attachments)
        chat.outbox.enqueue(entry)
        try await chat.saveOutbox()
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try await files.load(host: host, deviceId: device) == [entry])
        await chat.discard(clientId: entry.request.clientId)
        #expect(chat.outbox.entries.isEmpty)
        #expect(try await files.load(host: host, deviceId: device).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor @Test func answerErrorsAndExplicitRetry() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let chat = await paired(service, files: OutboxFile(root: root))
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
        #expect(chat.outboxStates["old"]?.canSendAgain == true)
        await chat.retry(clientId: "old")
        #expect(chat.outboxStates["old"]?.canSendAgain != true)
        await chat.retry(clientId: "old")
        #expect(chat.outbox.entries.count == 1)
        #expect(chat.outbox.entries.first?.request.clientId != "old")
        await chat.discard(clientId: try #require(chat.outbox.entries.first?.request.clientId))
        #expect(chat.outbox.entries.isEmpty)
    }

    @MainActor @Test func malformedEventAdvancesAndCancelledReplayResumes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([AppEvent(kind: .message, id: 11, data: Data("{}".utf8)),
            AppEvent(kind: .synchronized, id: nil, data: try JSONEncoder().encode(Synchronized(seq: 12)))])
        let store = SwiftDataThreadStore(inMemory: true)
        let chat = await paired(service, store: store, files: OutboxFile(root: root), active: true)
        try await waitUntil { chat.connectionState == .connected }
        #expect(chat.reducer.cursor == 12)
        chat.setActive(false)
        chat.setActive(true)
        try await waitUntil { chat.connectionState == .connected }
        #expect(await service.cursors == [10, 12])
        chat.setActive(false)
        let snapshot = try await store.load(host: host, deviceId: "dev_fixture")
        #expect(snapshot.cursor == 12)
    }

    @MainActor @Test func revocationClearsCacheAndOutbox() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.fail("hello", with: [.server(status: 401, body: ErrorBody(error: "device_revoked", message: "Revoked"))])
        let store = SwiftDataThreadStore(inMemory: true), files = OutboxFile(root: root)
        let chat = await paired(service, store: store, files: files)
        await chat.refresh()
        chat.openConversation("conv_taylor01")
        #expect(await chat.send(text: "pending"))
        chat.setActive(true)
        try await waitUntil { chat.pairing == nil }
        await chat.streamTask?.value
        #expect(try await store.load(host: host, deviceId: "dev_fixture").conversations.isEmpty)
        #expect(try await files.load(host: host, deviceId: "dev_fixture").isEmpty)
        chat.setActive(false)
    }

    @MainActor @Test func historyFloorExcludesOldEdits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        let chat = await paired(service, files: OutboxFile(root: root))
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
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OutboxFile(root: root, downloads: root.appending(path: "caches"))
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let directory = await files.directory(host: host, deviceId: "device")
        #expect(try await files.load(host: host, deviceId: "device").isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appending(path: "entries.json"))
        #expect(try await files.load(host: host, deviceId: "device").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("entries-invalid-") })
        let cached = try await files.cache(Data("file".utf8), fileId: "file", name: "../Report.pdf", host: host, deviceId: "device")
        #expect(cached.lastPathComponent == "Report.pdf")
        #expect(cached.deletingLastPathComponent().lastPathComponent == StoreLocation.digest("file"))
        #expect(cached.path.hasPrefix(root.appending(path: "caches").path))
        try await files.clear(host: host, deviceId: "device")
        #expect(await files.cached(fileId: "file", name: "../Report.pdf", host: host, deviceId: "device") == nil)
    }

    @MainActor @Test func lostSendResponseRetriesSameIdentity() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([])
        await service.fail("sendAfter", with: [.transport(.timeout)])
        let chat = await paired(service, files: OutboxFile(root: root))
        chat.openConversation("conv_taylor01")
        #expect(await chat.send(text: "lost response"))
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.isEmpty }
        #expect(await service.sentIDs.count == 2)
        #expect(await Set(service.sentIDs).count == 1)
        chat.setActive(false)
    }

    @MainActor @Test func cancelBeforeSynchronizedResumesCommittedCursor() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([AppEvent(kind: .unknown("future"), id: 11, data: Data("{}".utf8))])
        let chat = await paired(service, files: OutboxFile(root: root), active: true)
        try await waitUntil { chat.reducer.cursor == 11 }
        #expect(chat.connectionState == .connecting)
        chat.setActive(false)
        await service.events([AppEvent(kind: .synchronized, id: nil, data: try JSONEncoder().encode(Synchronized(seq: 12)))])
        chat.setActive(true)
        try await waitUntil { chat.connectionState == .connected }
        #expect(await service.cursors == [10, 11])
        chat.setActive(false)
    }

    @MainActor @Test func sendTappedInTheForegroundIsDeliveredAfterTheAppLeavesIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.events([])
        let chat = await paired(service, files: OutboxFile(root: root), active: true)
        chat.openConversation("conv_taylor01")
        let sending = Task { await chat.send(text: "swiped home") }
        // The tap runs up to its first suspension (staging the copy) in the foreground, then the app leaves it.
        await Task.yield()
        chat.setActive(false)
        #expect(await sending.value)
        // Acknowledged as stored by the host; reached arrives over the stream, which stays closed in the background.
        try await waitUntil { chat.outbox.entries.first?.state == .stored }
        #expect(await service.sentIDs.count == 1)
        try await waitUntil { chat.backgroundDelivery == .invalid }
        #expect(await chat.send(text: "sent while away"))
        #expect(chat.outbox.entries.count == 2)
        #expect(chat.outbox.entries.last?.state == .queued)
    }

    @MainActor @Test func historyThatFailedOnOpenLoadsAgainOnceSynchronized() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ScriptedAppService()
        await service.fail("history", with: [.transport(.offline)])
        await service.events([AppEvent(kind: .synchronized, id: nil, data: try JSONEncoder().encode(Synchronized(seq: 12)))])
        let chat = await paired(service, files: OutboxFile(root: root))
        chat.openConversation("conv_taylor01")
        try await waitUntil { chat.historyStale }
        #expect(chat.reducer.entities["msg_2101"] == nil)
        chat.setActive(true)
        try await waitUntil { chat.reducer.entities["msg_2101"] != nil }
        #expect(!chat.historyStale)
        chat.setActive(false)
    }

    @MainActor @Test func historyLoadedDuringAStreamSaveSurvivesTheBatch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SaveGate()
        let store = SwiftDataThreadStore(inMemory: true, beforeCommit: { snapshot in
            if snapshot.cursor == 12, snapshot.allowedConversations == nil { gate.hold() }
        })
        let service = ScriptedAppService()
        await service.events([AppEvent(kind: .synchronized, id: nil, data: try JSONEncoder().encode(Synchronized(seq: 12)))])
        await service.pages([HistoryPage(items: [.message(Message(kind: .message, id: "msg_older", conversationId: "conv_taylor01",
            order: 1, seq: 1, role: .agent, text: "Older", files: [], reactions: [], createdAt: 0))],
            hasMoreBefore: true, hasMoreAfter: false)])
        let chat = await paired(service, store: store, files: OutboxFile(root: root), active: true)
        try await waitUntil { gate.isHeld }
        chat.openConversation("conv_taylor01")
        try await waitUntil { chat.hasMoreBefore }
        gate.release()
        try await waitUntil { chat.connectionState == .connected }
        #expect(chat.reducer.cursor == 12)
        #expect(chat.hasMoreBefore)
        #expect(chat.reducer.entities["msg_older"] != nil)
        chat.setActive(false)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

}

/// Holds one store commit until released, so a test can act while a save is in flight.
private final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var held = false
    var isHeld: Bool { lock.withLock { held } }
    func hold() {
        let first = lock.withLock { () -> Bool in defer { held = true }; return !held }
        if first { _ = released.wait(timeout: .now() + 10) }
    }
    func release() { released.signal() }
}

actor ScriptedAppService: AppService {
    let base = FixtureAppService()
    var failures: [String: [AppError]] = [:]
    var sentIDs: [String] = []
    var cursors: [Int64] = []
    var mintKeys: [String] = []
    var emittedSeq: Int64 = 0
    var scriptedEvents: [AppEvent]?
    var scriptedPages: [HistoryPage] = []
    var beforeOrders: [Int64?] = []
    private var heldMethod: String?
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while continuation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(continuation != nil)
    }
    func hold(_ method: String) { heldMethod = method }
    func release() {
        heldMethod = nil
        continuation?.resume()
        continuation = nil
    }
    private func waitIfHeld(_ method: String) async {
        if heldMethod == method { await withCheckedContinuation { continuation = $0 } }
    }
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
    func conversations() async throws(AppError) -> ConversationsResponse {
        try check("conversations")
        var list = try await base.conversations()
        list.seq = max(list.seq, emittedSeq)
        await waitIfHeld("conversations")
        return list
    }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage { beforeOrders.append(query.before)
        try check("history")
        if !scriptedPages.isEmpty { return scriptedPages.removeFirst() }
        return try await base.history(conversationId: conversationId, query: query) }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse { sentIDs.append(request.clientId); try check("send"); let result = try await base.send(conversationId: conversationId, request: request); try check("sendAfter"); return result }
    func agentStatus(conversationId: String) async throws(AppError) -> AgentStatusResponse {
        try await base.agentStatus(conversationId: conversationId)
    }
    func updateSettings(agentId: String, request: AgentSettingsRequest) async throws(AppError) -> AgentSettingsResponse {
        try await base.updateSettings(agentId: agentId, request: request)
    }
    func agents() async throws(AppError) -> AgentsResponse {
        try check("agents"); return try await base.agents()
    }
    func setAgent(id: String, request: AgentVisibilityRequest) async throws(AppError) -> AgentResponse {
        await waitIfHeld("setAgent")
        try check("setAgent"); return try await base.setAgent(id: id, request: request)
    }
    func markUnread(conversationId: String) async throws(AppError) -> ReadResponse {
        await waitIfHeld("markUnread")
        try check("markUnread"); return try await base.markUnread(conversationId: conversationId)
    }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse { await waitIfHeld("markRead"); try check("markRead"); return try await base.markRead(conversationId: conversationId, request: request) }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse { try check("answer"); return try await base.answer(questionId: questionId, request: request) }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> { cursors.append(query.after); try check("events")
        if let scriptedEvents {
            for event in scriptedEvents { emittedSeq = (try? event.cursor(after: emittedSeq)) ?? emittedSeq }
            return AsyncThrowingStream { continuation in
                for event in scriptedEvents { continuation.yield(event) }
            }
        }
        return try await base.events(query: query) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse { mintKeys.append(request.uploadKey); try check("initializeFile"); let result = try await base.initializeFile(request); try check("initializeFileAfter"); return result }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse { try check("renewFileTicket"); return try await base.renewFileTicket(fileId: fileId) }
    func upload(fileId: String, ticket: String, bytes: Data) async throws(AppError) -> Void { try check("upload"); try await base.upload(fileId: fileId, ticket: ticket, bytes: bytes); try check("uploadAfter") }
    func download(fileId: String) async throws(AppError) -> Data { try check("download"); return try await base.download(fileId: fileId) }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant { try check("startCall"); return try await base.startCall(request) }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) -> Void { try check("endCall"); return try await base.endCall(callId: callId, request: request) }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) -> Void { try check("cancelCall"); return try await base.cancelCall(attemptId: attemptId, request: request) }
    func voice(conversationId: String) async throws(AppError) -> TTSView { try check("voice"); return try await base.voice(conversationId: conversationId) }
    func updateVoice(conversationId: String, request: TTSPatch) async throws(AppError) -> TTSView { try check("updateVoice"); return try await base.updateVoice(conversationId: conversationId, request: request) }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> CatalogPage { try check("voices"); return try await base.voices(conversationId: conversationId, query: query) }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void { try check("registerPushToken"); return try await base.registerPushToken(request) }
    func unpair() async throws(AppError) -> Void { try check("unpair"); return try await base.unpair() }
}

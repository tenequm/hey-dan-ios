import Foundation
import HeyDanCore
import Testing
@testable import HeyDan

struct ThreadStoreTests {
    private let host = URL(string: "https://app.opx.one")!

    private func conversation(seq: Int64, unread: Int = 2) -> Conversation {
        Conversation(kind: .conversation, id: "conv_stan01", seq: seq,
            agent: Agent(id: "ag_stan", name: "Stan"), unread: unread,
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
        let entry = Outbox.Entry(host: host, conversationId: "conv_stan01",
            request: SendRequest(clientId: UUID().uuidString, text: "test", fileIds: []))
        try await outbox.save([entry], host: host, deviceId: "device")
        try await populate(root: root)
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
        chat.openConversation("conv_stan01")
        await chat.loadHistory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        try Data("attachment".utf8).write(to: source)
        await chat.send(text: "test", attachments: [StagedAttachment(fileURL: source, name: "test.txt", mimeType: "text/plain")])
        #expect(chat.outbox.entries.count == 1)
        #expect(chat.outbox.entries.first?.state == .queued)
        #expect(try await files.load(host: host, deviceId: "dev_fixture").count == 1)
        chat.setActive(true)
        try await waitUntil { chat.outbox.entries.first?.state == .reached }
        let clientId = try #require(chat.outbox.entries.first?.request.clientId)
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
        #expect(restored.outbox.entries.first?.state == .reached)
        restored.openConversation("conv_stan01")
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
        chat.openConversation("conv_stan01")
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

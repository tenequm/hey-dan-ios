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

    private func populate(root: URL) async throws {
        let store = SwiftDataThreadStore(root: root, schemaVersion: 1)
        try await store.save(ThreadSnapshot(cursor: 10, conversations: [conversation(seq: 10)]), host: host, deviceId: "device")
    }
}

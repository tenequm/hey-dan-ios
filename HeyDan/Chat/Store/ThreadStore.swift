import Foundation
import HeyDanCore

/// One atomic cache snapshot: no SwiftData objects cross this boundary.
struct ThreadSnapshot: Sendable {
    var cursor: Int64 = 0
    var hasCursor = false
    var replacesCache = false
    var allowedConversations: Set<String>?
    var historyFloors: [String: Int64] = [:]
    init(cursor: Int64? = nil, conversations: [Conversation] = [], entities: [ThreadEntity] = []) {
        self.cursor = cursor ?? 0; hasCursor = cursor != nil
        self.conversations = conversations; self.entities = entities
    }
    var conversations: [Conversation] = []
    var entities: [ThreadEntity] = []
}

/// Persistence scoped by host and device, separately from the outbox.
protocol ThreadStore: Sendable {
    func load(host: URL, deviceId: String) async throws -> ThreadSnapshot
    func save(_ snapshot: ThreadSnapshot, host: URL, deviceId: String) async throws
    func clear(host: URL, deviceId: String) async throws
}

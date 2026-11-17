import Foundation
import HeyDanCore

/// H3 owns the atomic cache snapshot; no SwiftData objects cross this boundary.
struct ThreadSnapshot: Sendable {
    var cursor: Int64 = 0
    var conversations: [Conversation] = []
    var entities: [ThreadEntity] = []
}

/// H3 owns persistence scoped by host and device, separately from the outbox.
protocol ThreadStore: Sendable {
    func load(host: URL, deviceId: String) async throws -> ThreadSnapshot
    func save(_ snapshot: ThreadSnapshot, host: URL, deviceId: String) async throws
    func clear(host: URL, deviceId: String) async throws
}

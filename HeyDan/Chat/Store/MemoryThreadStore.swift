import Foundation
import HeyDanCore

actor MemoryThreadStore: ThreadStore {
    private struct Key: Hashable { let host: URL; let deviceId: String }
    private var snapshots: [Key: ThreadSnapshot] = [:]

    func load(host: URL, deviceId: String) -> ThreadSnapshot {
        snapshots[Key(host: host, deviceId: deviceId)] ?? ThreadSnapshot()
    }

    func save(_ snapshot: ThreadSnapshot, host: URL, deviceId: String) {
        let key = Key(host: host, deviceId: deviceId)
        var current = snapshots[key] ?? ThreadSnapshot()
        current.cursor = max(current.cursor, snapshot.cursor)
        current.hasCursor = current.hasCursor || snapshot.hasCursor
        for conversation in snapshot.conversations {
            if let index = current.conversations.firstIndex(where: { $0.id == conversation.id }) {
                if conversation.seq > current.conversations[index].seq { current.conversations[index] = conversation }
            } else { current.conversations.append(conversation) }
        }
        for entity in snapshot.entities {
            guard let incoming = identity(entity) else { continue }
            if let index = current.entities.firstIndex(where: { identity($0)?.id == incoming.id }) {
                if incoming.seq > (identity(current.entities[index])?.seq ?? -1) { current.entities[index] = entity }
            } else { current.entities.append(entity) }
        }
        current.entities.sort { (identity($0)?.order ?? 0) < (identity($1)?.order ?? 0) }
        snapshots[key] = current
    }

    func clear(host: URL, deviceId: String) {
        snapshots[Key(host: host, deviceId: deviceId)] = nil
    }

    private func identity(_ entity: ThreadEntity) -> (id: String, seq: Int64, order: Int64)? {
        switch entity {
        case .message(let message): ("message:" + message.id, message.seq, message.order)
        case .question(let question): ("question:" + question.id, question.seq, question.order)
        case .unknown: nil
        }
    }
}

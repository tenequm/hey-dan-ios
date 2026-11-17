import Foundation

public enum ThreadRow: Sendable, Equatable {
    case entity(ThreadEntity), outbox(Outbox.Entry)
}

public struct ThreadReducer: Sendable {
    public private(set) var cursor: Int64 = 0
    public private(set) var conversations: [String: Conversation] = [:]
    public private(set) var entities: [String: ThreadEntity] = [:]
    public private(set) var statuses: [String: Status] = [:]
    public private(set) var badge: Badge?
    public private(set) var hasMoreBefore: [String: Bool] = [:]
    public init(cursor: Int64 = 0, conversations: [String: Conversation] = [:],
                entities: [String: ThreadEntity] = [:], statuses: [String: Status] = [:],
                badge: Badge? = nil, hasMoreBefore: [String: Bool] = [:]) {
        self.cursor = cursor; self.conversations = conversations; self.entities = entities
        self.statuses = statuses; self.badge = badge; self.hasMoreBefore = hasMoreBefore
    }

    @discardableResult public mutating func apply(_ event: AppEvent) throws -> Set<String> {
        let nextCursor = try event.cursor(after: cursor)
        var changed: Set<String> = []
        switch event.kind {
        case .message, .question: changed = upsert(try event.decode(ThreadEntity.self))
        case .conversation: changed = upsert(try event.decode(Conversation.self))
        case .status: changed = upsert(try event.decode(Status.self))
        case .badge: changed = upsert(try event.decode(Badge.self))
        default: break
        }
        cursor = nextCursor
        return changed
    }

    @discardableResult public mutating func upsert(_ entity: ThreadEntity) -> Set<String> {
        guard let key = entity.identity,
              key.seq > (entities[key.id]?.identity?.seq ?? -1) else { return [] }
        entities[key.id] = entity
        return [key.id]
    }
    @discardableResult public mutating func upsert(_ conversation: Conversation) -> Set<String> {
        guard conversation.seq > (conversations[conversation.id]?.seq ?? -1) else { return [] }
        conversations[conversation.id] = conversation
        return [conversation.id]
    }
    @discardableResult public mutating func upsert(_ status: Status) -> Set<String> {
        guard status.rev > (statuses[status.conversationId]?.rev ?? -1) else { return [] }
        statuses[status.conversationId] = status
        return [status.conversationId]
    }
    @discardableResult public mutating func upsert(_ value: Badge) -> Set<String> {
        guard value.rev > (badge?.rev ?? -1) else { return [] }
        badge = value
        return ["badge"]
    }
    @discardableResult public mutating func upsert(_ list: ConversationsResponse) -> Set<String> {
        let empty = cursor == 0 && conversations.isEmpty && entities.isEmpty && statuses.isEmpty && badge == nil
        var changed: Set<String> = []
        for value in list.conversations { changed.formUnion(upsert(value)) }
        for value in list.statuses { changed.formUnion(upsert(value)) }
        changed.formUnion(upsert(list.badge))
        if empty { cursor = list.seq }
        return changed
    }
    @discardableResult public mutating func upsert(_ page: HistoryPage, conversationId: String) -> Set<String> {
        var changed: Set<String> = []
        for value in page.items { changed.formUnion(upsert(value)) }
        hasMoreBefore[conversationId] = page.hasMoreBefore
        return changed
    }
    public func thread(conversationId: String) -> [ThreadEntity] {
        entities.values.filter { $0.identity?.conversationId == conversationId }.sorted {
            let a = $0.identity!, b = $1.identity!
            return a.order == b.order ? a.id < b.id : a.order < b.order
        }
    }
    public func rows(conversationId: String, outbox: [Outbox.Entry] = []) -> [ThreadRow] {
        let thread = thread(conversationId: conversationId)
        let confirmed = Set(thread.compactMap { entity -> String? in
            if case .message(let message) = entity { return message.clientId }
            return nil
        })
        return thread.filter(\.isRenderable).map(ThreadRow.entity) + outbox.filter {
            $0.conversationId == conversationId && $0.serverSeq == nil && !confirmed.contains($0.request.clientId)
        }.map(ThreadRow.outbox)
    }
}

extension ThreadEntity {
    fileprivate var identity: (id: String, seq: Int64, order: Int64, conversationId: String)? {
        switch self {
        case .message(let v): return (v.id, v.seq, v.order, v.conversationId)
        case .question(let v): return (v.id, v.seq, v.order, v.conversationId)
        case .unknown(.object(let v)):
            guard case .string(let id) = v["id"], case .integer(let seq) = v["seq"],
                  case .integer(let order) = v["order"], case .string(let conversation) = v["conversationId"] else { return nil }
            return (id, seq, order, conversation)
        default: return nil
        }
    }
    fileprivate var isRenderable: Bool {
        switch self {
        case .message(let v):
            guard v.kind == .message else { return false }
            switch v.role { case .user, .agent, .host: return true; default: return false }
        case .question(let v): return v.kind == .question
        case .unknown: return false
        }
    }
}

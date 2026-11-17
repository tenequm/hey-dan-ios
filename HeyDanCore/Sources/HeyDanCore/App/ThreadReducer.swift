import Foundation

/// H1 owns event reduction and cursor advancement.
public struct ThreadReducer: Sendable {
    public private(set) var cursor: Int64 = 0
    public private(set) var conversations: [String: Conversation] = [:]
    public private(set) var entities: [String: ThreadEntity] = [:]
    public private(set) var statuses: [String: Status] = [:]
    public private(set) var badge: Badge?
    public init() {}
    public mutating func apply(_ event: AppEvent) throws {}
    public mutating func upsert(_ entity: ThreadEntity) {}
}

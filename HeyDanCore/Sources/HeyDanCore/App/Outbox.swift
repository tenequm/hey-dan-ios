import Foundation

/// H1 owns durable outgoing state, independently of the thread cache.
public struct Outbox: Sendable {
    public enum State: Sendable, Equatable, Codable {
        case queued, uploading, sending, stored, routed, reached, failed, outcomeUnknown
    }
    public struct Entry: Sendable, Equatable, Codable {
        public let host: URL
        public let conversationId: String
        public let request: SendRequest
        public var state: State
        public init(host: URL, conversationId: String, request: SendRequest, state: State = .queued) {
            self.host = host
            self.conversationId = conversationId
            self.request = request
            self.state = state
        }
    }
    public private(set) var entries: [Entry] = []
    public init() {}
    public mutating func enqueue(_ entry: Entry) {}
    public mutating func reconcile(_ message: Message) {}
}

import Foundation
import HeyDanCore

import Observation

/// H3 owns chat state and lifecycle; H2 supplies the selected pairing.
@MainActor @Observable final class ChatController {
    static let shared = ChatController(service: SignedClient(), store: SwiftDataThreadStore())
    enum ConnectionState: Sendable { case disconnected, connecting, connected, reconnecting }
    private(set) var pairing: PairResponse?
    private(set) var conversations: [Conversation] = []
    private(set) var openConversationId: String?
    private(set) var thread: [ThreadEntity] = []
    private(set) var statuses: [String: Status] = [:]
    private(set) var outboxStates: [String: Outbox.State] = [:]
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var badge: Badge?
    private(set) var error: AppError?
    @ObservationIgnored let service: any AppService
    @ObservationIgnored let store: any ThreadStore

    init(service: any AppService, store: any ThreadStore) {
        self.service = service
        self.store = store
    }
    func selectPairing(_ pairing: PairResponse?, host: URL) {}
    func openConversation(_ id: String) {}
    func closeConversation() {}
    func setActive(_ active: Bool) {}
    func loadHistory(before: Int64? = nil, after: Int64? = nil) async {}
    func send(_ request: SendRequest) async {}
    func answer(questionId: String, value: String) async {}
    func markRead(order: Int64) async {}
    func retry(clientId: String) async {}
}

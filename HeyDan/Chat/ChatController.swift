import Foundation
import HeyDanCore
import Observation
import Network
import UIKit

@MainActor @Observable final class ChatController {
    static let shared: ChatController = {
        let controller: ChatController
        #if DEBUG
        if ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CHAT"] == "1" {
            controller = ChatController(service: FixtureAppService(), store: MemoryThreadStore())
        } else { controller = ChatController(store: SwiftDataThreadStore()) }
        #else
        controller = ChatController(store: SwiftDataThreadStore())
        #endif
        Task { @MainActor in _ = Pairings.shared }
        return controller
    }()
    enum ConnectionState: Sendable { case disconnected, connecting, connected, reconnecting }
    private(set) var pairing: PairResponse?
    private(set) var openConversationId: String?
    var connectionState: ConnectionState = .disconnected
    var error: AppError?
    var features: [String] = []
    var conversations: [Conversation] { reducer.conversations.values.sorted { $0.id < $1.id } }
    var thread: [ThreadEntity] { openConversationId.map { reducer.thread(conversationId: $0) } ?? [] }
    var rows: [ThreadRow] { openConversationId.map { reducer.rows(conversationId: $0, outbox: outbox.entries) } ?? [] }
    var statuses: [String: Status] { reducer.statuses }
    var badge: Badge? { reducer.badge }
    var hasMoreBefore: Bool { openConversationId.flatMap { reducer.hasMoreBefore[$0] } ?? false }
    var outboxStates: [String: Outbox.State] { Dictionary(uniqueKeysWithValues: outbox.entries.map { ($0.request.clientId, $0.state) }) }
    private(set) var uploadProgress: [String: Double] = [:]
    var reducer = ThreadReducer()
    var outbox = Outbox()
    @ObservationIgnored private(set) var service: any AppService
    @ObservationIgnored let store: any ThreadStore
    @ObservationIgnored let files: OutboxFile
    @ObservationIgnored let fixedService: Bool
    @ObservationIgnored var host: URL?
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var offlineUntil: Date?
    @ObservationIgnored var active = true
    @ObservationIgnored var networkAvailable = true
    @ObservationIgnored var runnerSleep: Task<Void, any Error>?
    @ObservationIgnored var ready = false
    @ObservationIgnored var hasCursor = false
    @ObservationIgnored var paused = false
    @ObservationIgnored var streamTask: Task<Void, Never>?
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var runnerID = UUID()
    @ObservationIgnored var savedEntries: [Outbox.Entry] = []
    @ObservationIgnored var durableIDs: Set<String> = []
    @ObservationIgnored var runner: Task<Void, Never>?
    @ObservationIgnored var readTask: Task<Void, Never>?
    @ObservationIgnored var readOrder: Int64 = 0
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var protectedTask: Task<Void, Never>?

    init(service: (any AppService)? = nil, store: any ThreadStore, files: OutboxFile = OutboxFile(), monitorsNetwork: Bool = true) {
        self.service = service ?? SignedClient()
        self.store = store
        self.files = files
        fixedService = service != nil
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["HEYDAN_OFFLINE_FOR"].flatMap(Double.init), seconds > 0 {
            offlineUntil = Date().addingTimeInterval(seconds)
        }
        #endif
        if monitorsNetwork {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.networkAvailable != available else { return }
                self.networkAvailable = available
                self.restart()
            }
        }
        monitor.start(queue: DispatchQueue(label: "chat.path"))
        }
        protectedTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                guard let self else { return }
                if case .keyUnavailable = self.error { self.paused = false }
                if !self.ready, let pairing = self.pairing, let host = self.host {
                    self.selectPairing(nil, host: host)
                    self.selectPairing(pairing, host: host)
                } else { self.restart() }
            }
        }
    }
    deinit { monitor?.cancel(); protectedTask?.cancel(); streamTask?.cancel(); runner?.cancel(); loadTask?.cancel(); readTask?.cancel() }

    func setProgress(_ value: Double, key: String) { uploadProgress[key] = value }

    func selectPairing(_ pairing: PairResponse?, host: URL) {
        guard self.host != host || self.pairing != pairing else { return }
        generation = UUID()
        loadTask?.cancel(); streamTask?.cancel(); runner?.cancel(); readTask?.cancel()
        runner = nil; streamTask = nil
        self.host = host; self.pairing = pairing
        reducer = ThreadReducer(); outbox = Outbox(); openConversationId = nil
        savedEntries = []; durableIDs = []; ready = false; hasCursor = false; paused = false; features = []; error = nil; uploadProgress = [:]
        connectionState = .disconnected
        guard let pairing else { return }
        if !fixedService { service = SignedClient(host: host, deviceId: pairing.deviceId) }
        let token = generation
        loadTask = Task {
            do {
                let snapshot = try await store.load(host: host, deviceId: pairing.deviceId)
                let entries = try await files.load(host: host, deviceId: pairing.deviceId)
                guard token == generation, !Task.isCancelled else { return }
                hasCursor = snapshot.hasCursor
                reducer = ThreadReducer(cursor: snapshot.cursor)
                for value in snapshot.conversations { reducer.upsert(value) }
                for value in snapshot.entities { reducer.upsert(value) }
                savedEntries = entries
                for entry in entries { outbox.enqueue(entry); durableIDs.insert(entry.request.clientId) }
                for entity in reducer.entities.values {
                    if case .message(let message) = entity { outbox.reconcile(message) }
                }
                ready = true
                restart()
            } catch { if token == generation { self.error = AppError.map(error) } }
        }
    }
    func openConversation(_ id: String) {
        guard openConversationId != id else { return }
        readTask?.cancel(); readOrder = 0
        openConversationId = id
        Task { await loadHistory() }
    }
    func closeConversation() { openConversationId = nil; readTask?.cancel(); readOrder = 0 }
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        restart()
    }
    func restart() {
        guard active, networkAvailable, ready, !paused, pairing != nil else {
            streamTask?.cancel(); streamTask = nil
            runnerSleep?.cancel()
            connectionState = .disconnected
            return
        }
        if connectionState != .connected {
            streamTask?.cancel()
            let token = generation
            streamTask = Task { await stream(token: token) }
        }
        var resumed = Outbox()
        for var entry in outbox.entries {
            entry.nextAttemptAt = nil
            resumed.enqueue(entry)
        }
        outbox = resumed
        runOutbox()
    }
    func waitForNetwork() async throws {
        if let deadline = offlineUntil, deadline > .now {
            connectionState = .disconnected
            try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
        }
        try Task.checkCancellation()
    }
    func refresh() async {
        await loadTask?.value
        guard ready else { return }
        let token = generation
        do { try await refreshList(token: token) }
        catch { await handle(error, token: token) }
    }
    func refreshList(token: UUID) async throws {
        guard ready else { throw AppError.transport(.unavailable) }
        let list = try await service.conversations()
        guard token == generation, !Task.isCancelled, let host, let pairing else { return }
        let cursor = hasCursor ? reducer.cursor : list.seq
        try await store.save(ThreadSnapshot(cursor: cursor, conversations: list.conversations), host: host, deviceId: pairing.deviceId)
        guard token == generation, !Task.isCancelled else { return }
        reducer = ThreadReducer(cursor: cursor, conversations: reducer.conversations, entities: reducer.entities,
            statuses: reducer.statuses, badge: reducer.badge, hasMoreBefore: reducer.hasMoreBefore)
        for value in list.conversations { reducer.upsert(value) }
        for value in list.statuses { reducer.upsert(value) }
        reducer.upsert(list.badge)
        hasCursor = true
    }
    func loadHistory(before: Int64? = nil, after: Int64? = nil) async {
        guard let id = openConversationId, ready else { return }
        let token = generation
        do {
            let page = try await service.history(conversationId: id, query: HistoryQuery(before: before, after: after))
            guard token == generation, !Task.isCancelled else { return }
            let changed = reducer.upsert(page, conversationId: id)
            for entity in page.items { if case .message(let message) = entity { outbox.reconcile(message) } }
            try await persist(changed)
            guard token == generation else { return }
            try await saveOutbox()
        } catch { await handle(error, token: token) }
    }
    func answer(questionId: String, value: String) async {
        let token = generation
        do {
            let response = try await service.answer(questionId: questionId, request: AnswerRequest(value: value))
            guard token == generation else { return }
            try await persist(reducer.upsert(.question(response.question)))
        } catch {
            guard token == generation else { return }
            if case AppError.server(409, let body) = error, let question = body.question {
                do { try await persist(reducer.upsert(.question(question))) } catch { self.error = AppError.map(error) }
            }
            await handle(error, token: token)
        }
    }
    func markRead(order: Int64) async {
        guard let id = openConversationId else { return }
        readOrder = max(readOrder, order)
        readTask?.cancel()
        let token = generation
        readTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
                let response = try await service.markRead(conversationId: id, request: ReadRequest(order: readOrder))
                guard token == generation, !Task.isCancelled else { return }
                reducer.upsert(response.badge)
                try await persist(reducer.upsert(response.conversation))
            } catch { if !Task.isCancelled { await handle(error, token: token) } }
        }
    }
    func conversation(forAgent agent: String, host: URL) async -> Conversation? {
        if self.host != host {
            do { try Pairings.shared.setActive(host: host) } catch { self.error = AppError.map(error); return nil }
        }
        await loadTask?.value
        await refresh()
        guard self.host == host else { return nil }
        return conversations.first { $0.agent.id == agent }
    }
    func unpair(host: URL) async {
        guard let entry = Pairings.shared.entries.first(where: { $0.host == host }) else { return }
        do {
            let client: any AppService = self.host == host ? service : SignedClient(host: host, deviceId: entry.pairing.deviceId)
            try await client.unpair()
            try Pairings.shared.remove(host: host)
            try await store.clear(host: host, deviceId: entry.pairing.deviceId)
            try await files.clear(host: host, deviceId: entry.pairing.deviceId)
        } catch { self.error = AppError.map(error) }
    }
    func persist(_ changed: Set<String>) async throws {
        guard let host, let pairing else { return }
        let snapshot = ThreadSnapshot(cursor: hasCursor ? reducer.cursor : nil,
            conversations: changed.compactMap { reducer.conversations[$0] },
            entities: changed.compactMap { reducer.entities[$0] })
        try await store.save(snapshot, host: host, deviceId: pairing.deviceId)
    }
    func handle(_ failure: any Error, token: UUID) async {
        guard token == generation, !Task.isCancelled else { return }
        let mapped = AppError.map(failure)
        error = mapped
        switch mapped {
        case .keyUnavailable: paused = true
        case .server(let status, let body):
            if ["device_revoked", "unknown_device"].contains(body.error), let host, let pairing {
                selectPairing(nil, host: host)
                do {
                    try Pairings.shared.remove(host: host)
                    try await store.clear(host: host, deviceId: pairing.deviceId)
                    try await files.clear(host: host, deviceId: pairing.deviceId)
                } catch { self.error = AppError.map(error) }
                return
            }
            if status == 426 { paused = true }
        default: break
        }
        if paused { streamTask?.cancel(); runner?.cancel(); connectionState = .disconnected }
    }
}

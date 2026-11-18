import Foundation
import HeyDanCore
import Observation
import Network
import UIKit

@MainActor @Observable final class ChatController {
    static let shared: ChatController = {
        var controller: ChatController?
        #if DEBUG
        if ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CHAT"] == "1" {
            controller = ChatController(service: FixtureAppService(), store: SwiftDataThreadStore(inMemory: true))
        }
        #endif
        Task { @MainActor in _ = Pairings.shared }
        return controller ?? ChatController(store: SwiftDataThreadStore())
    }()
    enum ConnectionState: Sendable { case disconnected, connecting, connected, reconnecting }
    private(set) var pairing: PairResponse?
    private(set) var openConversationId: String?
    var connectionState: ConnectionState = .disconnected
    var error: AppError?
    var features: [String] = []
    var conversations: [Conversation] { reducer.conversations.values.sorted { $0.id < $1.id } }
    var thread: [ThreadEntity] { openConversationId.map { visibleThread($0) } ?? [] }
    var rows: [ThreadRow] { openConversationId.map { visibleRows($0) } ?? [] }
    var historyFloors: [String: Int64] = [:]
    private func visibleThread(_ id: String) -> [ThreadEntity] {
        reducer.thread(conversationId: id).filter { ($0.order ?? 0) >= (historyFloors[id] ?? 0) }
    }
    private func visibleRows(_ id: String) -> [ThreadRow] {
        reducer.rows(conversationId: id, outbox: outbox.entries).filter {
            if case .entity(let entity) = $0 { return (entity.order ?? 0) >= (historyFloors[id] ?? 0) }
            return true
        }
    }
    var statuses: [String: Status] { reducer.statuses }
    var badge: Badge? { reducer.badge }
    var hasMoreBefore: Bool { openConversationId.flatMap { reducer.hasMoreBefore[$0] } ?? false }
    var outboxStates: [String: Outbox.State] { Dictionary(uniqueKeysWithValues: outbox.entries.map { ($0.request.clientId, $0.state) }) }
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
    @ObservationIgnored var readFlushTask: Task<Void, Never>?
    @ObservationIgnored var readTask: Task<Void, Never>?
    @ObservationIgnored var readOrder: Int64 = 0
    @ObservationIgnored var retrying: Set<String> = []
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

    func selectPairing(_ pairing: PairResponse?, host: URL) {
        guard self.host != host || self.pairing != pairing else { return }
        flushRead()
        let pendingOpen = self.host == nil || self.host == host ? openConversationId : nil
        generation = UUID()
        loadTask?.cancel(); streamTask?.cancel(); runner?.cancel(); readTask?.cancel()
        runner = nil; streamTask = nil
        self.host = host; self.pairing = pairing
        reducer = ThreadReducer(); outbox = Outbox(); openConversationId = pairing == nil ? nil : pendingOpen
        historyFloors = [:]
        savedEntries = []; durableIDs = []; ready = false; hasCursor = false; paused = false; error = nil
        features = pairing == nil ? [] : Pairings.shared.entries.first { $0.host == host }?.features ?? []
        connectionState = .disconnected
        guard let pairing else { return }
        if !fixedService { service = SignedClient(host: host, deviceId: pairing.deviceId) }
        let token = generation
        loadTask = Task {
            do {
                let snapshot = try await store.load(host: host, deviceId: pairing.deviceId)
                let entries = try await files.load(host: host, deviceId: pairing.deviceId)
                guard token == generation, !Task.isCancelled else { return }
                historyFloors = snapshot.historyFloors
                hasCursor = snapshot.hasCursor
                reducer = ThreadReducer(cursor: snapshot.cursor)
                for value in snapshot.conversations { reducer.upsert(value) }
                for value in snapshot.entities { reducer.upsert(value) }
                savedEntries = entries
                for entry in entries { outbox.enqueue(entry); durableIDs.insert(entry.request.clientId) }
                for entity in reducer.entities.values {
                    if case .message(let message) = entity { outbox.reconcile(message) }
                }
                CallLog.log(.store, "loaded cursor=\(snapshot.cursor) entities=\(snapshot.entities.count)")
                ready = true
                restart()
                if openConversationId != nil { await loadHistory(newest: true) }
            } catch { if token == generation { self.error = AppError.map(error) } }
        }
    }
    func openConversation(_ id: String) {
        guard openConversationId != id else { return }
        flushRead()
        openConversationId = id
        Task { await loadHistory(newest: true) }
    }
    func closeConversation() { flushRead(); openConversationId = nil }
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
        // A transport wait ends when the network is back; a host's Retry-After or 5xx backoff stands.
        if outbox.entries.contains(where: { $0.nextAttemptAt != nil && $0.lastServerError == nil }) {
            var resumed = Outbox()
            for var entry in outbox.entries {
                if entry.lastServerError == nil { entry.nextAttemptAt = nil }
                resumed.enqueue(entry)
            }
            outbox = resumed
        }
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
        let allowed = Set(list.conversations.map(\.id))
        var snapshot = ThreadSnapshot(cursor: cursor, conversations: list.conversations)
        snapshot.allowedConversations = allowed
        snapshot.historyFloors = historyFloors
        try await store.save(snapshot, host: host, deviceId: pairing.deviceId)
        guard token == generation, !Task.isCancelled else { return }
        reducer = ThreadReducer(cursor: max(cursor, reducer.cursor), conversations: reducer.conversations.filter { allowed.contains($0.key) }, entities: reducer.entities.filter {
            switch $0.value { case .message(let m): allowed.contains(m.conversationId); case .question(let q): allowed.contains(q.conversationId); case .unknown: false }
        },
            statuses: reducer.statuses, badge: reducer.badge, hasMoreBefore: reducer.hasMoreBefore)
        for value in list.conversations { reducer.upsert(value) }
        for value in list.statuses { reducer.upsert(value) }
        reducer.upsert(list.badge)
        hasCursor = true
    }
    func loadHistory(before: Int64? = nil, newest: Bool = false) async {
        guard let id = openConversationId, ready else { return }
        let token = generation
        do {
            let page = try await service.history(conversationId: id, query: HistoryQuery(before: before ?? (newest ? nil : historyFloors[id])))
            guard token == generation, !Task.isCancelled else { return }
            if let floor = page.items.compactMap(\.order).min() {
                historyFloors[id] = min(historyFloors[id] ?? floor, floor)
            }
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
    func flushRead() {
        readTask?.cancel()
        guard let id = openConversationId, readOrder > 0 else { return }
        let order = readOrder, token = generation
        readOrder = 0
        let client = service
        readFlushTask = Task { await sendRead(id: id, order: order, token: token, client: client) }
    }
    func sendRead(id: String, order: Int64, token: UUID, client: (any AppService)? = nil) async {
        do {
            let response = try await (client ?? service).markRead(conversationId: id, request: ReadRequest(order: order))
            guard token == generation else { return }
            reducer.upsert(response.badge)
            try await persist(reducer.upsert(response.conversation))
        } catch { if !Task.isCancelled { await handle(error, token: token) } }
    }
    func markRead(order: Int64) async {
        guard let id = openConversationId, order > max(readOrder, reducer.conversations[id]?.readOrder ?? 0) else { return }
        readOrder = max(readOrder, order)
        readTask?.cancel()
        let token = generation, pending = readOrder
        readTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            readOrder = 0
            await sendRead(id: id, order: pending, token: token)
        }
    }
    /// An agent's conversation and the client that reaches its host. Another host is read on a client of its own,
    /// so a lookup never switches the active pairing; the active host answers from its list while the stream is live.
    func pairedConversation(agentId: String, entry: Pairings.Entry) async throws(AppError) -> (conversation: Conversation?, service: any AppService) {
        guard host == entry.host, pairing?.deviceId == entry.deviceId else {
            let client = SignedClient(host: entry.host, deviceId: entry.deviceId)
            return (try await client.conversations().conversations.first { $0.agent.id == agentId }, client)
        }
        let client = service
        await loadTask?.value
        if connectionState != .connected || !conversations.contains(where: { $0.agent.id == agentId }) {
            await refresh()
            if let error, !conversations.contains(where: { $0.agent.id == agentId }) { throw error }
        }
        guard host == entry.host else { throw .notPaired }
        return (conversations.first { $0.agent.id == agentId }, client)
    }
    /// One conversation by id, without sorting the list.
    func conversation(_ id: String) -> Conversation? { reducer.conversations[id] }
    func unpair(host: URL) async {
        guard let entry = Pairings.shared.entries.first(where: { $0.host == host }) else { return }
        // The call's hangup is signed with this host's key, which unpairing deletes.
        if CallController.shared.isCallActive, CallController.shared.pairedCallTarget?.paired?.host == host {
            error = .callActive
            return
        }
        do {
            let client: any AppService = self.host == host ? service : SignedClient(host: host, deviceId: entry.deviceId)
            do { try await client.unpair() }
            catch AppError.server(401, let body) where Outbox.revokedCodes.contains(body.error) {}
            try await forget(host: host, deviceId: entry.deviceId)
        } catch { self.error = AppError.map(error) }
    }
    /// The pairing goes first, which stops this controller's writers for that device, then its thread and outbox.
    private func forget(host: URL, deviceId: String) async throws {
        try Pairings.shared.remove(host: host, deviceId: deviceId)
        try await clearLocal(host: host, deviceId: deviceId)
        CallLog.log(.store, "unpaired")
    }
    /// Both wipes run even when one fails: nothing would ever clear a device's data once its pairing is gone.
    func clearLocal(host: URL, deviceId: String) async throws {
        var failure: (any Error)?
        do { try await store.clear(host: host, deviceId: deviceId) } catch { failure = error }
        do { try await files.clear(host: host, deviceId: deviceId) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
    func persist(_ changed: Set<String>) async throws {
        guard let host, let pairing else { return }
        var snapshot = ThreadSnapshot(cursor: hasCursor ? reducer.cursor : nil,
            conversations: changed.compactMap { reducer.conversations[$0] },
            entities: changed.compactMap { reducer.entities[$0] })
        snapshot.historyFloors = historyFloors
        try await store.save(snapshot, host: host, deviceId: pairing.deviceId)
    }
    func handle(_ failure: any Error, token: UUID) async {
        guard token == generation, !Task.isCancelled else { return }
        let mapped = AppError.map(failure)
        CallLog.log(.net, "failure code=\(mapped.logName)")
        error = mapped
        switch mapped {
        case .keyUnavailable: paused = true
        case .server(let status, let body):
            if Outbox.revokedCodes.contains(body.error), let host, let pairing {
                CallLog.log(.store, "revoke")
                selectPairing(nil, host: host)
                do { try await forget(host: host, deviceId: pairing.deviceId) } catch { self.error = AppError.map(error) }
                return
            }
            if status == 426 { paused = true }
        default: break
        }
        if paused { streamTask?.cancel(); runner?.cancel(); connectionState = .disconnected }
    }
}

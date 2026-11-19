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
    /// Why the last send from the composer did not queue; shown there, not as the connection's error.
    var sendFailure: String?
    var features: [String] = []
    var conversations: [Conversation] { reducer.conversations.values.sorted { $0.id < $1.id } }
    var thread: [ThreadEntity] { openConversationId.map { visibleThread($0) } ?? [] }
    var rows: [ThreadRow] { openConversationId.map { visibleRows($0) } ?? [] }
    var historyFloors: [String: Int64] = [:]
    private func visibleThread(_ id: String) -> [ThreadEntity] {
        reducer.thread(conversationId: id).filter { ($0.order ?? 0) >= (historyFloors[id] ?? 0) }
    }
    private func visibleRows(_ id: String) -> [ThreadRow] {
        var entries = outbox.entries
        #if DEBUG
        if let fixture = service as? FixtureAppService { entries += fixture.previewOutbox }
        #endif
        return reducer.rows(conversationId: id, outbox: entries).filter {
            if case .entity(let entity) = $0 { return (entity.order ?? 0) >= (historyFloors[id] ?? 0) }
            return true
        }
    }
    var statuses: [String: Status] { reducer.statuses }
    var badge: Badge? { reducer.badge }
    var hasMoreBefore: Bool { openConversationId.flatMap { reducer.hasMoreBefore[$0] } ?? false }
    var outboxStates: [String: Outbox.State] { Dictionary(outbox.entries.map { ($0.request.clientId, $0.state) }, uniquingKeysWith: { first, _ in first }) }
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
    private enum PauseReason { case keyUnavailable, incompatibleProtocol }
    @ObservationIgnored private var pauseReason: PauseReason?
    var paused: Bool { pauseReason != nil }
    @ObservationIgnored var streamTask: Task<Void, Never>?
    @ObservationIgnored private var loadRetry: Task<Void, Never>?
    @ObservationIgnored private var loadAttempts = 0
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var runnerID = UUID()
    @ObservationIgnored var savedEntries: [Outbox.Entry] = []
    @ObservationIgnored var durableIDs: Set<String> = []
    @ObservationIgnored var runner: Task<Void, Never>?
    @ObservationIgnored var readFlushTask: Task<Void, Never>?
    @ObservationIgnored var readTask: Task<Void, Never>?
    @ObservationIgnored var readOrder: Int64 = 0
    /// The open conversation's last history load failed: the next synchronized stream loads it again.
    @ObservationIgnored var historyStale = false
    @ObservationIgnored var retrying: Set<String> = []
    /// Held while a delivery that began in the foreground drains after the app left it.
    @ObservationIgnored var backgroundDelivery: UIBackgroundTaskIdentifier = .invalid
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
                self.protectedDataAvailable()
            }
        }
    }
    deinit { monitor?.cancel(); protectedTask?.cancel(); streamTask?.cancel(); runner?.cancel(); loadTask?.cancel(); readTask?.cancel() }

    #if DEBUG && targetEnvironment(simulator)
    func selectCaptureFixture(_ scenario: String?, id: String) {
        precondition(service is FixtureAppService && Pairings.shared.isFixture)
        let host = FixtureAppService.host
        selectPairing(nil, host: host)
        service = FixtureAppService(scenario: scenario)
        offlineUntil = scenario == "offline" ? Date.now.addingTimeInterval(120) : nil
        var pairing = FixtureAppService.pairing
        pairing.deviceId = id
        try! Pairings.shared.add(pairing, host: host, features: ["files", "calls", "push", "voice-picker"])
    }
    #endif

    func protectedDataAvailable() {
        if pauseReason == .keyUnavailable { pauseReason = nil }
        restart()
    }

    func selectPairing(_ pairing: PairResponse?, host: URL) {
        guard self.host != host || self.pairing != pairing else { return }
        flushRead()
        let pendingOpen = self.host == nil || self.host == host ? openConversationId : nil
        generation = UUID()
        loadTask?.cancel(); streamTask?.cancel(); runner?.cancel(); readTask?.cancel()
        runner = nil; streamTask = nil; loadTask = nil
        loadRetry?.cancel(); loadAttempts = 0
        self.host = host; self.pairing = pairing
        reducer = ThreadReducer(); outbox = Outbox(); historyStale = false; openConversationId = pairing == nil ? nil : pendingOpen
        historyFloors = [:]
        savedEntries = []; durableIDs = []; ready = false; hasCursor = false; pauseReason = nil; error = nil
        features = pairing == nil ? [] : Pairings.shared.entries.first { $0.host == host }?.features ?? []
        connectionState = .disconnected
        guard let pairing else { return }
        if !fixedService { service = SignedClient(host: host, deviceId: pairing.deviceId) }
        loadCache()
    }

    private func loadCache() {
        guard !ready, loadTask == nil, let host, let pairing else { return }
        loadRetry?.cancel()
        let token = generation
        loadTask = Task {
            defer { if token == generation { loadTask = nil } }
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
            } catch {
                guard token == generation else { return }
                self.error = AppError.map(error)
                guard active else { return }
                loadAttempts += 1
                let delay = Outbox.backoff(attempt: loadAttempts)
                loadRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self, self.active, self.generation == token else { return }
                    self.loadCache()
                }
            }
        }
    }
    func openConversation(_ id: String) {
        guard openConversationId != id, reducer.hiddenConversations[id] == nil else { return }
        flushRead()
        openConversationId = id
        sendFailure = nil
        Task { await loadHistory(newest: true) }
    }
    func closeConversation() { flushRead(); openConversationId = nil; sendFailure = nil }
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        restart()
        if active { endBackgroundDelivery() } else { keepDeliveringInBackground() }
    }
    func restart() {
        if active && !ready { loadCache() }
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
        loadCache()
        await loadTask?.value
        guard ready else { return }
        let token = generation
        do { try await refreshList(token: token) }
        catch { await handle(error, token: token) }
    }
    func refreshList(token: UUID) async throws {
        guard ready else { throw AppError.transport(.unavailable) }
        let requestedCursor = reducer.cursor
        let list = try await service.conversations()
        guard token == generation, !Task.isCancelled, let host, let pairing else { return }
        let restored = list.seq < requestedCursor
        let cursor = hasCursor && !restored ? reducer.cursor : list.seq
        let allowed = Set(list.conversations.map(\.id))
        var snapshot = ThreadSnapshot(cursor: cursor, conversations: list.conversations)
        snapshot.allowedConversations = allowed
        snapshot.listSequence = list.seq
        snapshot.historyFloors = restored ? [:] : historyFloors
        snapshot.replacesCache = restored
        try await store.save(snapshot, host: host, deviceId: pairing.deviceId)
        guard token == generation, !Task.isCancelled else { return }
        Pairings.shared.refreshAgents(list.conversations, host: host, deviceId: pairing.deviceId)
        if restored {
            reducer = ThreadReducer()
            historyFloors.removeAll()
            historyStale = openConversationId != nil
        }
        reducer = ThreadReducer(cursor: max(cursor, reducer.cursor), conversations: reducer.conversations.filter {
            allowed.contains($0.key) || $0.value.seq > list.seq
        }, hiddenConversations: reducer.hiddenConversations, entities: reducer.entities.filter {
            switch $0.value { case .message(let m): allowed.contains(m.conversationId); case .question(let q): allowed.contains(q.conversationId); case .unknown: false }
        },
            statuses: reducer.statuses, badge: reducer.badge, hasMoreBefore: reducer.hasMoreBefore)
        for value in list.conversations { reducer.upsert(value) }
        for value in list.statuses { reducer.upsert(value) }
        reducer.upsert(list.badge)
        if let id = openConversationId, reducer.conversations[id] == nil { closeConversation() }
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
            historyStale = false
            let changed = reducer.upsert(page, conversationId: id)
            for entity in page.items { if case .message(let message) = entity { outbox.reconcile(message) } }
            try await persist(changed)
            guard token == generation else { return }
            try await saveOutbox()
        } catch {
            if token == generation, !Task.isCancelled { historyStale = true }
            await handle(error, token: token)
        }
    }
    /// The failure to show on this question's card, nil once the host took the answer.
    @discardableResult func answer(questionId: String, value: String) async -> String? {
        let token = generation
        do {
            let response = try await service.answer(questionId: questionId, request: AnswerRequest(value: value))
            guard token == generation else { return nil }
            try await persist(reducer.upsert(.question(response.question)))
            return nil
        } catch {
            guard token == generation else { return nil }
            if case AppError.server(409, let body) = error, let question = body.question {
                do { try await persist(reducer.upsert(.question(question))) } catch { self.error = AppError.map(error) }
            }
            await handle(error, token: token)
            return AppError.map(error).message
        }
    }
    func flushRead() {
        readTask?.cancel()
        guard let id = openConversationId, readOrder > 0 else { return }
        let order = readOrder, token = generation
        readOrder = 0
        guard reducer.hiddenConversations[id] == nil else { return }
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
    func toggleRead(_ conversation: Conversation) async throws {
        let token = generation
        let client = service
        // A thread closed just before the swipe can still have a final read in flight.
        await readFlushTask?.value
        guard token == generation else { return }
        let response: ReadResponse
        if conversation.unread == 0 {
            response = try await client.markUnread(conversationId: conversation.id)
        } else {
            let page = try await client.history(conversationId: conversation.id, query: HistoryQuery(limit: 1))
            guard token == generation, let order = page.items.compactMap(\.order).max() else { return }
            response = try await client.markRead(conversationId: conversation.id, request: ReadRequest(order: order))
        }
        guard token == generation else { return }
        reducer.upsert(response.badge)
        try await persist(reducer.upsert(response.conversation))
    }

    func service(for entry: Pairings.Entry) -> any AppService {
        if host == entry.host, pairing?.deviceId == entry.deviceId { return service }
        return SignedClient(host: entry.host, deviceId: entry.deviceId)
    }

    func markRead(order: Int64) async {
        guard let id = openConversationId, order > max(readOrder, reducer.conversations[id]?.readOrder ?? 0) else { return }
        readOrder = max(readOrder, order)
        readTask?.cancel()
        readTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            // Sent outside this task: closing the thread cancels only the wait, never a read already on its way.
            flushRead()
        }
    }
    /// An agent's conversation and the client that reaches its host. Another host is read on a client of its own,
    /// so a lookup never switches the active pairing; the active host answers from its list while the stream is live.
    func pairedConversation(agentId: String, entry: Pairings.Entry) async throws(AppError) -> (conversation: Conversation?, service: any AppService) {
        guard host == entry.host, pairing?.deviceId == entry.deviceId else {
            let client = SignedClient(host: entry.host, deviceId: entry.deviceId)
            let list = try await client.conversations()
            Pairings.shared.refreshAgents(list.conversations, host: entry.host, deviceId: entry.deviceId)
            return (list.conversations.first { $0.agent.id == agentId }, client)
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
    /// `localOnly` forgets the host on this phone without asking it: for a host that no longer answers, whose device
    /// then stays listed there until it is revoked on the host.
    @discardableResult func unpair(host: URL, localOnly: Bool = false) async -> AppError? {
        guard let entry = Pairings.shared.entries.first(where: { $0.host == host }) else { return nil }
        // The call's hangup is signed with this host's key, which unpairing deletes.
        if CallController.shared.isCallActive, CallController.shared.pairedCallTarget?.paired.host == host {
            error = .callActive
            return .callActive
        }
        do {
            let client: any AppService = self.host == host ? service : SignedClient(host: host, deviceId: entry.deviceId)
            if !localOnly {
                do { try await client.unpair() }
                catch AppError.server(401, let body) where Outbox.revokedCodes.contains(body.error) {}
            }
            try await forget(host: host, deviceId: entry.deviceId)
            return nil
        } catch {
            let failure = AppError.map(error)
            self.error = failure
            return failure
        }
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
        var snapshot = ThreadSnapshot(conversations: changed.compactMap { reducer.conversationRecord($0) },
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
        case .keyUnavailable: if pauseReason == nil { pauseReason = .keyUnavailable }
        case .server(let status, let body):
            if Outbox.revokedCodes.contains(body.error), let host, let pairing {
                CallLog.log(.store, "revoke")
                selectPairing(nil, host: host)
                do { try await forget(host: host, deviceId: pairing.deviceId) } catch { self.error = AppError.map(error) }
                return
            }
            if status == 426 { pauseReason = .incompatibleProtocol }
        default: break
        }
        if paused { streamTask?.cancel(); runner?.cancel(); connectionState = .disconnected }
    }
}

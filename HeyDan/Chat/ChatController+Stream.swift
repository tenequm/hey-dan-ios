import Foundation
import HeyDanCore

extension ChatController {
    func stream(token: UUID) async {
        var attempts = 0
        while token == generation, active, !paused, !Task.isCancelled {
            connectionState = attempts == 0 ? .connecting : .reconnecting
            do {
                try await waitForNetwork()
                guard token == generation else { return }
                let hello = try await service.hello()
                guard token == generation, !Task.isCancelled else { return }
                if features != hello.features { features = hello.features }
                if let host { Pairings.shared.refreshFeatures(hello.features, host: host) }
                try await refreshList(token: token)
                guard token == generation, !paused, !Task.isCancelled else { return }
                #if DEBUG
                if ProcessInfo.processInfo.environment["HEYDAN_CHAT_CHECKS"] == "1" {
                    let metadata = conversations.map { conversation in
                        ["id": conversation.id, "agent": ["id": conversation.agent.id, "name": conversation.agent.name],
                         "intentId": host.map { PairedAgentID.make(host: $0, agentId: conversation.agent.id).uuidString } ?? ""] as [String: Any]
                    }
                    if let bytes = try? JSONSerialization.data(withJSONObject: metadata) {
                        _ = FileManager.default.createFile(atPath: URL.cachesDirectory.appending(path: "chat-check-context.json").path,
                            contents: bytes, attributes: [.posixPermissions: 0o600])
                    }
                }
                #endif
                let started = ContinuousClock.now
                CallLog.log(.stream, "connect after=\(reducer.cursor)")
                let events = try await service.events(query: EventsQuery(after: reducer.cursor))
                for try await batch in Self.batches(events) {
                    guard token == generation, !Task.isCancelled else { return }
                    var candidate = reducer
                    let changed = Self.apply(batch, to: &candidate, logs: true)
                    guard let host, let pairing else { return }
                    let moved = candidate.cursor != reducer.cursor || !changed.isEmpty
                    if moved {
                        try await store.save(ThreadSnapshot(cursor: candidate.cursor,
                            conversations: changed.compactMap { candidate.conversations[$0] },
                            entities: changed.compactMap { candidate.entities[$0] }), host: host, deviceId: pairing.deviceId)
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    // Applied again to the live reducer, not swapped in: a history page, read or send that landed
                    // during the save would be lost with the copy. Upserts keep the higher seq, so this is idempotent.
                    if moved { Self.apply(batch, to: &reducer, logs: false) }
                    for id in changed {
                        if case .message(let message) = reducer.entities[id] { outbox.reconcile(message) }
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["HEYDAN_CHAT_CHECKS"] == "1" {
                        for event in batch where event.kind == .message {
                            if let message = try? event.decode(Message.self), let voice = message.voice {
                                CallLog.log(.stream, "check thread voice=\(voice.rawValue) id=\(message.id)")
                            }
                        }
                    }
                    #endif
                    if batch.contains(where: { $0.kind == .synchronized }) {
                        CallLog.log(.stream, "synchronized cursor=\(reducer.cursor) count=\(batch.count) ms=\(CallLog.ms(since: started))")
                        connectionState = .connected; error = nil; attempts = 0
                        if historyStale, openConversationId != nil { Task { await loadHistory(newest: true) } }
                    }
                    try await saveOutbox()
                    runOutbox()
                }
                try Task.checkCancellation()
                throw AppError.transport(.unavailable)
            } catch {
                await handle(error, token: token)
                guard token == generation, active, !paused, !Task.isCancelled else { return }
                attempts += 1
                CallLog.log(.stream, "reconnect attempt=\(attempts) code=\(AppError.map(error).logName)")
                connectionState = .reconnecting
                do { try await Task.sleep(for: .seconds(Outbox.backoff(attempt: attempts))) }
                catch { return }
            }
        }
    }
    /// An event that does not decode is skipped, and the cursor still moves past it.
    @discardableResult
    private static func apply(_ batch: [AppEvent], to reducer: inout ThreadReducer, logs: Bool) -> Set<String> {
        var changed: Set<String> = []
        for event in batch {
            do { changed.formUnion(try reducer.apply(event)) }
            catch {
                if logs { CallLog.log(.stream, "decode_skip seq=\(event.id ?? 0)") }
                reducer = ThreadReducer(cursor: max(reducer.cursor, event.id ?? reducer.cursor),
                    conversations: reducer.conversations, entities: reducer.entities,
                    statuses: reducer.statuses, badge: reducer.badge, hasMoreBefore: reducer.hasMoreBefore)
            }
        }
        return changed
    }
    nonisolated private static func batches(_ source: AsyncThrowingStream<AppEvent, any Error>) -> AsyncThrowingStream<[AppEvent], any Error> {
        let pair = AsyncThrowingStream<[AppEvent], any Error>.makeStream()
        let batcher = EventBatcher(continuation: pair.continuation)
        let pump = Task {
            do {
                for try await event in source { try Task.checkCancellation(); await batcher.append(event) }
                await batcher.finish(nil)
            } catch { await batcher.finish(error) }
        }
        pair.continuation.onTermination = { _ in pump.cancel() }
        return pair.stream
    }
}

private actor EventBatcher {
    let continuation: AsyncThrowingStream<[AppEvent], any Error>.Continuation
    var pending: [AppEvent] = []
    var timer: Task<Void, Never>?
    init(continuation: AsyncThrowingStream<[AppEvent], any Error>.Continuation) { self.continuation = continuation }
    func append(_ event: AppEvent) {
        pending.append(event)
        if pending.count >= 64 { flush(); return }
        guard timer == nil else { return }
        timer = Task {
            do { try await Task.sleep(for: .milliseconds(25)); flush() } catch {}
        }
    }
    func flush() {
        timer?.cancel(); timer = nil
        guard !pending.isEmpty else { return }
        continuation.yield(pending); pending.removeAll(keepingCapacity: true)
    }
    func finish(_ error: (any Error)?) { flush(); continuation.finish(throwing: error) }
}

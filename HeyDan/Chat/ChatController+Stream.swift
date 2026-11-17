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
                features = hello.features
                try await refreshList(token: token)
                guard token == generation, !paused, !Task.isCancelled else { return }
                let events = try await service.events(query: EventsQuery(after: reducer.cursor))
                for try await batch in Self.batches(events) {
                    guard token == generation, !Task.isCancelled else { return }
                    var candidate = reducer
                    var changed: Set<String> = []
                    for event in batch { changed.formUnion(try candidate.apply(event)) }
                    guard let host, let pairing else { return }
                    if candidate.cursor != reducer.cursor || !changed.isEmpty {
                    try await store.save(ThreadSnapshot(cursor: candidate.cursor,
                        conversations: changed.compactMap { candidate.conversations[$0] },
                        entities: changed.compactMap { candidate.entities[$0] }), host: host, deviceId: pairing.deviceId)
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    for event in batch { try reducer.apply(event) }
                    for event in batch {
                        if event.kind == .message { outbox.reconcile(try event.decode(Message.self)) }
                        if event.kind == .synchronized {
                            connectionState = .connected; error = nil; attempts = 0
                        }
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
                connectionState = .reconnecting
                do { try await Task.sleep(for: .seconds(Outbox.backoff(attempt: attempts))) }
                catch { return }
            }
        }
    }
}

extension ChatController {
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

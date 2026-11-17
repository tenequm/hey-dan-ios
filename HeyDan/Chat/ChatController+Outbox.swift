import Foundation
import HeyDanCore

extension ChatController {
    func send(text: String, attachments: [StagedAttachment] = []) async {
        guard let id = openConversationId else { return }
        await enqueue(text: text, attachments: attachments, conversationId: id)
    }
    private func enqueue(text: String, attachments: [StagedAttachment], conversationId: String) async {
        guard ready, let host, let pairing else { return }
        let token = generation
        do {
            let copied = try await files.stage(attachments, host: host, deviceId: pairing.deviceId)
            guard token == generation else { return }
            let entry = Outbox.Entry(host: host, conversationId: conversationId,
                request: SendRequest(clientId: UUID().uuidString, text: text, fileIds: []), attachments: copied)
            outbox.enqueue(entry)
            try await saveOutbox()
            guard token == generation else { return }
            durableIDs.insert(entry.request.clientId)
            runOutbox()
        } catch { await handle(error, token: token) }
    }
    func retry(clientId: String) async {
        guard let entry = outbox.entries.first(where: { $0.request.clientId == clientId }),
              [.failed, .outcomeUnknown].contains(entry.state), let host, let pairing else { return }
        let directory = await files.directory(host: host, deviceId: pairing.deviceId)
        let attachments = entry.attachments.map { StagedAttachment(fileURL: directory.appending(path: $0.localFileName), name: $0.name, mimeType: $0.mimeType) }
        await enqueue(text: entry.request.text, attachments: attachments, conversationId: entry.conversationId)
    }
    func saveOutbox() async throws {
        guard let host, let pairing else { return }
        let entries = outbox.entries
        try await files.save(entries, host: host, deviceId: pairing.deviceId)
        try await files.removeReachedCopies(entries, host: host, deviceId: pairing.deviceId)
    }
    func runOutbox() {
        guard runner == nil, ready, active, !paused, let host, let pairing else { return }
        let token = generation
        let runID = UUID()
        runnerID = runID
        runner = Task {
            await deliver(token: token, host: host, deviceId: pairing.deviceId)
            if token == generation, runnerID == runID { runner = nil }
        }
    }
    private func deliver(token: UUID, host: URL, deviceId: String) async {
        while token == generation, active, !paused, !Task.isCancelled {
            do { try await waitForNetwork() } catch { return }
            guard token == generation else { return }
            var wake: Date?
            var selected: (Outbox.Entry, Outbox.Action)?
            var blocked: Set<String> = []
            for entry in outbox.entries where durableIDs.contains(entry.request.clientId) {
                guard !blocked.contains(entry.conversationId) else { continue }
                let action = Outbox.step(entry, now: .now)
                switch action {
                case .done, .held: continue
                case .waitUntil(let date):
                    blocked.insert(entry.conversationId)
                    wake = min(wake ?? date, date)
                default: selected = (entry, action)
                }
                if selected != nil { break }
            }
            guard let (entry, action) = selected else {
                guard let wake else { return }
                do { try await Task.sleep(for: .seconds(max(0.01, wake.timeIntervalSinceNow))) } catch { return }
                continue
            }
            let result: Outbox.Result
            do {
                switch action {
                case .mint(let attachment): result = .ticket(uploadKey: attachment.uploadKey, try await service.initializeFile(attachment.request))
                case .renewTicket(let attachment): result = .ticket(uploadKey: attachment.uploadKey, try await service.renewFileTicket(fileId: attachment.fileId!))
                case .upload(let attachment):
                    let bytes = try await files.bytes(attachment, host: host, deviceId: deviceId)
                    guard token == generation, !Task.isCancelled else { return }
                    try await service.upload(fileId: attachment.fileId!, ticket: attachment.ticket!, bytes: bytes) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.setProgress(progress, key: attachment.uploadKey)
                        }
                    }
                    result = .uploaded(uploadKey: attachment.uploadKey)
                case .send(let request):
                    let response = try await service.send(conversationId: entry.conversationId, request: request)
                    guard token == generation, !Task.isCancelled else { return }
                    try await persist(reducer.upsert(.message(response.message)))
                    result = .sent(response.message)
                    if let agent = reducer.conversations[entry.conversationId]?.agent { Task { await MessageNotification.donateOutgoing(agent: agent, conversationID: entry.conversationId) } }
                default: return
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                let mapped = AppError.map(error)
                await handle(mapped, token: token)
                guard token == generation, !paused else { return }
                if case .server(let status, let body) = mapped { result = .serverError(status: status, body: body) }
                else { result = .transportFailure }
            }
            guard token == generation, !Task.isCancelled else { return }
            outbox.apply(result, clientId: entry.request.clientId, now: .now)
            do { try await saveOutbox() }
            catch { await handle(error, token: token); return }
        }
    }
    func download(_ file: FileAttachment) async throws -> URL {
        guard let host, let pairing else { throw AppError.notPaired }
        let token = generation
        if let cached = await files.cached(fileId: file.id, host: host, deviceId: pairing.deviceId) { return cached }
        let bytes = try await service.download(fileId: file.id)
        guard token == generation else { throw CancellationError() }
        return try await files.cache(bytes, fileId: file.id, host: host, deviceId: pairing.deviceId)
    }
}

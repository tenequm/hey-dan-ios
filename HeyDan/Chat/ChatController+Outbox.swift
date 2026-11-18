import Foundation
import HeyDanCore
import UIKit

extension ChatController {
    @discardableResult func send(text: String, attachments: [StagedAttachment] = []) async -> Bool {
        guard let id = openConversationId else { error = .transport(.unavailable); return false }
        return await enqueue(text: text, attachments: attachments, conversationId: id)
    }
    private func enqueue(text: String, attachments: [StagedAttachment], conversationId: String) async -> Bool {
        guard ready, let host, let pairing else { error = .transport(.unavailable); return false }
        guard text.utf8.count <= Outbox.maximumTextBytes, attachments.count <= Outbox.maximumFiles else {
            error = .limit("Use at most \(Outbox.maximumTextBytes / 1024) KiB of text and \(Outbox.maximumFiles) files.")
            return false
        }
        let token = generation
        do {
            let copied = try await files.stage(attachments, host: host, deviceId: pairing.deviceId)
            let entry = Outbox.Entry(host: host, conversationId: conversationId,
                request: SendRequest(clientId: UUID().uuidString, text: text, fileIds: []), attachments: copied)
            guard token == generation else {
                try? await files.removeCopies([entry], host: host, deviceId: pairing.deviceId)
                return false
            }
            outbox.enqueue(entry)
            do { try await saveOutbox() }
            catch {
                outbox.remove(clientId: entry.request.clientId)
                try? await files.removeCopies([entry], host: host, deviceId: pairing.deviceId)
                throw error
            }
            // Saved, so it is sent once its host loads again, even if the pairing changed meanwhile.
            guard token == generation else { return true }
            durableIDs.insert(entry.request.clientId)
            runOutbox()
            return true
        } catch { await handle(error, token: token); return false }
    }
    func retry(clientId: String) async {
        guard let entry = outbox.entries.first(where: { $0.request.clientId == clientId }),
              [.failed, .outcomeUnknown].contains(entry.state), let host, let pairing,
              retrying.insert(clientId).inserted else { return }
        // A second tap while the copy is staged would send the message twice.
        defer { retrying.remove(clientId) }
        let directory = await files.directory(host: host, deviceId: pairing.deviceId)
        let attachments = entry.attachments.map { StagedAttachment(fileURL: directory.appending(path: $0.localFileName), name: $0.name, mimeType: $0.mimeType) }
        if await enqueue(text: entry.request.text, attachments: attachments, conversationId: entry.conversationId) { await discard(clientId: clientId) }
    }
    func discard(clientId: String) async {
        guard let entry = outbox.entries.first(where: { $0.request.clientId == clientId }), let host, let pairing else { return }
        outbox.remove(clientId: clientId)
        do {
            try await saveOutbox()
            try await files.removeCopies([entry], host: host, deviceId: pairing.deviceId)
            durableIDs.remove(clientId)
        } catch { self.error = AppError.map(error) }
    }
    func saveOutbox() async throws {
        guard let host, let pairing else { return }
        let removed = outbox.entries.filter { $0.state == .reached }
        for entry in removed { outbox.remove(clientId: entry.request.clientId) }
        let entries = outbox.entries
        guard entries != savedEntries || !removed.isEmpty else { return }
        try await files.save(entries, host: host, deviceId: pairing.deviceId)
        savedEntries = entries
        try await files.removeCopies(removed, host: host, deviceId: pairing.deviceId)
    }
    func runOutbox() {
        runnerSleep?.cancel()
        guard runner == nil, ready, active, networkAvailable, !paused, let host, let pairing else { return }
        let token = generation
        let runID = UUID()
        runnerID = runID
        runner = Task {
            await deliver(token: token, host: host, deviceId: pairing.deviceId)
            if token == generation, runnerID == runID { runner = nil }
        }
    }
    private func deliver(token: UUID, host: URL, deviceId: String) async {
        while token == generation, active, networkAvailable, !paused, !Task.isCancelled {
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
                let sleeper = Task { try await Task.sleep(for: .seconds(max(0.01, wake.timeIntervalSinceNow))) }
                runnerSleep = sleeper
                _ = try? await sleeper.value
                runnerSleep = nil
                if Task.isCancelled { return }
                continue
            }
            let background = UIApplication.shared.beginBackgroundTask(withName: "Chat delivery") { [weak self] in
                self?.runner?.cancel()
            }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            CallLog.log(.net, "outbox step client=\(entry.request.clientId.prefix(8))")
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
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["HEYDAN_CHAT_CHECKS"] == "1" {
                        CallLog.log(.store, "check send acknowledged client=\(request.clientId) delivery=\(response.message.delivery?.rawValue ?? "none")")
                    }
                    #endif
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
            CallLog.log(.net, "outbox result client=\(entry.request.clientId.prefix(8))")
            do { try await saveOutbox() }
            catch { await handle(error, token: token); return }
        }
    }
    func download(_ file: FileAttachment) async throws -> URL {
        guard let host, let pairing else { throw AppError.notPaired }
        let token = generation
        if let cached = await files.cached(fileId: file.id, name: file.name, host: host, deviceId: pairing.deviceId) { return cached }
        let bytes = try await service.download(fileId: file.id)
        guard token == generation else { throw CancellationError() }
        return try await files.cache(bytes, fileId: file.id, name: file.name, host: host, deviceId: pairing.deviceId)
    }
}

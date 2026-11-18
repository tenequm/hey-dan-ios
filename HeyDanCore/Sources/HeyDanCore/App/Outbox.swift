import Foundation

public struct StagedAttachment: Sendable, Equatable {
    public let fileURL: URL
    public let name: String
    public let mimeType: String
    public init(fileURL: URL, name: String, mimeType: String) {
        self.fileURL = fileURL; self.name = name; self.mimeType = mimeType
    }
}

public struct Outbox: Sendable {
    public static let maximumTextBytes = 32 * 1024
    public static let maximumFiles = 10
    public static let maximumFileBytes: Int64 = 25 * 1024 * 1024
    /// The codes a host answers when this device is no longer paired: everything it holds for the host stops.
    public static let revokedCodes: Set<String> = ["device_revoked", "unknown_device"]

    public enum State: Sendable, Equatable, Codable {
        case queued, waiting, held, stored, routed, reached, failed, outcomeUnknown
        public var canSendAgain: Bool { self == .failed || self == .outcomeUnknown }
    }
    public struct Attachment: Sendable, Equatable, Codable {
        public let uploadKey: String
        public let localFileName: String
        public let name: String
        public let mimeType: String
        public let size: Int64
        public let sha256: String
        public var fileId: String?
        public var ticket: String?
        public var uploaded: Bool
        public init(uploadKey: String = UUID().uuidString, localFileName: String, name: String,
                    mimeType: String, size: Int64, sha256: String, fileId: String? = nil,
                    ticket: String? = nil, uploaded: Bool = false) {
            self.uploadKey = uploadKey; self.localFileName = localFileName; self.name = name
            self.mimeType = mimeType; self.size = size; self.sha256 = sha256
            self.fileId = fileId; self.ticket = ticket; self.uploaded = uploaded
        }
        public var request: FileInitRequest {
            FileInitRequest(uploadKey: uploadKey, name: name, mimeType: mimeType, size: size, sha256: sha256)
        }
    }
    public struct Entry: Sendable, Equatable, Codable {
        public let host: URL
        public let conversationId: String
        public let request: SendRequest
        public var state: State
        public var attachments: [Attachment]
        public var attempts: Int
        public var nextAttemptAt: Date?
        public var lastServerError: ErrorBody?
        public var serverSeq: Int64?
        public init(host: URL, conversationId: String, request: SendRequest, state: State = .queued,
                    attachments: [Attachment] = [], attempts: Int = 0, nextAttemptAt: Date? = nil,
                    lastServerError: ErrorBody? = nil, serverSeq: Int64? = nil) {
            self.host = host; self.conversationId = conversationId; self.request = request; self.state = state
            self.attachments = attachments; self.attempts = attempts; self.nextAttemptAt = nextAttemptAt
            self.lastServerError = lastServerError; self.serverSeq = serverSeq
        }
    }
    public enum Action: Sendable, Equatable {
        case mint(Attachment), renewTicket(Attachment), upload(Attachment), send(SendRequest)
        case waitUntil(Date), done, held
    }
    public enum Result: Sendable {
        case ticket(uploadKey: String, FileInitResponse)
        case uploaded(uploadKey: String)
        case sent(Message)
        case transportFailure
        /// The staged copy is gone or unreadable on this phone: no retry can send it, so it waits for Discard.
        case localFailure
        case serverError(status: Int, body: ErrorBody)
    }
    public private(set) var entries: [Entry] = []
    private var heldError: ErrorBody?
    public init() {}
    public mutating func enqueue(_ entry: Entry) {
        guard !entries.contains(where: { $0.host == entry.host && $0.conversationId == entry.conversationId && $0.request.clientId == entry.request.clientId }) else { return }
        var entry = entry
        if let heldError { entry.state = .held; entry.lastServerError = heldError }
        entries.append(entry)
    }
    public mutating func remove(clientId: String) {
        entries.removeAll { $0.request.clientId == clientId }
    }
    public mutating func reconcile(_ message: Message) {
        for index in entries.indices where entries[index].conversationId == message.conversationId && entries[index].request.clientId == message.clientId {
            Self.reconcile(message, entry: &entries[index])
        }
    }
    public static func backoff(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        max(max(0, retryAfter ?? 0), min(60, max(0, pow(2, Double(min(6, max(0, attempt - 1)))))))
    }
    public static func step(_ entry: Entry, now: Date) -> Action {
        switch entry.state {
        case .held: return .held
        case .stored, .routed, .reached, .failed, .outcomeUnknown: return .done
        default: break
        }
        if let next = entry.nextAttemptAt, next > now { return .waitUntil(next) }
        guard entry.request.text.utf8.count <= maximumTextBytes,
              entry.request.fileIds.count + entry.attachments.count <= maximumFiles,
              entry.attachments.allSatisfy({ $0.size >= 0 && $0.size <= maximumFileBytes }) else { return .held }
        for attachment in entry.attachments where !attachment.uploaded {
            guard attachment.fileId != nil else { return .mint(attachment) }
            guard attachment.ticket != nil else { return .renewTicket(attachment) }
            return .upload(attachment)
        }
        var request = entry.request
        request.fileIds += entry.attachments.compactMap(\.fileId)
        guard entry.attachments.allSatisfy({ $0.fileId != nil }) else { return .held }
        return .send(request)
    }
    public static func applying(_ result: Result, to entry: Entry, now: Date) -> Entry {
        var entry = entry
        if case .sent(let message) = result {
            reconcile(message, entry: &entry)
            return entry
        }
        switch entry.state {
        case .held, .stored, .routed, .reached, .failed, .outcomeUnknown: return entry
        default: break
        }
        switch result {
        case .ticket(let key, let response):
            guard let i = entry.attachments.firstIndex(where: { $0.uploadKey == key }) else { return entry }
            entry.attachments[i].fileId = response.fileId
            entry.attachments[i].ticket = response.ticket
            entry.attachments[i].uploaded = response.uploaded
            entry.state = .queued; entry.nextAttemptAt = nil; entry.lastServerError = nil
        case .uploaded(let key):
            guard let i = entry.attachments.firstIndex(where: { $0.uploadKey == key }) else { return entry }
            entry.attachments[i].uploaded = true
            entry.state = .queued; entry.attempts = 0; entry.nextAttemptAt = nil; entry.lastServerError = nil
        case .transportFailure:
            retry(&entry, now: now, retryAfter: nil)
        case .localFailure:
            entry.state = .held; entry.nextAttemptAt = nil
        case .serverError(let status, let body):
            entry.lastServerError = body
            switch body.error {
            case let code where Self.revokedCodes.contains(code): entry.state = .held; entry.nextAttemptAt = nil
            // A fresh signature carries a fresh nonce, so a replay refusal is corrected like a stale timestamp.
            case "stale_timestamp", "replayed": retryCorrection(&entry, now: now)
            case "ticket_expired":
                for i in entry.attachments.indices where !entry.attachments[i].uploaded &&
                    (body.fileId == nil || body.fileId == entry.attachments[i].fileId) {
                    entry.attachments[i].ticket = nil
                }
                retryCorrection(&entry, now: now)
            default:
                if status == 429 || (500...599).contains(status) {
                    retry(&entry, now: now, retryAfter: status == 429 ? body.retryAfter.map(Double.init) : nil)
                } else { entry.state = .held; entry.nextAttemptAt = nil }
            }
        case .sent: break
        }
        return entry
    }
    public mutating func apply(_ result: Result, clientId: String, now: Date) {
        if case .serverError(_, let body) = result, Self.revokedCodes.contains(body.error) {
            heldError = body
            for i in entries.indices {
                entries[i].state = .held; entries[i].lastServerError = body; entries[i].nextAttemptAt = nil
            }
            return
        }
        for i in entries.indices where entries[i].request.clientId == clientId {
            entries[i] = Self.applying(result, to: entries[i], now: now)
        }
    }
    private static func retryCorrection(_ entry: inout Entry, now: Date) {
        if entry.attempts == 0 {
            entry.attempts = 1; entry.state = .queued; entry.nextAttemptAt = nil
        } else { retry(&entry, now: now, retryAfter: nil) }
    }
    private static func retry(_ entry: inout Entry, now: Date, retryAfter: TimeInterval?) {
        entry.attempts = min(entry.attempts, 1_000_000) + 1
        entry.state = .waiting
        entry.nextAttemptAt = now.addingTimeInterval(backoff(attempt: entry.attempts, retryAfter: retryAfter))
    }
    private static func reconcile(_ message: Message, entry: inout Entry) {
        guard message.clientId == entry.request.clientId, message.conversationId == entry.conversationId,
              message.seq > (entry.serverSeq ?? -1) else { return }
        entry.serverSeq = message.seq
        switch message.delivery {
        case .stored: if ![.routed, .reached, .failed, .outcomeUnknown].contains(entry.state) { entry.state = .stored }
        case .routed: if ![.reached, .failed, .outcomeUnknown].contains(entry.state) { entry.state = .routed }
        case .reached: if ![.failed, .outcomeUnknown].contains(entry.state) { entry.state = .reached }
        case .failed: entry.state = .failed
        case .outcomeUnknown: entry.state = .outcomeUnknown
        default: entry.state = .stored
        }
        entry.nextAttemptAt = nil; entry.lastServerError = message.deliveryError
    }
}

import Foundation
import Testing
@testable import HeyDanCore

private func pending() -> Outbox.Entry {
    Outbox.Entry(host: URL(string: "https://example.com")!, conversationId: "conv_stan01",
        request: SendRequest(clientId: "stable", text: "", fileIds: []),
        attachments: [Outbox.Attachment(uploadKey: "upload", localFileName: "local", name: "file", mimeType: "text/plain", size: 4, sha256: String(repeating: "0", count: 64))])
}

@Test func lostResponsesKeepIdentityAndRenewTickets() throws {
    let now = Date(timeIntervalSince1970: 100)
    var entry = pending()
    let mint = Outbox.step(entry, now: now)
    entry = Outbox.applying(.transportFailure, to: entry, now: now)
    #expect(Outbox.step(entry, now: now) == .waitUntil(now.addingTimeInterval(1)))
    #expect(Outbox.step(entry, now: now.addingTimeInterval(1)) == mint)
    let ticket = FileInitResponse(fileId: "file", ticket: "opaque", expiresAt: 200_000, uploadPath: "/app/files/file", uploaded: false)
    entry = Outbox.applying(.ticket(uploadKey: "upload", ticket), to: entry, now: now)
    let upload = Outbox.step(entry, now: now)
    entry = Outbox.applying(.transportFailure, to: entry, now: now)
    #expect(Outbox.step(entry, now: now.addingTimeInterval(2)) == upload)
    entry = Outbox.applying(.serverError(status: 401, body: ErrorBody(error: "ticket_expired", message: "")), to: entry, now: now)
    if case .renewTicket(let attachment) = Outbox.step(entry, now: now.addingTimeInterval(10)) { #expect(attachment.uploadKey == "upload") }
    else { Issue.record("Expected renewal") }
    entry = Outbox.applying(.ticket(uploadKey: "upload", ticket), to: entry, now: now)
    entry = Outbox.applying(.uploaded(uploadKey: "upload"), to: entry, now: now)
    let send = Outbox.step(entry, now: now)
    if case .send(let request) = send { #expect(request.clientId == "stable"); #expect(request.fileIds == ["file"]) }
    else { Issue.record("Expected send") }
    entry = Outbox.applying(.transportFailure, to: entry, now: now)
    #expect(Outbox.step(entry, now: now.addingTimeInterval(1)) == send)
    let encoded = try JSONEncoder().encode(entry)
    checkCore(try JSONDecoder().decode(Outbox.Entry.self, from: encoded) == entry)
}

@Test func retryAndContractErrors() throws {
    let errors = try coreFixtures()["errors"] as! [String: [String: Any]]
    let now = Date(timeIntervalSince1970: 100)
    for value in errors.values {
        let body = try fixtureDecode(ErrorBody.self, value["body"]!)
        let status = value["status"] as! Int
        let entry = Outbox.applying(.serverError(status: status, body: body), to: pending(), now: now)
        switch body.error {
        case "stale_timestamp", "ticket_expired": #expect(entry.state == .queued)
        default:
            if status == 429 || status >= 500 { #expect(entry.state == .waiting) }
            else { #expect(entry.state == .held); checkCore(entry.lastServerError == body) }
        }
    }
    let rate = Outbox.applying(.serverError(status: 429, body: ErrorBody(error: "rate_limited", message: "", retryAfter: 2), retryAfter: 120), to: pending(), now: now)
    #expect(rate.nextAttemptAt == now.addingTimeInterval(120))
    #expect(Outbox.backoff(attempt: 100) == 60)
    #expect(Outbox.backoff(attempt: 2, jitter: 0.5) == 2.5)
    for code in ["device_revoked", "unknown_device"] {
        var outbox = Outbox(); outbox.enqueue(pending())
        outbox.enqueue(Outbox.Entry(host: pending().host, conversationId: "other", request: SendRequest(clientId: "other", text: "", fileIds: [])))
        outbox.apply(.serverError(status: 401, body: ErrorBody(error: code, message: "")), clientId: "stable", now: now)
        #expect(outbox.entries.count == 2)
        #expect(outbox.entries.allSatisfy { $0.state == .held })
    }
}

@Test func deliveryNeverResendsAndReachedDoesNotRegress() throws {
    let messages = try coreFixtures()["messages"] as! [String: Any]
    for key in ["userUnknown", "userFailed"] {
        let message = try fixtureDecode(Message.self, messages[key]!)
        var entry = Outbox.Entry(host: pending().host, conversationId: message.conversationId,
            request: SendRequest(clientId: message.clientId!, text: "", fileIds: []))
        entry = Outbox.applying(.sent(message), to: entry, now: .distantPast)
        #expect(Outbox.step(entry, now: .distantFuture) == .done)
        entry = Outbox.applying(.transportFailure, to: entry, now: .distantPast)
        #expect(Outbox.step(entry, now: .distantFuture) == .done)
    }
    var message = try fixtureDecode(Message.self, messages["userFailed"]!)
    var outbox = Outbox()
    outbox.enqueue(Outbox.Entry(host: pending().host, conversationId: message.conversationId, request: SendRequest(clientId: message.clientId!, text: "", fileIds: [])))
    for delivery in [Delivery.stored, .reached, .routed] {
        message.seq += 1; message.delivery = delivery; outbox.reconcile(message)
    }
    #expect(outbox.entries.first?.state == .reached)
}

@Test func limitsAndExpiredTickets() {
    let now = Date(timeIntervalSince1970: 100)
    var entry = pending()
    entry.attachments[0].fileId = "file"; entry.attachments[0].ticket = "opaque"
    entry.attachments[0].expiresAt = 100_000
    if case .upload = Outbox.step(entry, now: now.addingTimeInterval(7200)) {} else { Issue.record("Device clock must not expire a server ticket") }
    let oversized = Outbox.Entry(host: entry.host, conversationId: entry.conversationId,
        request: SendRequest(clientId: "large", text: String(repeating: "é", count: 16_385), fileIds: []))
    #expect(Outbox.step(oversized, now: now) == .held)
    let boundary = Outbox.Entry(host: entry.host, conversationId: entry.conversationId,
        request: SendRequest(clientId: "limit", text: String(repeating: "é", count: 16_384), fileIds: []))
    if case .send = Outbox.step(boundary, now: now) {} else { Issue.record("Text at limit should send") }
    entry.attachments = Array(repeating: pending().attachments[0], count: 11)
    #expect(Outbox.step(entry, now: now) == .held)
}

@Test func correctionRetriesAreBoundedAndResendsResetIdentity() {
    let now = Date(timeIntervalSince1970: 100)
    for code in ["stale_timestamp", "ticket_expired"] {
        var entry = pending()
        for attempt in 1...4 {
            entry = Outbox.applying(.serverError(status: 401, body: ErrorBody(error: code, message: "")), to: entry, now: now)
            #expect(entry.attempts == attempt)
            if attempt > 1 { #expect(entry.nextAttemptAt! > now) }
            if code == "ticket_expired" {
                entry = Outbox.applying(.ticket(uploadKey: "upload", FileInitResponse(fileId: "file", ticket: "opaque", expiresAt: 1, uploadPath: "", uploaded: false)), to: entry, now: now)
            }
        }
    }
    var old = pending()
    old.attachments[0].fileId = "consumed"; old.attachments[0].ticket = "old"
    old.attachments[0].uploaded = true; old.attachments[0].expiresAt = 1
    old.state = .failed; old.serverSeq = 5
    let fresh = old.resend(clientId: "new")
    #expect(fresh.request.clientId != old.request.clientId)
    #expect(fresh.attachments[0].uploadKey != old.attachments[0].uploadKey)
    #expect(fresh.attachments[0].fileId == nil && fresh.attachments[0].ticket == nil)
    #expect(fresh.attachments[0].expiresAt == nil && !fresh.attachments[0].uploaded)
    if case .mint = Outbox.step(fresh, now: now) {} else { Issue.record("Resend must mint") }
    #expect(ThreadReducer().rows(conversationId: old.conversationId, outbox: [old]).isEmpty)
    var box = Outbox(); box.enqueue(old)
    box.apply(.serverError(status: 401, body: ErrorBody(error: "device_revoked", message: "")), clientId: old.request.clientId, now: now)
    box.remove(clientId: old.request.clientId); box.enqueue(fresh)
    #expect(box.entries.count == 1 && box.entries[0].state == .held)
}

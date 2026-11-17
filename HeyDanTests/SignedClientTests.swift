import CryptoKit
import Foundation
import HeyDanCore
import Synchronization
import XCTest
@testable import HeyDan

final class SignedClientTests: XCTestCase {
    func testSecureEnclaveCreateSignReload() throws {
        let host = URL(string: "https://key-test-\(UUID().uuidString.lowercased()).invalid")!
        let key = DeviceKey()
        try key.create(host: host)
        defer { try? key.remove(host: host) }
        let publicKey = try P256.Signing.PublicKey(derRepresentation: key.publicKey(host: host))
        let bytes = Data("probe".utf8)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: DeviceKey().sign(bytes, host: host))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: bytes))
        XCTAssertEqual(try DeviceKey().publicKey(host: host), publicKey.derRepresentation)
    }

    func testClockRetrySignsNewNonceAndUploadUsesTicket() async throws {
        let key = P256.Signing.PrivateKey()
        let headers = Mutex<[String]>([])
        Stub.handler.withLock { handler in
            handler = { request in
                let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if request.httpMethod == "PUT" {
                    XCTAssertEqual(header, "HeyDan-Ticket fixture")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "3")
                    return (204, Data())
                }
                let count = headers.withLock { $0.append(header); return $0.count }
                XCTAssertTrue(header.hasPrefix("HeyDan-Sig v=1,p=1,d=dev_test,"))
                let fields = Dictionary(uniqueKeysWithValues: header.dropFirst("HeyDan-Sig ".count).split(separator: ",").map {
                    let parts = $0.split(separator: "=", maxSplits: 1)
                    return (String(parts[0]), String(parts[1]))
                })
                let canonical = SigningText.canonical(protocol: 1, method: "GET", target: "/app/conversations",
                    ts: Int64(fields["t"]!)!, nonce: fields["n"]!, bodyHash: SigningText.bodyHash(Data()), deviceId: "dev_test")
                var encoded = fields["s"]!.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: encoded)!)
                XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data(canonical.utf8)))
                if count == 1 {
                    return (401, try JSONEncoder().encode(ErrorBody(error: "stale_timestamp", message: "Clock differs", serverTime: Int64(Date().timeIntervalSince1970 * 1000) + 300_000)))
                }
                return (200, try JSONEncoder().encode(ConversationsResponse(conversations: [], statuses: [], badge: Badge(kind: .badge, rev: 1, unreadTotal: 0), seq: 1)))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let client = SignedClient(host: URL(string: "https://test.invalid")!, deviceId: "dev_test",
            configuration: configuration, signer: { data, _ in try key.signature(for: data).derRepresentation })
        _ = try await client.conversations()
        let values = headers.withLock { $0 }
        XCTAssertEqual(values.count, 2)
        let nonce: (String) -> Substring? = { $0.split(separator: ",").first { $0.hasPrefix("n=") } }
        XCTAssertNotEqual(nonce(values[0]), nonce(values[1]))
        try await client.upload(fileId: "file_test", ticket: "fixture", bytes: Data([1, 2, 3]))
    }

    func testServerErrorsPreserveBody() async throws {
        struct Refusal: Decodable { let status: Int; let body: ErrorBody }
        let fixture = #"[{"status":426,"body":{"error":"protocol","protocol":1,"message":"Update Hey Dan to keep chatting."}},{"status":401,"body":{"error":"bad_signature","message":"The request signature is not valid."}},{"status":401,"body":{"error":"unknown_device","message":"This device is not paired."}},{"status":401,"body":{"error":"device_revoked","message":"This device was unpaired."}},{"status":401,"body":{"error":"stale_timestamp","message":"The request is too old or too new.","serverTime":1794943562000}},{"status":401,"body":{"error":"replayed","message":"This request was already used."}},{"status":400,"body":{"error":"bad_body","message":"The request body does not match its signature."}},{"status":400,"body":{"error":"bad_request","message":"The request is malformed."}},{"status":403,"body":{"error":"forbidden","message":"This device cannot reach that agent."}},{"status":400,"body":{"error":"bad_proof","message":"The pairing proof is not valid."}},{"status":502,"body":{"error":"answer_not_delivered","message":"The answer did not reach the agent. Try again."}},{"status":403,"body":{"error":"invalid_code","message":"This pairing link is used or expired. Send /pair again."}},{"status":404,"body":{"error":"not_found","message":"Not found."}},{"status":409,"body":{"error":"use_call_screen","message":"Start a call with the call button."}},{"status":409,"body":{"error":"use_pairing_screen","message":"Add agents from Telegram with /pair."}},{"status":409,"body":{"error":"client_id_conflict","message":"This message was already sent with different content."}},{"status":400,"body":{"error":"bad_file","message":"An attachment is missing or was already sent.","fileId":"file_7hT2pQ9a"}},{"status":413,"body":{"error":"too_large","message":"A file can be at most 25 MB.","maxBytes":26214400}},{"status":411,"body":{"error":"length_required","message":"The upload needs a Content-Length."}},{"status":401,"body":{"error":"ticket_expired","message":"The upload link expired."}},{"status":409,"body":{"error":"upload_key_conflict","message":"This upload key was already used for another file."}},{"status":409,"body":{"error":"attempt_conflict","message":"This call attempt was already used for another conversation."}},{"status":409,"body":{"error":"conflict","message":"Different bytes were already uploaded for this file."}},{"status":429,"headers":{"Retry-After":"30"},"body":{"error":"rate_limited","message":"Too many requests. Try again shortly.","retryAfter":30}},{"status":418,"body":{"error":"teapot_from_a_later_server","message":"Shown as written.","extra":{"any":"thing"}}}]"#
        let bodies = try JSONDecoder().decode([Refusal].self, from: Data(fixture.utf8))
        for refusal in bodies {
            let status = refusal.status
            let body = refusal.body
            Stub.handler.withLock { $0 = { _ in (status, try JSONEncoder().encode(body)) } }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            let client = SignedClient(host: URL(string: "https://test.invalid")!, configuration: configuration)
            do { _ = try await client.hello(); XCTFail("Expected server refusal") }
            catch AppError.server(let actualStatus, let actualBody) {
                XCTAssertEqual(actualStatus, status)
                XCTAssertEqual(actualBody, body)
            }
        }
    }
}

private final class Stub: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, Data))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let respond = Self.handler.withLock { $0! }
            let (status, data) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

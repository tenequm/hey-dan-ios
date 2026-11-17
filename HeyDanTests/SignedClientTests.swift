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
        let timestamp: (String) -> Int64 = { Int64($0.split(separator: ",").first { $0.hasPrefix("t=") }!.dropFirst(2))! }
        XCTAssertEqual(Double(timestamp(values[1]) - timestamp(values[0])), 300, accuracy: 3)
        try await client.upload(fileId: "file_test", ticket: "fixture", bytes: Data([1, 2, 3]))
    }

    func testServerErrorsPreserveBody() async throws {
        struct Refusal: Decodable { let status: Int; let body: ErrorBody }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "app-contract.fixtures", withExtension: "json"))
        struct Fixtures: Decodable { let errors: [String: Refusal] }
        let bodies = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url)).errors.values
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
                XCTAssertEqual(actualBody.retryAfter, body.retryAfter)
            }
        }
    }
    func testSignedPostBodyAndGatewayFailures() async throws {
        let key = P256.Signing.PrivateKey()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let client = SignedClient(host: URL(string: "https://post.invalid")!, deviceId: "dev_test",
            configuration: config, signer: { bytes, _ in try key.signature(for: bytes).derRepresentation })
        Stub.handler.withLock { $0 = { request in
            let bytes: Data
            if let body = request.httpBody { bytes = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
                bytes = data
            } else { bytes = Data() }
            XCTAssertFalse(bytes.isEmpty)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("bh=" + SigningText.bodyHash(bytes) + ","))
            return (204, Data())
        } }
        try await client.cancelCall(attemptId: "attempt", request: CallCancelRequest(reason: "test"))
        for status in [502, 503, 504] {
            Stub.handler.withLock { $0 = { _ in (status, Data("gateway".utf8)) } }
            do { _ = try await client.hello(); XCTFail("Expected failure") }
            catch AppError.transport(let failure) { XCTAssertEqual(failure, .unavailable) }
        }
    }

    @MainActor func testPairingFlowPreservesOldKeyOnRefusalAndReplacesOnSuccess() async throws {
        let host = URL(string: "https://pair-\(UUID().uuidString.lowercased()).invalid")!
        let account = "test-pairings-" + UUID().uuidString
        let pending = URL(string: host.absoluteString + "#pending")!
        let key = DeviceKey()
        defer {
            try? key.remove(host: host); try? key.remove(host: pending)
            try? IdentityKeychain.remove(account: account)
        }
        try key.create(host: host)
        let old = try key.publicKey(host: host)
        let pairings = Pairings(account: account, publishes: false)
        while pairings.state == .unreadable { await Task.yield() }
        try pairings.add(PairResponse(deviceId: "dev_old", userName: "Old", agents: [], protocol: 1, serverTime: 0), host: host, features: [])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        for (status, code) in [(400, "bad_proof"), (403, "invalid_code"), (429, "rate_limited"), (200, "ok")] {
            Stub.handler.withLock { $0 = { request in
                if request.url!.path == "/app/hello" {
                    return (200, Data(#"{"protocol":1,"minProtocol":1,"voiceProtocol":6,"features":["files"],"serverTime":0}"#.utf8))
                }
                if status == 200 {
                    return (200, try JSONEncoder().encode(PairResponse(deviceId: "dev_new", userName: "Test", agents: [], protocol: 1, serverTime: 0)))
                }
                return (status, try JSONEncoder().encode(ErrorBody(error: code, message: "verbatim " + code, retryAfter: status == 429 ? 30 : nil)))
            } }
            do {
                try await pairings.pair(host.absoluteString + "/app/pair#synthetic", configuration: config)
                XCTAssertEqual(status, 200)
                XCTAssertEqual(pairings.active?.pairing.deviceId, "dev_new")
                XCTAssertNotEqual(try key.publicKey(host: host), old)
                let reloaded = Pairings(account: account, publishes: false)
                while reloaded.state == .unreadable { await Task.yield() }
                XCTAssertEqual(reloaded.active?.pairing.deviceId, "dev_new")
            } catch AppError.server(let actual, let body) {
                XCTAssertEqual(actual, status); XCTAssertEqual(body.message, "verbatim " + code)
                XCTAssertEqual(try key.publicKey(host: host), old)
                XCTAssertEqual(pairings.active?.pairing.deviceId, "dev_old")
            }
            XCTAssertNil(try IdentityKeychain.load(account: pending.absoluteString))
        }
    }

    @MainActor func testStackPairAndRejectReusedLink() async throws {
        guard let link = ProcessInfo.processInfo.environment["HEYDAN_PAIR_LINK"] else {
            throw XCTSkip("No local stack pairing link supplied")
        }
        let account = "test-stack-" + UUID().uuidString
        let pairings = Pairings(account: account, publishes: false)
        while pairings.state == .unreadable { await Task.yield() }
        defer { try? IdentityKeychain.remove(account: account) }
        try await pairings.pair(link)
        XCTAssertEqual(pairings.state, .paired)
        do { try await pairings.pair(link); XCTFail("Reused code accepted") }
        catch AppError.server(_, let body) { XCTAssertEqual(body.error, "invalid_code") }
        if let host = pairings.active?.host { try pairings.remove(host: host) }
    }

    @MainActor func testCorruptSavedPairingsCanRecover() async throws {
        let account = "test-corrupt-" + UUID().uuidString
        try IdentityKeychain.save(Data("invalid".utf8), account: account)
        defer { try? IdentityKeychain.remove(account: account) }
        let pairings = Pairings(account: account, publishes: false)
        while pairings.state == .unreadable { await Task.yield() }
        XCTAssertEqual(pairings.state, .none)
        try pairings.add(PairResponse(deviceId: "d", userName: "u", agents: [], protocol: 1, serverTime: 0),
            host: URL(string: "https://recover.invalid")!, features: [])
        XCTAssertEqual(pairings.state, .paired)
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

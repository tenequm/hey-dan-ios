import Foundation

public struct SignedRequest: Sendable {
    public let method: String
    public let target: String
    public let body: Data
    public let canonical: String
    public let authorization: Authorization
    public init(method: String, target: String, body: Data, canonical: String, authorization: Authorization) {
        self.method = method; self.target = target; self.body = body
        self.canonical = canonical; self.authorization = authorization
    }
}

public struct RequestSigner: Sendable {
    public private(set) var offset: TimeInterval
    private let clock: @Sendable () -> Date
    private let nonce: @Sendable () throws -> Data
    private let signer: @Sendable (Data) throws -> Data
    public init(offset: TimeInterval = 0, clock: @escaping @Sendable () -> Date = { Date() },
                nonce: @escaping @Sendable () throws -> Data,
                signer: @escaping @Sendable (Data) throws -> Data) {
        self.offset = offset; self.clock = clock; self.nonce = nonce; self.signer = signer
    }
    public mutating func adjustClock(from error: ErrorBody) {
        guard error.error == "stale_timestamp", let serverTime = error.serverTime else { return }
        offset = Double(serverTime) / 1000 - clock().timeIntervalSince1970
    }
    public func sign(method: String, path: [String], query: [(String, String)] = [], body: Data = Data(),
                     deviceId: String, protocol version: Int = 1) throws -> SignedRequest {
        guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) }) else { throw ContractError.invalidTarget }
        let target = try RequestTarget.build(path: path, query: query)
        let bytes = try nonce()
        guard bytes.count == 16 else { throw ContractError.invalidAuthorization }
        let ts = Int64(floor(clock().timeIntervalSince1970 + offset))
        let hash = SigningText.bodyHash(body)
        let canonical = SigningText.canonical(protocol: version, method: method, target: target, ts: ts,
                                             nonce: SigningText.base64url(bytes), bodyHash: hash, deviceId: deviceId)
        let authorization = try Authorization(protocol: version, deviceId: deviceId, ts: ts, nonce: bytes,
                                               bodyHash: hash, signature: signer(Data(canonical.utf8)))
        return SignedRequest(method: method, target: target, body: body, canonical: canonical, authorization: authorization)
    }
}

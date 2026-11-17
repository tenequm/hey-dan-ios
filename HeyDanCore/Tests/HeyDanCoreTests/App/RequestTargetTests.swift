import Foundation
import Testing
@testable import HeyDanCore

@Test func signedRequestsMatchEveryVector() throws {
    let vectors = (try coreFixtures()["signing"] as! [String: Any])["vectors"] as! [[String: Any]]
    func decode64(_ value: String) -> Data {
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))!
    }
    for v in vectors {
        let ts = (v["ts"] as! NSNumber).doubleValue
        let nonce = decode64(v["nonce"] as! String), signature = decode64(v["signature"] as! String)
        var signer = RequestSigner(clock: { Date(timeIntervalSince1970: ts - 300) }, nonce: { nonce }, signer: { _ in signature })
        signer.adjustClock(from: ErrorBody(error: "stale_timestamp", message: "", serverTime: Int64(ts * 1000)))
        let parts = URLComponents(string: v["target"] as! String)!
        let signed = try signer.sign(method: v["method"] as! String,
            path: parts.path.split(separator: "/").dropFirst().map(String.init),
            query: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            body: Data((v["body"] as! String).utf8), deviceId: v["deviceId"] as! String, protocol: v["protocol"] as! Int)
        checkCore(signed.canonical == v["canonical"] as! String)
        checkCore(signed.authorization.header == v["authorization"] as! String)
    }
}

@Test func signingClockOffset() {
    var signer = RequestSigner(clock: { Date(timeIntervalSince1970: 100) }, nonce: { Data() }, signer: { $0 })
    signer.adjustClock(from: ErrorBody(error: "stale_timestamp", message: "", serverTime: 203_500))
    #expect(signer.offset == 103.5)
    signer.adjustClock(from: ErrorBody(error: "other", message: "", serverTime: 0))
    #expect(signer.offset == 103.5)
}

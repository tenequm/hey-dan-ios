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
        let signer = RequestSigner(offset: 300, clock: { Date(timeIntervalSince1970: ts - 300) }, nonce: { nonce }, signer: { _ in signature })
        let parts = URLComponents(string: v["target"] as! String)!
        let signed = try signer.sign(method: v["method"] as! String,
            path: parts.path.split(separator: "/").dropFirst().map(String.init),
            query: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            body: Data((v["body"] as! String).utf8), deviceId: v["deviceId"] as! String, protocol: v["protocol"] as! Int)
        #expect(signed.canonical == v["canonical"] as! String)
        #expect(signed.authorization.header == v["authorization"] as! String)
    }
}
